#!/usr/bin/env python3
"""Read-only native/helper package audit. Signature validity is not notarization."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

from bundle_native_dependencies import dependencies, minimum_os


def version(value):
    parts = [int(part) for part in value.split('.')]
    return tuple((parts + [0, 0, 0])[:3])


def audit(app, deployment_target):
    contents = app.resolve() / 'Contents'
    framework_root = contents / 'Frameworks'
    bridge = (framework_root / 'libtorrent_flutter.framework' / 'libtorrent_flutter').resolve()
    helper = contents / 'Helpers' / 'peerstream-service'
    queue = [bridge, helper]
    visited = set()
    external = []
    minima = []
    while queue:
        binary = queue.pop().resolve()
        if binary in visited:
            continue
        visited.add(binary)
        if not binary.is_file():
            external.append({'from': binary.name, 'missing': binary.name})
            continue
        minimum = minimum_os(binary)
        minima.append({'name': binary.name, 'minimumMacOS': minimum})
        for dependency in dependencies(binary):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@loader_path/'):
                target = (binary.parent / dependency.removeprefix('@loader_path/')).resolve()
            elif dependency.startswith('@executable_path/'):
                target = (binary.parent / dependency.removeprefix('@executable_path/')).resolve()
            elif dependency.startswith('@rpath/'):
                target = (framework_root / dependency.removeprefix('@rpath/')).resolve()
            else:
                external.append({'from': binary.name, 'externalLibrary': pathlib.Path(dependency).name})
                continue
            if not target.is_relative_to(contents) or not target.is_file():
                external.append({'from': binary.name, 'unresolvedLibrary': pathlib.Path(dependency).name})
            else:
                queue.append(target)
    verification = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True).stderr
    ad_hoc = 'Signature=adhoc' in signature
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(helper)], capture_output=True)
    try:
        values = plistlib.loads(entitlements.stdout)
        inherited_sandbox = values.get('com.apple.security.app-sandbox') is True and values.get('com.apple.security.inherit') is True
    except (plistlib.InvalidFileException, ValueError):
        inherited_sandbox = False
    incompatible = [item for item in minima if item['minimumMacOS'] and version(item['minimumMacOS']) > version(deployment_target)]
    trust_file = contents / 'Resources/NativeTrust/cacert.pem'
    trust_source = pathlib.Path(__file__).resolve().parent.parent / 'resources/native-trust/cacert.pem'
    trust_matches = trust_file.is_file() and trust_file.read_bytes() == trust_source.read_bytes()
    return {
        'scope': 'Source-built torrent bridge, its transitive libraries, bundled service helper and app signature',
        'externalOrMissingDependencies': external,
        'nativeLibraries': sorted(minima, key=lambda value: value['name']),
        'requestedMinimumMacOS': deployment_target,
        'incompatibleMinimumOSLibraries': incompatible,
        'deepSignatureValid': verification.returncode == 0,
        'adHocSignature': ad_hoc,
        'helperInheritsSandbox': inherited_sandbox,
        'bundledPublicTrustMatchesSource': trust_matches,
        'publicTrustSHA256': hashlib.sha256(trust_file.read_bytes()).hexdigest() if trust_file.is_file() else None,
        'notarizationVerified': False,
        'distributionReady': False,
        'reason': 'Developer ID/notarization and oldest-supported-OS runtime checks are required independently of local ad-hoc signing.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--deployment-target', default='12.0')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    result = audit(args.app, args.deployment_target)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    raise SystemExit(bool(result['externalOrMissingDependencies']) or not result['deepSignatureValid'] or not result['helperInheritsSandbox'] or not result['bundledPublicTrustMatchesSource'])
