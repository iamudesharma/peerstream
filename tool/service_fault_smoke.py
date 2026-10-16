#!/usr/bin/env python3
"""Fault checks on original data and a private, disposable 64 MiB disk image.
Never detaches the host SSD. Only the image created by this invocation is mounted.
"""
import argparse
import concurrent.futures
import select
import errno
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from service_native_smoke import bencode


class Helper:
    def __init__(self, args, root, log, environment=None):
        self.token = secrets.token_hex(32)
        child_environment = dict(os.environ)
        for key, value in (environment or {}).items():
            if value is None:
                child_environment.pop(key, None)
            else:
                child_environment[key] = value
        self.process = subprocess.Popen(
            [str(args.binary.resolve()), '--root', str(root), '--native', str(args.library.resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
            env=child_environment,
        )
        self.process.stdin.write(json.dumps({'token': self.token}) + '\n')
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 15)[0]:
            self.process.kill()
            self.process.wait(timeout=5)
            raise TimeoutError('Helper bootstrap exceeded 15 seconds')
        self.ready = json.loads(self.process.stdout.readline())
        self.endpoint = f'http://127.0.0.1:{self.ready["port"]}'

    def command(self, op, **args):
        request = urllib.request.Request(
            self.endpoint + '/v1/command',
            data=json.dumps({'op': op, 'args': {'instance': self.ready['instance'], **args}}).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + self.token},
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)['data']

    def close(self):
        if self.process.poll() is not None:
            return
        self.process.stdin.close()
        try:
            self.process.wait(timeout=12)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise
        assert self.process.returncode == 0


def wait_for(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('Fault-test condition timed out')


def run(args):
    payload = (b'Original PeerStream fault verification payload.\n' * 100000)[:4 * 1024 * 1024]
    bad_requests = threading.Event()

    class Seed(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path not in ['/bad/fixture.mp4', '/good/fixture.mp4']:
                self.send_error(404)
                return
            start, end = 0, len(payload) - 1
            header = self.headers.get('Range')
            if header:
                first, last = header.removeprefix('bytes=').split('-')
                start, end = int(first), int(last or end)
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(payload)}')
            else:
                self.send_response(200)
            block = payload[start:end + 1]
            if self.path.startswith('/bad/'):
                bad_requests.set()
                block = bytes(value ^ 0xff for value in block)
            self.send_header('Content-Length', str(len(block)))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()
            try:
                self.wfile.write(block)
            except (BrokenPipeError, ConnectionResetError):
                pass

    seed = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Seed)
    threading.Thread(target=seed.serve_forever, daemon=True).start()
    piece_size = 256 * 1024
    info = {
        b'name': b'fixture.mp4', b'length': len(payload), b'piece length': piece_size,
        b'pieces': b''.join(hashlib.sha1(payload[i:i + piece_size]).digest() for i in range(0, len(payload), piece_size)),
    }
    identity = hashlib.sha1(bencode(info)).hexdigest()
    torrent = bencode({b'info': info, b'url-list': [f'http://127.0.0.1:{seed.server_port}/bad/fixture.mp4']})
    report = {}
    helper = None
    mounted = False
    args.temp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='peerstream-service-fault-', dir=args.temp_parent) as workspace:
        workspace = pathlib.Path(workspace)
        image = workspace / 'disposable.sparseimage'
        mount = workspace / 'mount'
        mount.mkdir()

        def attach():
            nonlocal mounted
            result = subprocess.run(
                ['hdiutil', 'attach', '-plist', '-nobrowse', '-mountpoint', str(mount), str(image)],
                check=True, capture_output=True,
            )
            entities = plistlib.loads(result.stdout)['system-entities']
            assert any(entry.get('mount-point') == str(mount) for entry in entities)
            mounted = True

        def detach():
            nonlocal mounted
            # This is the exact mount point of our newly created image, never the SSD.
            subprocess.run(['hdiutil', 'detach', '-force', str(mount)], check=True, capture_output=True)
            mounted = False

        subprocess.run(
            ['hdiutil', 'create', '-size', '64m', '-fs', 'HFS+', '-volname', 'PeerStreamPrivateFault', '-type', 'SPARSE', str(image)],
            check=True, capture_output=True,
        )
        attach()
        root = mount / 'engine'
        with (workspace / 'helper.log').open('ab') as log:
            try:
                helper = Helper(args, root, log)
                session = helper.command('add', requestId='corrupt', cacheKey=identity, torrent=list(torrent))['session']
                wait_for(lambda: helper.command('files', session=session))
                helper.command('download', session=session, fileIndex=0)
                assert bad_requests.wait(timeout=15)
                time.sleep(1)
                assert helper.command('complete', session=session, fileIndex=0) is False
                report['corruptSeedRejected'] = True
                helper.command('webSeed', session=session, url=f'http://127.0.0.1:{seed.server_port}/good/fixture.mp4')
                wait_for(lambda: helper.command('complete', session=session, fileIndex=0), seconds=40)
                snapshot = helper.command('start', session=session, fileIndex=0)
                url = snapshot['stream']['url']

                def read_range(header, expected):
                    request = urllib.request.Request(url, headers={'Range': header})
                    with urllib.request.urlopen(request, timeout=10) as response:
                        assert response.status == 206
                        assert response.read() == expected

                read_range('bytes=-2048', payload[-2048:])
                read_range(f'bytes={len(payload)-2048}-', payload[-2048:])
                report['suffixAndOpenEndedTailProbes'] = True
                parsed = urllib.parse.urlsplit(url)
                for _ in range(8):
                    with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as client:
                        client.sendall(f'GET {parsed.path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
                        client.recv(512)
                read_range('bytes=0-1023', payload[:1024])
                report['cancelledReadersRecover'] = True
                with socket.create_connection((parsed.hostname, parsed.port), timeout=8) as client:
                    client.sendall(b'GET /incomplete HTTP/1.1\r\n')
                    started = time.monotonic()
                    assert client.recv(1024) == b''
                    assert time.monotonic() - started < 8
                report['incompleteHeadersBounded'] = True
                helper.command('persist')
                resume = root / 'payload' / identity / 'resume.dat'
                saved_resume = resume.read_bytes()
                saved_session = (root / 'session.dat').read_bytes()
                helper.command('cachePreferences', maxCacheBytes=1024)
                index = root / 'peerstream-playback-cache.json'
                original = index.read_bytes()
                filler = mount / 'filler'
                with filler.open('wb', buffering=0) as output:
                    for block_size, limit in [(1024 * 1024, 128), (4096, 4096)]:
                        try:
                            for _ in range(limit):
                                output.write(b'x' * block_size)
                        except OSError as error:
                            assert error.errno == errno.ENOSPC
                try:
                    helper.command('cachePreferences', maxCacheBytes=2048)
                    raise AssertionError('Expected real ENOSPC')
                except urllib.error.HTTPError as error:
                    assert error.code == 422
                assert index.read_bytes() == original
                try:
                    helper.command('persist')
                    raise AssertionError('Expected resume persistence failure on real ENOSPC')
                except urllib.error.HTTPError as error:
                    assert error.code == 422
                assert resume.read_bytes() == saved_resume
                assert (root / 'session.dat').read_bytes() == saved_session
                assert helper.command('health')['resumePersistenceFailed'] is True
                report['fullDiskPreservesPreviousResumeAndReportsFailure'] = True
                assert helper.command('release', session=session)['resumeSaved'] is False
                assert helper.command('health')['sessions'] == 0
                report['releaseStillStopsSessionOnFullDisk'] = True
                filler.unlink()
                helper.command('cachePreferences', maxCacheBytes=2048)
                assert helper.command('cacheIndex')['maxCacheBytes'] == 2048
                session = helper.command('add', requestId='after-full', cacheKey=identity, torrent=list(torrent))['session']
                wait_for(lambda: helper.command('files', session=session))
                snapshot = helper.command('start', session=session, fileIndex=0)
                url = snapshot['stream']['url']
                read_range('bytes=0-1023', payload[:1024])
                helper.command('persist')
                assert helper.command('health')['resumePersistenceFailed'] is False
                report['fullDiskAtomicIndexAndRecovery'] = True
                detach()
                state = wait_for(lambda: helper.command('snapshot', session=session))
                assert state.get('error') is True
                assert 'Storage' in state['message']
                assert not root.exists()
                report['privateVolumeRemovalDetected'] = True
                attach()
                helper.close()
                helper = Helper(args, root, log)
                assert helper.command('cacheIndex')['maxCacheBytes'] == 2048
                resumed = helper.command('add', requestId='resume', cacheKey=identity, torrent=list(torrent))['session']
                wait_for(lambda: helper.command('files', session=resumed))
                snapshot = helper.command('start', session=resumed, fileIndex=0)
                url = snapshot['stream']['url']
                read_range('bytes=0-1023', payload[:1024])
                read_range('bytes=-2048', payload[-2048:])
                report['volumeReconnectResumeAndExactBytes'] = True
                helper.command('release', session=resumed)
                missing_info = {**info, b'nonce': secrets.token_hex(16)}
                missing_torrent = bencode({b'info': missing_info})
                missing_id = hashlib.sha1(bencode(missing_info)).hexdigest()
                pending = helper.command('add', requestId='pending-read', cacheKey=missing_id, torrent=list(missing_torrent))['session']
                wait_for(lambda: helper.command('files', session=pending))
                url = helper.command('start', session=pending, fileIndex=0)['stream']['url']
                headers_received = threading.Event()
                def pending_read():
                    try:
                        request = urllib.request.Request(url, headers={'Range': 'bytes=0-1023'})
                        with urllib.request.urlopen(request, timeout=10) as response:
                            headers_received.set()
                            return response.read()
                    except Exception:
                        return b''
                with concurrent.futures.ThreadPoolExecutor(1) as executor:
                    blocked = executor.submit(pending_read)
                    assert headers_received.wait(timeout=5)
                    started = time.monotonic()
                    helper.command('release', session=pending)
                    assert blocked.result(timeout=5) == b''
                    assert time.monotonic() - started < 5
                report['cancelBlockedMissingPieceReaderWithinFiveSeconds'] = True
                helper.close()
                helper = None
            finally:
                try:
                    if helper is not None:
                        helper.close()
                finally:
                    if mounted:
                        detach()
    seed.shutdown()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--library', type=pathlib.Path, required=True)
    parser.add_argument('--temp-parent', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    run(parser.parse_args())
