#!/usr/bin/env python3
"""Verify native HTTPS trust using only private generated certificates and data."""
import argparse
import hashlib
import http.server
import json
import pathlib
import ssl
import subprocess
import tempfile
import threading
import time

from service_fault_smoke import Helper, wait_for
from service_native_smoke import bencode


def run(args):
    args.temp_parent.mkdir(parents=True, exist_ok=True)
    report = {}
    with tempfile.TemporaryDirectory(prefix='peerstream-tls-', dir=args.temp_parent) as temporary:
        root = pathlib.Path(temporary)
        for name in ['trusted', 'unrelated']:
            subprocess.run([
                'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=PeerStream private TLS fixture', '-addext', 'subjectAltName=IP:127.0.0.1',
                '-keyout', str(root / (name + '.key')), '-out', str(root / (name + '.pem')),
            ], check=True, capture_output=True)
        payload = b'Original PeerStream private HTTPS verification data.\n' * 10000
        served = threading.Event()

        class Seed(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                start, end = 0, len(payload) - 1
                if self.headers.get('Range'):
                    first, last = self.headers['Range'].removeprefix('bytes=').split('-')
                    start, end = int(first), int(last or end)
                    self.send_response(206)
                    self.send_header('Content-Range', f'bytes {start}-{end}/{len(payload)}')
                else:
                    self.send_response(200)
                data = payload[start:end + 1]
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                try:
                    self.wfile.write(data)
                    served.set()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        seed = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Seed)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / 'trusted.pem', root / 'trusted.key')
        seed.socket = context.wrap_socket(seed.socket, server_side=True)
        threading.Thread(target=seed.serve_forever, daemon=True).start()
        piece = 256 * 1024
        info = {
            b'name': b'fixture.mp4', b'length': len(payload), b'piece length': piece,
            b'pieces': b''.join(hashlib.sha1(payload[i:i + piece]).digest() for i in range(0, len(payload), piece)),
        }
        identity = hashlib.sha1(bencode(info)).hexdigest()
        torrent = bencode({b'info': info, b'url-list': [f'https://127.0.0.1:{seed.server_port}/fixture.mp4']})
        try:
            # With no override, the packaged bridge must find and validate its
            # bundled trust file. It must reject this private, untrusted server.
            for name, certificates in [('bundled', None), ('untrusted', str(root / 'unrelated.pem')), ('trusted', str(root / 'trusted.pem'))]:
                served.clear()
                engine_root = root / name
                with (root / (name + '.log')).open('ab') as log:
                    helper = Helper(args, engine_root, log, {'SSL_CERT_FILE': certificates, 'SSL_CERT_DIR': str(root / 'no-system-roots')})
                    try:
                        session = helper.command('add', requestId=name, cacheKey=identity, torrent=list(torrent))['session']
                        wait_for(lambda: helper.command('files', session=session))
                        helper.command('download', session=session, fileIndex=0)
                        if name == 'trusted':
                            wait_for(lambda: helper.command('complete', session=session, fileIndex=0), seconds=30)
                            assert served.is_set()
                            report['explicitTrustedCAAllowsVerifiedHTTPSWebSeed'] = True
                        else:
                            time.sleep(3)
                            assert not served.is_set()
                            assert helper.command('complete', session=session, fileIndex=0) is False
                            report[name + 'RejectsUntrustedHTTPSWebSeed'] = True
                    finally:
                        helper.close()
                if name == 'bundled':
                    assert 'Validated bundled macOS public CA certificates' in (engine_root / 'torrent_bridge.log').read_text()
                    report['frameworkRelativeBundledTrustValidated'] = True
        finally:
            seed.shutdown()
            seed.server_close()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--library', type=pathlib.Path, required=True)
    parser.add_argument('--temp-parent', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    run(parser.parse_args())
