#!/usr/bin/env python3
"""Original loopback BitTorrent peer: magnet metadata -> native Range -> real player.
Separate from the HTTP web-seed matrix; never reads/writes the user's payload cache.
"""
import argparse
import hashlib
import json
import os
import pathlib
import select
import shlex
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

from service_native_smoke import bencode
from benchmark_matrix import active_players, p95


def main(args):
    if active_players():
        raise RuntimeError('Close the existing player before native verification.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    snapshot = pathlib.Path(subprocess.check_output([
        'python3', 'tool/verify_metadata.py', 'snapshot', str(args.storage_root),
    ], text=True).strip())
    rows = []
    code = 0
    try:
        with tempfile.TemporaryDirectory(prefix='peerstream-wire-', dir=args.storage_root / 'temp') as root_name:
            root = pathlib.Path(root_name)
            seed_binary = root / 'local-peer-seed'
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libtorrent-rasterbar', 'openssl'], text=True))
            boost = subprocess.check_output(['brew', '--prefix', 'boost'], text=True).strip()
            flags.append('-I' + boost + '/include')
            native_env = dict(os.environ, SDKROOT=subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
            subprocess.run(['xcrun', 'clang++', '-std=c++17', 'tool/fixtures/local_peer_seed.cpp', '-o', str(seed_binary), *flags], env=native_env, check=True)
            app = pathlib.Path('build/macos/Build/Products/Profile/PeerStream.app').resolve()
            if not args.skip_build:
                with args.output.with_suffix('.build.log').open('w') as log:
                    subprocess.run(['flutter', 'build', 'macos', '--profile', '--target', 'integration_test/peer_player_test.dart', '--dart-define=PEERSTREAM_PLAYER_FIXTURE=' + str(args.fixture.resolve())], stdout=log, stderr=subprocess.STDOUT, check=True)
            if not app.exists():
                raise RuntimeError('Profile app is unavailable')
            payload = args.fixture.read_bytes()
            shutil.copyfile(args.fixture, root / 'video.mkv')
            for sample in range(args.samples):
                for backend in ['native', 'service']:
                    info = {'length': len(payload), 'name': 'video.mkv', 'piece length': 256 * 1024,
                            'pieces': b''.join(hashlib.sha1(payload[i:i + 256 * 1024]).digest() for i in range(0, len(payload), 256 * 1024)),
                            'nonce': str(time.time_ns())}
                    torrent = root / 'video.torrent'
                    torrent.write_bytes(bencode({'info': info}))
                    seed_log = args.output.with_name(f'{args.output.stem}-{sample:02d}-{backend}-seed.log')
                    with seed_log.open('w') as log:
                        seed = subprocess.Popen([str(seed_binary), str(torrent), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
                        try:
                            if not select.select([seed.stdout], [], [], 20)[0]:
                                raise RuntimeError('Loopback peer readiness timed out')
                            magnet = seed.stdout.readline().strip()
                            if not magnet.startswith('magnet:?') or 'x.pe=127.0.0.1:' not in magnet:
                                raise RuntimeError('Loopback peer failed: ' + seed_log.read_text())
                            trial_log = args.output.with_name(f'{args.output.stem}-{sample:02d}-{backend}.log')
                            with trial_log.open('w') as output:
                                trial = subprocess.Popen(['flutter', 'drive', '-d', 'macos', '--profile', '--driver', 'tool/integration_driver.dart', '--target', 'integration_test/peer_player_test.dart', '--use-application-binary', str(app), '--dart-entrypoint-args=' + backend, '--dart-entrypoint-args=' + magnet + '&tr=http%3A%2F%2F127.0.0.1%3A9%2Fannounce'], stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                                try:
                                    trial.wait(timeout=180)
                                except subprocess.TimeoutExpired:
                                    os_group_stop(trial)
                                    raise
                            parsed = [json.loads(line[line.index('{'):]) for line in trial_log.read_text().splitlines() if '[PeerVerification]' in line and '{' in line]
                            if len(parsed) != 1:
                                raise RuntimeError(f'Local peer trial failed: {trial_log.name}')
                            rows.extend(parsed)
                            if trial.returncode:
                                code = 1
                                row = parsed[0]
                                if row['visiblePlaybackMs'] <= 10000 or row['sourceLookups'] != 0 or row['playableScheme'] != 'http':
                                    raise RuntimeError(f'Local peer correctness failed: {trial_log.name}')
                            parsed[0]['startupTargetMet'] = parsed[0]['visiblePlaybackMs'] <= 10000
                            print(json.dumps({'backend': backend, 'sample': sample + 1, 'firstFrameMs': parsed[0]['visiblePlaybackMs']}), flush=True)
                        finally:
                            seed.stdin.close()
                            try:
                                seed.wait(timeout=12)
                            except subprocess.TimeoutExpired:
                                seed.kill()
                                seed.wait(timeout=5)
    except Exception as error:
        code = 1
        print(str(error), flush=True)
    finally:
        guard = subprocess.run(['python3', 'tool/verify_metadata.py', 'check', str(args.storage_root), '--snapshot', str(snapshot)], capture_output=True, text=True)
        guard_result = json.loads(guard.stdout)
        if guard.returncode:
            code = 1
        else:
            shutil.rmtree(snapshot)
            guard_result['snapshotRetained'] = None
        summary = {}
        for backend in ['native', 'service']:
            values = [r['visiblePlaybackMs'] for r in rows if r['backend'] == backend]
            summary[backend] = {'samples': len(values), 'firstFrameMedianMs': statistics.median(values) if values else None, 'firstFrameP95Ms': p95(values) if values else None}
        args.output.write_text(json.dumps({'exitCode': code, 'metadataGuard': guard_result, 'results': rows, 'summary': summary,
            'applicationBuildSkipped': args.skip_build, 'scope': 'Original fixture over loopback TCP/uTP BitTorrent peer with magnet metadata exchange, no HTTP web seed and only an inert loopback tracker URI (avoids production default public tracker injection). Seed upload budget 1 MiB/s. Fresh application and cache per trial.',
            'p95AcceptanceEvaluated': args.samples >= 20 and len(rows) == 2 * args.samples}, indent=2))
    raise SystemExit(code)


def os_group_stop(process):
    import os
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=pathlib.Path, required=True)
    parser.add_argument('--storage-root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--skip-build', action='store_true', help='Reuse the already-built peer fixture app; never for another entrypoint.')
    options = parser.parse_args()
    if options.samples < 1:
        parser.error('--samples must be positive')
    main(options)
