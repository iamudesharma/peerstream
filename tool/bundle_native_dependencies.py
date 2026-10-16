#!/usr/bin/env python3
"""Bundle the bridge's non-system dylibs without changing their minimum OS claims."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def dependencies(binary):
    lines = run('otool', '-L', str(binary)).splitlines()[1:]
    identifiers = run('otool', '-D', str(binary)).splitlines()[1:]
    return [value for line in lines if (value := line.strip().split(' (compatibility version', 1)[0]) not in identifiers]


def minimum_os(binary):
    output = run('xcrun', 'vtool', '-show-build', str(binary))
    match = re.search(r'\bminos\s+([0-9.]+)', output)
    return match.group(1) if match else None


def bundle(app, identity, native_prefix=None):
    contents = app.resolve() / 'Contents'
    framework = contents / 'Frameworks' / 'libtorrent_flutter.framework'
    bridge = (framework / 'libtorrent_flutter').resolve()
    if not bridge.is_file():
        raise RuntimeError('Build the source bridge before bundling native dependencies.')
    destination = contents / 'Frameworks' / 'PeerStreamNative'
    destination.mkdir(exist_ok=True)
    resources = contents / 'Resources'
    report_path = resources / 'peerstream-native-libraries.json'
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    linker_sources = dict(previous.get('linkerLibrarySources', {}))
    originals = {}
    portable = {}
    if native_prefix is not None:
        native_prefix = native_prefix.resolve()
        manifest = json.loads((native_prefix / 'peerstream-native-build.json').read_text())
        if manifest['architecture'] != platform.machine() or manifest['libtorrentABI'] != 2 or manifest['versions'] != {'libtorrent': '2.1.1', 'openssl': '3.6.4', 'boostHeaders': '1.88.0'} or manifest.get('webtorrentRTC') is not True:
            raise RuntimeError('The portable prefix does not match this bridge build.')
        for item in manifest['libraries']:
            path = native_prefix / 'lib' / item['name']
            if pathlib.Path(item['name']).name != item['name'] or item['minimumMacOS'] != '12.0' or minimum_os(path) != '12.0' or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
                raise RuntimeError('Portable native library verification failed.')
            portable[item['name']] = path.resolve()
        if set(portable) != {'libboost_system.dylib', 'libssl.3.dylib', 'libcrypto.3.dylib', 'libtorrent-rasterbar.2.1.1.dylib'}:
            raise RuntimeError('The portable prefix must contain all four matching libraries.')
    queue = [bridge]
    graph = {}
    while queue:
        binary = queue.pop()
        if binary in graph:
            continue
        edges = []
        for dependency in dependencies(binary):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@'):
                if dependency.startswith('@rpath/') and pathlib.Path(dependency).name in portable:
                    source = portable[pathlib.Path(dependency).name]
                    originals[source.name] = source
                    edges.append((dependency, source))
                    queue.append(source)
                    continue
                # The bridge's own install ID is not a dependency. Already
                # bundled loader paths are retained when a build phase reruns.
                if dependency.startswith('@rpath/libtorrent_flutter.framework/'):
                    continue
                if dependency.startswith('@loader_path/'):
                    resolved = (binary.parent / dependency[len('@loader_path/'):]).resolve()
                    if resolved.is_relative_to(destination) and resolved.is_file():
                        if not portable:
                            remembered = linker_sources.get(resolved.name)
                            if remembered is None:
                                if previous.get('portableSourceBuild'):
                                    raise RuntimeError('Clean/relink this source-prefix app before a normal build; original linker inputs are unknown.')
                                continue
                            source = pathlib.Path(remembered).resolve()
                            if not source.is_file():
                                raise RuntimeError('Original linker input unavailable; clean/relink before normal packaging: ' + resolved.name)
                            originals[source.name] = source
                            edges.append((dependency, source))
                            queue.append(source)
                            continue
                        source = portable.get(resolved.name)
                        if source is None:
                            raise RuntimeError('A bundled dependency is absent from the portable prefix: ' + resolved.name)
                        originals[source.name] = source
                        edges.append((dependency, source))
                        queue.append(source)
                        continue
                raise RuntimeError(f'Unresolved non-system dependency in {binary.name}: {dependency}')
            source = pathlib.Path(dependency).resolve()
            if portable:
                source = portable.get(source.name, source)
            else:
                linker_sources[source.name] = str(source)
            if not source.is_file():
                raise RuntimeError(f'Missing native dependency: {source.name}')
            name = source.name
            if name in originals and originals[name] != source:
                raise RuntimeError(f'Conflicting native library name: {name}')
            originals[name] = source
            edges.append((dependency, source))
            queue.append(source)
        graph[binary] = edges
    # Copy every original before patching references. Never edit Homebrew files.
    for name, original in originals.items():
        shutil.copy2(original, destination / name)
        os.chmod(destination / name, 0o755)
    for original, edges in graph.items():
        target = bridge if original == bridge else destination / original.name
        for dependency, source in edges:
            relative = os.path.relpath(destination / source.name, target.parent)
            subprocess.run(['install_name_tool', '-change', dependency, '@loader_path/' + relative, str(target)], check=True, capture_output=True)
        if original != bridge:
            subprocess.run(['install_name_tool', '-id', '@rpath/PeerStreamNative/' + target.name, str(target)], check=True, capture_output=True)
    for path in destination.glob('*.dylib'):
        subprocess.run(['codesign', '--force', '--sign', identity, str(path)], check=True, capture_output=True)
    subprocess.run(['codesign', '--force', '--sign', identity, str(framework)], check=True, capture_output=True)
    # A successful copy is not proof of older-OS compatibility.
    libraries = [{'name': name, 'minimumMacOS': minimum_os(destination / name)} for name in sorted(path.name for path in destination.glob('*.dylib'))]
    report = {'libraries': libraries, 'bridgeMinimumMacOS': minimum_os(bridge), 'minimumOSUnchanged': True}
    report['linkerLibrarySources'] = linker_sources
    if native_prefix is not None:
        report['portableSourceBuild'] = manifest
    resources.mkdir(exist_ok=True)
    (destination / 'manifest.json').unlink(missing_ok=True)
    notices = resources / 'NativeLicenses'
    notices.mkdir(exist_ok=True)
    repository = pathlib.Path(__file__).resolve().parent.parent
    trust_source = repository / 'resources/native-trust/cacert.pem'
    trust_bytes = trust_source.read_bytes()
    if trust_bytes.count(b'-----BEGIN CERTIFICATE-----') < 100:
        raise RuntimeError('The pinned public native CA bundle is missing or invalid.')
    trust = resources / 'NativeTrust'
    trust.mkdir(exist_ok=True)
    shutil.copy2(trust_source, trust / 'cacert.pem')
    report['nativeTrust'] = {
        'source': 'https://curl.se/docs/caextract.html',
        'sha256': hashlib.sha256(trust_bytes).hexdigest(),
        'certificates': trust_bytes.count(b'-----BEGIN CERTIFICATE-----'),
        'explicitEnvironmentOverridePreserved': True,
    }
    for license_file in (repository / 'licenses' / 'native').glob('*.txt'):
        shutil.copy2(license_file, notices / license_file.name)
    shutil.copy2(repository / 'packages/libtorrent_flutter/LICENSE', notices / 'libtorrent_flutter-LICENSE.txt')
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--native-prefix', type=pathlib.Path)
    args = parser.parse_args()
    bundle(args.app, args.identity, args.native_prefix)
