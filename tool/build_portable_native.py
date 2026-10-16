#!/usr/bin/env python3
"""Build pinned native dependencies in an isolated prefix, never into Homebrew.
This produces deployment-target evidence, not an oldest-OS runtime guarantee.
"""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import tarfile
import urllib.request

from bundle_native_dependencies import minimum_os

SOURCES = {
    'openssl-3.6.4.tar.gz': ('https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz', '9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef'),
    'libtorrent-rasterbar-2.1.1.tar.gz': ('https://github.com/arvidn/libtorrent/releases/download/v2.1.1/libtorrent-rasterbar-2.1.1.tar.gz', '0f163516ecef2e3331500266751de3098835a3c3ae0c2290448046c632bc0e93'),
    'boost-error_code.cpp': ('https://raw.githubusercontent.com/boostorg/system/boost-1.88.0/src/error_code.cpp', '4e3e95f1e90a76e0bfc32f03510c54b7a81ff0a2ab7da20f93315e84384c4e75'),
}


def main(args):
    if platform.system() != 'Darwin':
        raise RuntimeError('This dependency builder is macOS-only.')
    architecture = platform.machine()
    if architecture not in ['arm64', 'x86_64']:
        raise RuntimeError('Unsupported host architecture')
    boost = args.boost.resolve()
    if '#define BOOST_VERSION 108800' not in (boost / 'include/boost/version.hpp').read_text():
        raise RuntimeError('The bridge requires matching Boost 1.88 headers.')
    workspace = args.workspace.resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    build_lock = (workspace / 'build.lock').open('a')
    fcntl.flock(build_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    prefix = workspace / 'prefix'
    prefix.mkdir(exist_ok=True)
    source = workspace / 'sources'
    source.mkdir(exist_ok=True)
    for name, (url, digest) in SOURCES.items():
        target = source / name
        if not target.exists():
            with urllib.request.urlopen(url, timeout=60) as response, target.open('wb') as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Source checksum mismatch: ' + name)
        if name.endswith('.tar.gz'):
            directory = source / name.removesuffix('.tar.gz')
            if not directory.exists():
                with tarfile.open(target) as archive:
                    archive.extractall(source, filter='data')
    environment = {
        **os.environ,
        'MACOSX_DEPLOYMENT_TARGET': '12.0',
        'CC': '/usr/bin/clang', 'CXX': '/usr/bin/clang++',
        'SDKROOT': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip(),
    }

    def run(*command, cwd=None):
        print('Running:', *command, flush=True)
        subprocess.run(command, cwd=cwd, env=environment, check=True)

    openssl = source / 'openssl-3.6.4'
    if not (prefix / '.openssl-installed').is_file():
        target = 'darwin64-arm64-cc' if architecture == 'arm64' else 'darwin64-x86_64-cc'
        run('./Configure', target, 'shared', 'no-tests', '--prefix=' + str(prefix), '--openssldir=' + str(prefix / 'ssl'), '-mmacosx-version-min=12.0', cwd=openssl)
        run('make', '-j' + str(args.jobs), cwd=openssl)
        run('make', 'install_sw', cwd=openssl)
        (prefix / '.openssl-installed').write_text('3.6.4 macOS 12.0\n')
    # Boost.System >=1.69 is header-only. Preserve its actual upstream legacy
    # stub export for the existing bridge link command, targeting macOS 12.
    run('/usr/bin/clang++', '-dynamiclib', '-std=c++17', '-mmacosx-version-min=12.0', '-I' + str(boost / 'include'), str(source / 'boost-error_code.cpp'), '-install_name', str(prefix / 'lib/libboost_system.dylib'), '-o', str(prefix / 'lib/libboost_system.dylib'))
    build = workspace / 'libtorrent-build'
    run('cmake', '-S', str(source / 'libtorrent-rasterbar-2.1.1'), '-B', str(build),
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=' + str(prefix),
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0', '-DCMAKE_OSX_ARCHITECTURES=' + architecture,
        '-DCMAKE_CXX_FLAGS=-Werror=unguarded-availability-new',
        '-DOPENSSL_ROOT_DIR=' + str(prefix), '-DOPENSSL_INCLUDE_DIR=' + str(prefix / 'include'),
        '-DOPENSSL_SSL_LIBRARY=' + str(prefix / 'lib/libssl.3.dylib'),
        '-DOPENSSL_CRYPTO_LIBRARY=' + str(prefix / 'lib/libcrypto.3.dylib'),
        '-DBoost_DIR=' + str(boost / 'lib/cmake/Boost-1.88.0'),
        '-Ddeprecated-functions=ON', '-Dwebtorrent=ON', '-DBUILD_SHARED_LIBS=ON',
        '-Dbuild_tests=OFF', '-Dbuild_examples=OFF', '-Dbuild_tools=OFF', '-Dpython-bindings=OFF')
    run('cmake', '--build', str(build), '--parallel', str(args.jobs))
    run('cmake', '--install', str(build))
    libraries = []
    for name in ['libboost_system.dylib', 'libssl.3.dylib', 'libcrypto.3.dylib', 'libtorrent-rasterbar.2.1.1.dylib']:
        library = prefix / 'lib' / name
        minimum = minimum_os(library)
        if minimum != '12.0':
            raise RuntimeError('Unexpected minimum OS: ' + name + ': ' + str(minimum))
        libraries.append({'name': name, 'minimumMacOS': minimum, 'sha256': hashlib.sha256(library.read_bytes()).hexdigest()})
    result = {
        'architecture': architecture, 'minimumMacOS': '12.0',
        'versions': {'libtorrent': '2.1.1', 'openssl': '3.6.4', 'boostHeaders': '1.88.0'},
        'libtorrentABI': 2, 'webtorrentRTC': True,
        'sources': {name: {'url': url, 'sha256': digest} for name, (url, digest) in SOURCES.items()},
        'libraries': libraries, 'oldestOSRuntimeVerified': False,
    }
    (prefix / 'peerstream-native-build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=pathlib.Path, required=True)
    parser.add_argument('--boost', type=pathlib.Path, default=pathlib.Path('/opt/homebrew/opt/boost'))
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error('--jobs must be between 1 and 8')
    main(args)
