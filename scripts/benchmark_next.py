#!/usr/bin/env python3
"""Local encrypted-report workload. Never connects to a deployed relay."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import statistics
import sys
import tempfile
import threading
import time
import uuid
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from app import Relay, card_bytes, header_bytes
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def encode(value):
    return base64.b64encode(value).decode()


def identity():
    sign = Ed25519PrivateKey.generate()
    pub = sign.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    card = dict(id=hashlib.sha256(pub).hexdigest(), signingKey=encode(pub),
                agreementKey=encode(X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)))
    card['binding'] = encode(sign.sign(card_bytes(card)))
    return sign, card


def request(relay, path, method, body, remote, token=None):
    raw = json.dumps(body).encode() if body is not None else b''
    env = dict(REQUEST_METHOD=method, PATH_INFO=path, CONTENT_LENGTH=str(len(raw)), CONTENT_TYPE='application/json', REMOTE_ADDR=remote)
    env['wsgi.input'] = io.BytesIO(raw)
    if token: env['HTTP_AUTHORIZATION'] = 'Bearer ' + token
    status = []
    def start(value, headers): status.append(int(value.split()[0]))
    result = json.loads(b''.join(relay(env, start)))
    return status[0], result


def login(relay, private, card, remote):
    assert request(relay, '/v1/register', 'POST', card, remote)[0] == 200
    status, challenge = request(relay, '/v1/challenge', 'POST', {'id': card['id']}, remote)
    assert status == 200
    proof = f"VO1D-AUTH-1\n{card['id']}\n{challenge['nonce']}".encode()
    status, response = request(relay, '/v1/session', 'POST', dict(id=card['id'], nonce=challenge['nonce'], signature=encode(private.sign(proof))), remote)
    assert status == 200
    return response['token']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--transport', choices=('wsgi', 'http'), default='wsgi')
    args = parser.parse_args()
    if not 1 <= args.samples <= 2000 or not 1 <= args.workers <= 32:
        parser.error('samples must be 1..2000; workers 1..32')
    with tempfile.TemporaryDirectory() as directory:
        relay = Relay(Path(directory) / 'benchmark.sqlite3')
        root, admin = identity()
        root_token = login(relay, root, admin, '10.255.255.254')
        assert request(relay, '/v1/username', 'POST', {'username': 'vo1d'}, '10.255.255.254', root_token)[0] == 200
        fixtures = []
        for i in range(args.samples):
            private, card = identity()
            remote = f'10.0.{i // 254}.{i % 254 + 1}'
            token = login(relay, private, card, remote)
            ephemeral = X25519PrivateKey.generate()
            e = dict(id=str(uuid.uuid4()), sender=card['id'], recipient=admin['id'],
                     ephemeralKey=encode(ephemeral.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
                     salt=encode(os.urandom(32)), expiresAt=int(time.time()) + 3600, ciphertext='', signature='')
            subject = 'c' * 64
            content = dict(kind='VO1D-REPORT-1', reportID=e['id'], subject=subject, reason='other', source='profile', comment='Synthetic benchmark evidence', messages=[], createdAt=time.time())
            shared = ephemeral.exchange(X25519PublicKey.from_public_bytes(base64.b64decode(admin['agreementKey'])))
            key = HKDF(algorithm=hashes.SHA256(), length=32, salt=base64.b64decode(e['salt']), info=header_bytes(e)).derive(shared)
            nonce = os.urandom(12)
            cipher = nonce + AESGCM(key).encrypt(nonce, json.dumps(content).encode(), header_bytes(e))
            e['ciphertext'] = encode(cipher); e['signature'] = encode(private.sign(header_bytes(e) + b'\n' + cipher))
            fixtures.append((remote, token, dict(subject=subject, reason='other', source='profile', consent=True, envelope=e)))
        class QuietHandler(WSGIRequestHandler):
            def log_message(self, *args):
                pass
        class LocalServer(ThreadingMixIn, WSGIServer):
            daemon_threads = True
            request_queue_size = 64
        server = None
        if args.transport == 'http':
            # Deliberately bind only loopback and choose an ephemeral port.
            # No endpoint override or proxy-header identity spoofing is allowed.
            server = make_server('127.0.0.1', 0, relay, server_class=LocalServer, handler_class=QuietHandler)
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
            thread.start()
        def submit(fixture):
            remote, token, body = fixture
            start = time.perf_counter()
            if server is None:
                status, _ = request(relay, '/v2/reports', 'POST', body, remote, token)
            else:
                connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=30)
                try:
                    connection.request('POST', '/v2/reports', json.dumps(body).encode(), {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
                    response = connection.getresponse(); response.read()
                    status = response.status
                except (OSError, http.client.HTTPException):
                    status = 0
                finally:
                    connection.close()
            return status, (time.perf_counter() - start) * 1000
        start = time.perf_counter()
        try:
            with ThreadPoolExecutor(args.workers) as pool:
                results = list(pool.map(submit, fixtures))
        finally:
            if server is not None:
                server.shutdown(); server.server_close(); thread.join(timeout=5)
        elapsed = time.perf_counter() - start
        durations = sorted(r[1] for r in results)
        failures = sum(status != 200 for status, _ in results)
        with relay.db() as db:
            stored = db.execute('SELECT count(*) FROM reports').fetchone()[0]
            chat_rows = db.execute('SELECT count(*) FROM envelopes').fetchone()[0]
        result = dict(samples=args.samples, workers=args.workers, transport=args.transport, seconds=round(elapsed, 3),
                      p50_ms=round(statistics.median(durations), 3), p95_ms=round(durations[min(len(durations)-1, int(len(durations)*.95))], 3),
                      failures=failures, stored_reports=stored, chat_envelopes=chat_rows,
                      boundary=('Loopback HTTP, WSGI, signatures and SQLite; excludes TLS, Tor, iOS, APNs, fixture setup and production capacity' if server is not None else 'Local WSGI, signatures and SQLite; excludes network, Tor, iOS, APNs, fixture setup and production capacity'))
        print(json.dumps(result, indent=2))
        return 0 if failures == 0 and stored == args.samples and chat_rows == 0 else 1


if __name__ == '__main__': raise SystemExit(main())
