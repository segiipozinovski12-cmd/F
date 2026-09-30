"""VO1D opaque mailbox relay. WSGI application; no message plaintext is accepted."""
import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

ID = re.compile(r'^[a-f0-9]{64}$')
CODE = re.compile(r'^[2-9A-HJ-NP-Z]{4}
UUID = re.compile(r'^[A-Za-z0-9-]{16,64}$')
MAX_BODY = 9 * 1024 * 1024
MAX_ENVELOPE = 7 * 1024 * 1024
RETENTION = 7 * 86400

class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def b64(value, length=None):
    if not isinstance(value, str):
        raise APIError(400, 'Invalid base64')
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise APIError(400, 'Invalid base64')
    if length is not None and len(result) != length:
        raise APIError(400, 'Invalid key length')
    return result


def card_bytes(card):
    return f"VO1D-CARD-1\n{card['id']}\n{card['signingKey']}\n{card['agreementKey']}".encode()


def verify_card(card):
    if not isinstance(card, dict) or not all(isinstance(card.get(k), str) for k in ('id', 'signingKey', 'agreementKey', 'binding')):
        raise APIError(400, 'Invalid identity')
    signing = b64(card['signingKey'], 32)
    b64(card['agreementKey'], 32)
    if hashlib.sha256(signing).hexdigest() != card['id']:
        raise APIError(400, 'Identity fingerprint mismatch')
    try:
        Ed25519PublicKey.from_public_bytes(signing).verify(b64(card['binding'], 64), card_bytes(card))
    except InvalidSignature:
        raise APIError(400, 'Invalid identity signature')
    return {k: card[k] for k in ('id', 'signingKey', 'agreementKey', 'binding')}


def header_bytes(e):
    return f"VO1D-ENVELOPE-1\n{e['id']}\n{e['sender']}\n{e['recipient']}\n{e['ephemeralKey']}\n{e['salt']}\n{e['expiresAt']}".encode()


class Relay:
    def __init__(self, path=None):
        self.path = str(path or os.environ.get('VO1D_DB', './data/relay.sqlite3'))
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS identities (id TEXT PRIMARY KEY, card TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS challenges (nonce TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS envelopes (id TEXT, recipient TEXT, sender TEXT, body TEXT, expires INTEGER, size INTEGER, PRIMARY KEY(id,recipient));
                CREATE INDEX IF NOT EXISTS mailbox ON envelopes(recipient,expires);
                CREATE TABLE IF NOT EXISTS seen (id TEXT, recipient TEXT, digest TEXT, expires INTEGER, PRIMARY KEY(id,recipient));
                CREATE TABLE IF NOT EXISTS blocks (owner TEXT, peer TEXT, PRIMARY KEY(owner,peer));
                CREATE TABLE IF NOT EXISTS codes (code TEXT PRIMARY KEY, identity TEXT UNIQUE NOT NULL);
                CREATE INDEX IF NOT EXISTS code_identity ON codes(identity);
                CREATE TABLE IF NOT EXISTS usernames (username TEXT PRIMARY KEY, identity TEXT UNIQUE NOT NULL, updated INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS username_identity ON usernames(identity);
                CREATE TABLE IF NOT EXISTS rates (bucket TEXT PRIMARY KEY, count INTEGER, expires INTEGER);
            ''')

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.path, timeout=20)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def rate(self, key, limit, window=60):
        now = int(time.time())
        bucket = f'{key}:{now // window}'
        with self.db() as db:
            db.execute('DELETE FROM rates WHERE expires < ?', (now,))
            db.execute('INSERT INTO rates VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=count+1', (bucket, now + window * 2))
            count = db.execute('SELECT count FROM rates WHERE bucket=?', (bucket,)).fetchone()[0]
        if count > limit:
            raise APIError(429, 'Too many requests. Try again later.')

    def clean(self, db):
        now = int(time.time())
        for table in ('challenges', 'sessions', 'envelopes', 'seen'):
            db.execute(f'DELETE FROM {table} WHERE expires <= ?', (now,))

    def user(self, env, db):
        auth = env.get('HTTP_AUTHORIZATION', '')
        if not auth.startswith('Bearer '):
            raise APIError(401, 'Authentication required')
        digest = hashlib.sha256(auth[7:].encode()).hexdigest()
        row = db.execute('SELECT identity FROM sessions WHERE digest=? AND expires>?', (digest, int(time.time()))).fetchone()
        if not row:
            raise APIError(401, 'Session expired')
        return row[0]

    def dispatch(self, env, body):
        method, path = env['REQUEST_METHOD'], env.get('PATH_INFO', '/')
        now = int(time.time())
        # Only the immediate peer is used; untrusted forwarded headers never bypass limits.
        ip_hash = hashlib.sha256(env.get('REMOTE_ADDR', '').encode()).hexdigest()
        if method == 'GET' and path == '/health':
            return {'status': 'ok', 'protocol': 1}
        if path in ('/v1/register', '/v1/challenge', '/v1/session'):
            self.rate('auth:' + ip_hash, 90)
        if path == '/v1/register':
            self.rate('register:' + ip_hash, 30, 3600)
        public = path in ('/v1/register', '/v1/challenge', '/v1/session')
        if not public:
            with self.db() as auth_db:
                user = self.user(env, auth_db)
            self.rate('user:' + user, 240)
        with self.db() as db:
            self.clean(db)
            if method == 'POST' and path == '/v1/register':
                card = verify_card(body)
                old = db.execute('SELECT card FROM identities WHERE id=?', (card['id'],)).fetchone()
                if old and json.loads(old[0]) != card:
                    raise APIError(409, 'Identity already bound to different keys')
                db.execute('INSERT OR IGNORE INTO identities VALUES (?,?)', (card['id'], json.dumps(card)))
                return {'ok': True}
            if method == 'POST' and path == '/v1/challenge':
                identity = body.get('id', '')
                if not isinstance(identity, str) or not ID.fullmatch(identity):
                    raise APIError(400, 'Invalid identity')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (identity,)).fetchone():
                    raise APIError(404, 'Unknown identity')
                nonce = secrets.token_urlsafe(32)
                db.execute('INSERT INTO challenges VALUES (?,?,?)', (nonce, identity, now + 120))
                return {'nonce': nonce}
            if method == 'POST' and path == '/v1/session':
                nonce = body.get('nonce', '')
                identity = body.get('id', '')
                row = db.execute('SELECT card FROM identities WHERE id=?', (identity,)).fetchone()
                challenge = db.execute('SELECT 1 FROM challenges WHERE nonce=? AND identity=? AND expires>?', (nonce, identity, now)).fetchone()
                if not row or not challenge:
                    raise APIError(401, 'Invalid or expired challenge')
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(body.get('signature'), 64), f'VO1D-AUTH-1\n{identity}\n{nonce}'.encode())
                except InvalidSignature:
                    raise APIError(401, 'Invalid signature')
                # DELETE condition makes concurrent replay lose, even under multiple workers.
                if db.execute('DELETE FROM challenges WHERE nonce=?', (nonce,)).rowcount != 1:
                    raise APIError(401, 'Challenge already consumed')
                token = secrets.token_urlsafe(32)
                db.execute('INSERT INTO sessions VALUES (?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), identity, now + 86400))
                return {'token': token}
            if method == 'POST' and path == '/v1/code':
                existing = db.execute('SELECT code FROM codes WHERE identity=?', (user,)).fetchone()
                if existing:
                    return {'code': existing[0]}
                for _ in range(128):
                    code = ''.join(secrets.choice(CODE_ALPHABET) for _ in range(4))
                    try:
                        db.execute('INSERT INTO codes(code,identity) VALUES (?,?)', (code, user))
                        return {'code': code}
                    except sqlite3.IntegrityError:
                        continue
                raise APIError(500, 'Unable to allocate compact ID')
            if method == 'GET' and path.startswith('/v1/code/'):
                code = path.rsplit('/', 1)[1].upper()
                if not CODE.fullmatch(code):
                    raise APIError(400, 'Invalid compact ID')
                row = db.execute('SELECT i.card FROM codes c JOIN identities i ON i.id=c.identity WHERE c.code=?', (code,)).fetchone()
                if not row:
                    raise APIError(404, 'Compact ID not found')
                return json.loads(row[0])
            if method == 'GET' and path.startswith('/v1/username/check/'):
                username = path.rsplit('/', 1)[1].lower()
                if not USERNAME.fullmatch(username) or username in RESERVED_USERNAMES:
                    return {'username': username, 'available': False, 'valid': False}
                row = db.execute('SELECT identity FROM usernames WHERE username=?', (username,)).fetchone()
                return {
                    'username': username,
                    'available': row is None or row[0] == user,
                    'valid': True
                }
            if method == 'POST' and path == '/v1/username':
                username = body.get('username', '')
                if not isinstance(username, str):
                    raise APIError(400, 'Invalid username')
                username = username.strip().lower()
                if not USERNAME.fullmatch(username):
                    raise APIError(400, 'Username must be 4-20 characters: a-z, 0-9, underscore')
                if username in RESERVED_USERNAMES:
                    raise APIError(409, 'Username is reserved')
                owner = db.execute('SELECT identity FROM usernames WHERE username=?', (username,)).fetchone()
                if owner and owner[0] != user:
                    raise APIError(409, 'Username is already taken')
                db.execute('DELETE FROM usernames WHERE identity=? AND username<>?', (user, username))
                db.execute(
                    'INSERT INTO usernames(username,identity,updated) VALUES (?,?,?) '
                    'ON CONFLICT(username) DO UPDATE SET identity=excluded.identity,updated=excluded.updated',
                    (username, user, now)
                )
                return {'username': username}
            if method == 'GET' and path.startswith('/v1/username/'):
                username = path.rsplit('/', 1)[1].lower()
                if not USERNAME.fullmatch(username):
                    raise APIError(400, 'Invalid username')
                row = db.execute(
                    'SELECT i.card FROM usernames u JOIN identities i ON i.id=u.identity WHERE u.username=?',
                    (username,)
                ).fetchone()
                if not row:
                    raise APIError(404, 'Username not found')
                return {'username': username, 'card': json.loads(row[0])}
            if method == 'GET' and path.startswith('/v1/identity/'):
                row = db.execute('SELECT card FROM identities WHERE id=?', (path.rsplit('/', 1)[1],)).fetchone()
                if not row:
                    raise APIError(404, 'Contact is not registered on this relay')
                return json.loads(row[0])
            if method == 'POST' and path == '/v1/envelopes':
                e = body
                keys = ('id', 'sender', 'recipient', 'ephemeralKey', 'salt', 'ciphertext', 'signature')
                if not all(isinstance(e.get(k), str) for k in keys) or type(e.get('expiresAt')) is not int:
                    raise APIError(400, 'Invalid envelope')
                if not UUID.fullmatch(e['id']) or e['sender'] != user or not ID.fullmatch(e['recipient']):
                    raise APIError(400, 'Invalid envelope identity')
                if not now < e['expiresAt'] <= now + RETENTION + 60:
                    raise APIError(400, 'Invalid expiry')
                b64(e['ephemeralKey'], 32)
                b64(e['salt'], 32)
                cipher = b64(e['ciphertext'])
                if not 28 <= len(cipher) <= MAX_ENVELOPE:
                    raise APIError(413, 'Message exceeds size limit')
                row = db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(e['signature'], 64), header_bytes(e) + b'\n' + cipher)
                except InvalidSignature:
                    raise APIError(403, 'Invalid envelope signature')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (e['recipient'],)).fetchone():
                    raise APIError(404, 'Recipient not registered')
                if db.execute('SELECT 1 FROM blocks WHERE owner=? AND peer=?', (e['recipient'], user)).fetchone():
                    # Do not expose whether the recipient has blocked this sender.
                    return {'ok': True}
                encoded = json.dumps({k: e[k] for k in (*keys, 'expiresAt')}, separators=(',', ':'))
                digest = hashlib.sha256(encoded.encode()).hexdigest()
                old = db.execute('SELECT digest FROM seen WHERE id=? AND recipient=?', (e['id'], e['recipient'])).fetchone()
                if old:
                    if old[0] != digest:
                        raise APIError(409, 'Envelope ID collision')
                    return {'ok': True}
                count, size = db.execute('SELECT count(*), coalesce(sum(size),0) FROM envelopes WHERE recipient=?', (e['recipient'],)).fetchone()
                if count >= 1000 or size + len(encoded) > 100 * 1024 * 1024:
                    raise APIError(429, 'Recipient mailbox is full')
                db.execute('INSERT INTO envelopes VALUES (?,?,?,?,?,?)', (e['id'], e['recipient'], user, encoded, e['expiresAt'], len(encoded)))
                db.execute('INSERT INTO seen VALUES (?,?,?,?)', (e['id'], e['recipient'], digest, e['expiresAt']))
                return {'ok': True}
            if method == 'GET' and path == '/v1/inbox':
                rows = db.execute('SELECT body FROM envelopes WHERE recipient=? ORDER BY rowid LIMIT 10', (user,)).fetchall()
                return {'envelopes': [json.loads(row[0]) for row in rows]}
            if method == 'POST' and path == '/v1/ack':
                ids = body.get('ids')
                if not isinstance(ids, list) or len(ids) > 100 or not all(isinstance(i, str) for i in ids):
                    raise APIError(400, 'Invalid acknowledgement')
                db.executemany('DELETE FROM envelopes WHERE id=? AND recipient=?', [(i, user) for i in ids])
                return {'ok': True}
            if method == 'POST' and path == '/v1/block':
                peer = body.get('id', '')
                if not isinstance(peer, str) or not ID.fullmatch(peer):
                    raise APIError(400, 'Invalid contact')
                if body.get('blocked', True):
                    db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?)', (user, peer))
                    db.execute('DELETE FROM envelopes WHERE recipient=? AND sender=?', (user, peer))
                else:
                    db.execute('DELETE FROM blocks WHERE owner=? AND peer=?', (user, peer))
                return {'ok': True}
            if method == 'DELETE' and path == '/v1/account':
                db.execute('DELETE FROM envelopes WHERE sender=? OR recipient=?', (user, user))
                db.execute('DELETE FROM seen WHERE recipient=?', (user,))
                db.execute('DELETE FROM blocks WHERE owner=? OR peer=?', (user, user))
                db.execute('DELETE FROM codes WHERE identity=?', (user,))
                db.execute('DELETE FROM usernames WHERE identity=?', (user,))
                db.execute('DELETE FROM sessions WHERE identity=?', (user,))
                db.execute('DELETE FROM challenges WHERE identity=?', (user,))
                db.execute('DELETE FROM identities WHERE id=?', (user,))
                return {'ok': True}
            raise APIError(404, 'Not found')

    def __call__(self, env, start_response):
        try:
            length = int(env.get('CONTENT_LENGTH') or 0)
            if length < 0 or length > MAX_BODY:
                raise APIError(413, 'Request too large')
            if env['REQUEST_METHOD'] == 'POST' and env.get('CONTENT_TYPE', '').split(';')[0] != 'application/json':
                raise APIError(415, 'JSON required')
            body = json.loads(env['wsgi.input'].read(length)) if length else {}
            if not isinstance(body, dict):
                raise APIError(400, 'JSON object required')
            result = self.dispatch(env, body)
            status = 200
        except APIError as e:
            result, status = {'error': e.message}, e.status
        except (ValueError, TypeError, KeyError, UnicodeError):
            result, status = {'error': 'Invalid request'}, 400
        except Exception:
            # No raw requests, tokens, identifiers or traceback are logged.
            result, status = {'error': 'Relay unavailable'}, 500
        payload = json.dumps(result, separators=(',', ':')).encode()
        reason = {200:'OK',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',409:'Conflict',413:'Payload Too Large',415:'Unsupported Media Type',429:'Too Many Requests',500:'Internal Server Error'}[status]
        start_response(f'{status} {reason}', [('Content-Type','application/json'),('Content-Length',str(len(payload))),('Cache-Control','no-store'),('X-Content-Type-Options','nosniff')])
        return [payload]


def create_app():
    return Relay()


if __name__ == '__main__':
    from wsgiref.simple_server import make_server, WSGIRequestHandler
    class QuietHandler(WSGIRequestHandler):
        def log_message(self, *args):
            pass
    print('VO1D development relay: http://127.0.0.1:8080 (production: use Docker + TLS)')
    make_server('0.0.0.0', 8080, create_app(), handler_class=QuietHandler).serve_forever()
)
CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
USERNAME = re.compile(r'^[a-z0-9_]{4,20}
UUID = re.compile(r'^[A-Za-z0-9-]{16,64}$')
MAX_BODY = 9 * 1024 * 1024
MAX_ENVELOPE = 7 * 1024 * 1024
RETENTION = 7 * 86400

class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def b64(value, length=None):
    if not isinstance(value, str):
        raise APIError(400, 'Invalid base64')
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise APIError(400, 'Invalid base64')
    if length is not None and len(result) != length:
        raise APIError(400, 'Invalid key length')
    return result


def card_bytes(card):
    return f"VO1D-CARD-1\n{card['id']}\n{card['signingKey']}\n{card['agreementKey']}".encode()


def verify_card(card):
    if not isinstance(card, dict) or not all(isinstance(card.get(k), str) for k in ('id', 'signingKey', 'agreementKey', 'binding')):
        raise APIError(400, 'Invalid identity')
    signing = b64(card['signingKey'], 32)
    b64(card['agreementKey'], 32)
    if hashlib.sha256(signing).hexdigest() != card['id']:
        raise APIError(400, 'Identity fingerprint mismatch')
    try:
        Ed25519PublicKey.from_public_bytes(signing).verify(b64(card['binding'], 64), card_bytes(card))
    except InvalidSignature:
        raise APIError(400, 'Invalid identity signature')
    return {k: card[k] for k in ('id', 'signingKey', 'agreementKey', 'binding')}


def header_bytes(e):
    return f"VO1D-ENVELOPE-1\n{e['id']}\n{e['sender']}\n{e['recipient']}\n{e['ephemeralKey']}\n{e['salt']}\n{e['expiresAt']}".encode()


class Relay:
    def __init__(self, path=None):
        self.path = str(path or os.environ.get('VO1D_DB', './data/relay.sqlite3'))
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS identities (id TEXT PRIMARY KEY, card TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS challenges (nonce TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS envelopes (id TEXT, recipient TEXT, sender TEXT, body TEXT, expires INTEGER, size INTEGER, PRIMARY KEY(id,recipient));
                CREATE INDEX IF NOT EXISTS mailbox ON envelopes(recipient,expires);
                CREATE TABLE IF NOT EXISTS seen (id TEXT, recipient TEXT, digest TEXT, expires INTEGER, PRIMARY KEY(id,recipient));
                CREATE TABLE IF NOT EXISTS blocks (owner TEXT, peer TEXT, PRIMARY KEY(owner,peer));
                CREATE TABLE IF NOT EXISTS codes (code TEXT PRIMARY KEY, identity TEXT UNIQUE NOT NULL);
                CREATE INDEX IF NOT EXISTS code_identity ON codes(identity);
                CREATE TABLE IF NOT EXISTS rates (bucket TEXT PRIMARY KEY, count INTEGER, expires INTEGER);
            ''')

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.path, timeout=20)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def rate(self, key, limit, window=60):
        now = int(time.time())
        bucket = f'{key}:{now // window}'
        with self.db() as db:
            db.execute('DELETE FROM rates WHERE expires < ?', (now,))
            db.execute('INSERT INTO rates VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=count+1', (bucket, now + window * 2))
            count = db.execute('SELECT count FROM rates WHERE bucket=?', (bucket,)).fetchone()[0]
        if count > limit:
            raise APIError(429, 'Too many requests. Try again later.')

    def clean(self, db):
        now = int(time.time())
        for table in ('challenges', 'sessions', 'envelopes', 'seen'):
            db.execute(f'DELETE FROM {table} WHERE expires <= ?', (now,))

    def user(self, env, db):
        auth = env.get('HTTP_AUTHORIZATION', '')
        if not auth.startswith('Bearer '):
            raise APIError(401, 'Authentication required')
        digest = hashlib.sha256(auth[7:].encode()).hexdigest()
        row = db.execute('SELECT identity FROM sessions WHERE digest=? AND expires>?', (digest, int(time.time()))).fetchone()
        if not row:
            raise APIError(401, 'Session expired')
        return row[0]

    def dispatch(self, env, body):
        method, path = env['REQUEST_METHOD'], env.get('PATH_INFO', '/')
        now = int(time.time())
        # Only the immediate peer is used; untrusted forwarded headers never bypass limits.
        ip_hash = hashlib.sha256(env.get('REMOTE_ADDR', '').encode()).hexdigest()
        if method == 'GET' and path == '/health':
            return {'status': 'ok', 'protocol': 1}
        if path in ('/v1/register', '/v1/challenge', '/v1/session'):
            self.rate('auth:' + ip_hash, 90)
        if path == '/v1/register':
            self.rate('register:' + ip_hash, 30, 3600)
        public = path in ('/v1/register', '/v1/challenge', '/v1/session')
        if not public:
            with self.db() as auth_db:
                user = self.user(env, auth_db)
            self.rate('user:' + user, 240)
        with self.db() as db:
            self.clean(db)
            if method == 'POST' and path == '/v1/register':
                card = verify_card(body)
                old = db.execute('SELECT card FROM identities WHERE id=?', (card['id'],)).fetchone()
                if old and json.loads(old[0]) != card:
                    raise APIError(409, 'Identity already bound to different keys')
                db.execute('INSERT OR IGNORE INTO identities VALUES (?,?)', (card['id'], json.dumps(card)))
                return {'ok': True}
            if method == 'POST' and path == '/v1/challenge':
                identity = body.get('id', '')
                if not isinstance(identity, str) or not ID.fullmatch(identity):
                    raise APIError(400, 'Invalid identity')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (identity,)).fetchone():
                    raise APIError(404, 'Unknown identity')
                nonce = secrets.token_urlsafe(32)
                db.execute('INSERT INTO challenges VALUES (?,?,?)', (nonce, identity, now + 120))
                return {'nonce': nonce}
            if method == 'POST' and path == '/v1/session':
                nonce = body.get('nonce', '')
                identity = body.get('id', '')
                row = db.execute('SELECT card FROM identities WHERE id=?', (identity,)).fetchone()
                challenge = db.execute('SELECT 1 FROM challenges WHERE nonce=? AND identity=? AND expires>?', (nonce, identity, now)).fetchone()
                if not row or not challenge:
                    raise APIError(401, 'Invalid or expired challenge')
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(body.get('signature'), 64), f'VO1D-AUTH-1\n{identity}\n{nonce}'.encode())
                except InvalidSignature:
                    raise APIError(401, 'Invalid signature')
                # DELETE condition makes concurrent replay lose, even under multiple workers.
                if db.execute('DELETE FROM challenges WHERE nonce=?', (nonce,)).rowcount != 1:
                    raise APIError(401, 'Challenge already consumed')
                token = secrets.token_urlsafe(32)
                db.execute('INSERT INTO sessions VALUES (?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), identity, now + 86400))
                return {'token': token}
            if method == 'POST' and path == '/v1/code':
                existing = db.execute('SELECT code FROM codes WHERE identity=?', (user,)).fetchone()
                if existing:
                    return {'code': existing[0]}
                for _ in range(128):
                    code = ''.join(secrets.choice(CODE_ALPHABET) for _ in range(4))
                    try:
                        db.execute('INSERT INTO codes(code,identity) VALUES (?,?)', (code, user))
                        return {'code': code}
                    except sqlite3.IntegrityError:
                        continue
                raise APIError(500, 'Unable to allocate compact ID')
            if method == 'GET' and path.startswith('/v1/code/'):
                code = path.rsplit('/', 1)[1].upper()
                if not CODE.fullmatch(code):
                    raise APIError(400, 'Invalid compact ID')
                row = db.execute('SELECT i.card FROM codes c JOIN identities i ON i.id=c.identity WHERE c.code=?', (code,)).fetchone()
                if not row:
                    raise APIError(404, 'Compact ID not found')
                return json.loads(row[0])
            if method == 'GET' and path.startswith('/v1/identity/'):
                row = db.execute('SELECT card FROM identities WHERE id=?', (path.rsplit('/', 1)[1],)).fetchone()
                if not row:
                    raise APIError(404, 'Contact is not registered on this relay')
                return json.loads(row[0])
            if method == 'POST' and path == '/v1/envelopes':
                e = body
                keys = ('id', 'sender', 'recipient', 'ephemeralKey', 'salt', 'ciphertext', 'signature')
                if not all(isinstance(e.get(k), str) for k in keys) or type(e.get('expiresAt')) is not int:
                    raise APIError(400, 'Invalid envelope')
                if not UUID.fullmatch(e['id']) or e['sender'] != user or not ID.fullmatch(e['recipient']):
                    raise APIError(400, 'Invalid envelope identity')
                if not now < e['expiresAt'] <= now + RETENTION + 60:
                    raise APIError(400, 'Invalid expiry')
                b64(e['ephemeralKey'], 32)
                b64(e['salt'], 32)
                cipher = b64(e['ciphertext'])
                if not 28 <= len(cipher) <= MAX_ENVELOPE:
                    raise APIError(413, 'Message exceeds size limit')
                row = db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(e['signature'], 64), header_bytes(e) + b'\n' + cipher)
                except InvalidSignature:
                    raise APIError(403, 'Invalid envelope signature')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (e['recipient'],)).fetchone():
                    raise APIError(404, 'Recipient not registered')
                if db.execute('SELECT 1 FROM blocks WHERE owner=? AND peer=?', (e['recipient'], user)).fetchone():
                    # Do not expose whether the recipient has blocked this sender.
                    return {'ok': True}
                encoded = json.dumps({k: e[k] for k in (*keys, 'expiresAt')}, separators=(',', ':'))
                digest = hashlib.sha256(encoded.encode()).hexdigest()
                old = db.execute('SELECT digest FROM seen WHERE id=? AND recipient=?', (e['id'], e['recipient'])).fetchone()
                if old:
                    if old[0] != digest:
                        raise APIError(409, 'Envelope ID collision')
                    return {'ok': True}
                count, size = db.execute('SELECT count(*), coalesce(sum(size),0) FROM envelopes WHERE recipient=?', (e['recipient'],)).fetchone()
                if count >= 1000 or size + len(encoded) > 100 * 1024 * 1024:
                    raise APIError(429, 'Recipient mailbox is full')
                db.execute('INSERT INTO envelopes VALUES (?,?,?,?,?,?)', (e['id'], e['recipient'], user, encoded, e['expiresAt'], len(encoded)))
                db.execute('INSERT INTO seen VALUES (?,?,?,?)', (e['id'], e['recipient'], digest, e['expiresAt']))
                return {'ok': True}
            if method == 'GET' and path == '/v1/inbox':
                rows = db.execute('SELECT body FROM envelopes WHERE recipient=? ORDER BY rowid LIMIT 10', (user,)).fetchall()
                return {'envelopes': [json.loads(row[0]) for row in rows]}
            if method == 'POST' and path == '/v1/ack':
                ids = body.get('ids')
                if not isinstance(ids, list) or len(ids) > 100 or not all(isinstance(i, str) for i in ids):
                    raise APIError(400, 'Invalid acknowledgement')
                db.executemany('DELETE FROM envelopes WHERE id=? AND recipient=?', [(i, user) for i in ids])
                return {'ok': True}
            if method == 'POST' and path == '/v1/block':
                peer = body.get('id', '')
                if not isinstance(peer, str) or not ID.fullmatch(peer):
                    raise APIError(400, 'Invalid contact')
                if body.get('blocked', True):
                    db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?)', (user, peer))
                    db.execute('DELETE FROM envelopes WHERE recipient=? AND sender=?', (user, peer))
                else:
                    db.execute('DELETE FROM blocks WHERE owner=? AND peer=?', (user, peer))
                return {'ok': True}
            if method == 'DELETE' and path == '/v1/account':
                db.execute('DELETE FROM envelopes WHERE sender=? OR recipient=?', (user, user))
                db.execute('DELETE FROM seen WHERE recipient=?', (user,))
                db.execute('DELETE FROM blocks WHERE owner=? OR peer=?', (user, user))
                db.execute('DELETE FROM codes WHERE identity=?', (user,))
                db.execute('DELETE FROM sessions WHERE identity=?', (user,))
                db.execute('DELETE FROM challenges WHERE identity=?', (user,))
                db.execute('DELETE FROM identities WHERE id=?', (user,))
                return {'ok': True}
            raise APIError(404, 'Not found')

    def __call__(self, env, start_response):
        try:
            length = int(env.get('CONTENT_LENGTH') or 0)
            if length < 0 or length > MAX_BODY:
                raise APIError(413, 'Request too large')
            if env['REQUEST_METHOD'] == 'POST' and env.get('CONTENT_TYPE', '').split(';')[0] != 'application/json':
                raise APIError(415, 'JSON required')
            body = json.loads(env['wsgi.input'].read(length)) if length else {}
            if not isinstance(body, dict):
                raise APIError(400, 'JSON object required')
            result = self.dispatch(env, body)
            status = 200
        except APIError as e:
            result, status = {'error': e.message}, e.status
        except (ValueError, TypeError, KeyError, UnicodeError):
            result, status = {'error': 'Invalid request'}, 400
        except Exception:
            # No raw requests, tokens, identifiers or traceback are logged.
            result, status = {'error': 'Relay unavailable'}, 500
        payload = json.dumps(result, separators=(',', ':')).encode()
        reason = {200:'OK',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',409:'Conflict',413:'Payload Too Large',415:'Unsupported Media Type',429:'Too Many Requests',500:'Internal Server Error'}[status]
        start_response(f'{status} {reason}', [('Content-Type','application/json'),('Content-Length',str(len(payload))),('Cache-Control','no-store'),('X-Content-Type-Options','nosniff')])
        return [payload]


def create_app():
    return Relay()


if __name__ == '__main__':
    from wsgiref.simple_server import make_server, WSGIRequestHandler
    class QuietHandler(WSGIRequestHandler):
        def log_message(self, *args):
            pass
    print('VO1D development relay: http://127.0.0.1:8080 (production: use Docker + TLS)')
    make_server('0.0.0.0', 8080, create_app(), handler_class=QuietHandler).serve_forever()
)
RESERVED_USERNAMES = {'vo1d','xrosb','admin','administrator','support','system','security','moderator','official'}
UUID = re.compile(r'^[A-Za-z0-9-]{16,64}$')
MAX_BODY = 9 * 1024 * 1024
MAX_ENVELOPE = 7 * 1024 * 1024
RETENTION = 7 * 86400

class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def b64(value, length=None):
    if not isinstance(value, str):
        raise APIError(400, 'Invalid base64')
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise APIError(400, 'Invalid base64')
    if length is not None and len(result) != length:
        raise APIError(400, 'Invalid key length')
    return result


def card_bytes(card):
    return f"VO1D-CARD-1\n{card['id']}\n{card['signingKey']}\n{card['agreementKey']}".encode()


def verify_card(card):
    if not isinstance(card, dict) or not all(isinstance(card.get(k), str) for k in ('id', 'signingKey', 'agreementKey', 'binding')):
        raise APIError(400, 'Invalid identity')
    signing = b64(card['signingKey'], 32)
    b64(card['agreementKey'], 32)
    if hashlib.sha256(signing).hexdigest() != card['id']:
        raise APIError(400, 'Identity fingerprint mismatch')
    try:
        Ed25519PublicKey.from_public_bytes(signing).verify(b64(card['binding'], 64), card_bytes(card))
    except InvalidSignature:
        raise APIError(400, 'Invalid identity signature')
    return {k: card[k] for k in ('id', 'signingKey', 'agreementKey', 'binding')}


def header_bytes(e):
    return f"VO1D-ENVELOPE-1\n{e['id']}\n{e['sender']}\n{e['recipient']}\n{e['ephemeralKey']}\n{e['salt']}\n{e['expiresAt']}".encode()


class Relay:
    def __init__(self, path=None):
        self.path = str(path or os.environ.get('VO1D_DB', './data/relay.sqlite3'))
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS identities (id TEXT PRIMARY KEY, card TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS challenges (nonce TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, identity TEXT, expires INTEGER);
                CREATE TABLE IF NOT EXISTS envelopes (id TEXT, recipient TEXT, sender TEXT, body TEXT, expires INTEGER, size INTEGER, PRIMARY KEY(id,recipient));
                CREATE INDEX IF NOT EXISTS mailbox ON envelopes(recipient,expires);
                CREATE TABLE IF NOT EXISTS seen (id TEXT, recipient TEXT, digest TEXT, expires INTEGER, PRIMARY KEY(id,recipient));
                CREATE TABLE IF NOT EXISTS blocks (owner TEXT, peer TEXT, PRIMARY KEY(owner,peer));
                CREATE TABLE IF NOT EXISTS codes (code TEXT PRIMARY KEY, identity TEXT UNIQUE NOT NULL);
                CREATE INDEX IF NOT EXISTS code_identity ON codes(identity);
                CREATE TABLE IF NOT EXISTS rates (bucket TEXT PRIMARY KEY, count INTEGER, expires INTEGER);
            ''')

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.path, timeout=20)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def rate(self, key, limit, window=60):
        now = int(time.time())
        bucket = f'{key}:{now // window}'
        with self.db() as db:
            db.execute('DELETE FROM rates WHERE expires < ?', (now,))
            db.execute('INSERT INTO rates VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=count+1', (bucket, now + window * 2))
            count = db.execute('SELECT count FROM rates WHERE bucket=?', (bucket,)).fetchone()[0]
        if count > limit:
            raise APIError(429, 'Too many requests. Try again later.')

    def clean(self, db):
        now = int(time.time())
        for table in ('challenges', 'sessions', 'envelopes', 'seen'):
            db.execute(f'DELETE FROM {table} WHERE expires <= ?', (now,))

    def user(self, env, db):
        auth = env.get('HTTP_AUTHORIZATION', '')
        if not auth.startswith('Bearer '):
            raise APIError(401, 'Authentication required')
        digest = hashlib.sha256(auth[7:].encode()).hexdigest()
        row = db.execute('SELECT identity FROM sessions WHERE digest=? AND expires>?', (digest, int(time.time()))).fetchone()
        if not row:
            raise APIError(401, 'Session expired')
        return row[0]

    def dispatch(self, env, body):
        method, path = env['REQUEST_METHOD'], env.get('PATH_INFO', '/')
        now = int(time.time())
        # Only the immediate peer is used; untrusted forwarded headers never bypass limits.
        ip_hash = hashlib.sha256(env.get('REMOTE_ADDR', '').encode()).hexdigest()
        if method == 'GET' and path == '/health':
            return {'status': 'ok', 'protocol': 1}
        if path in ('/v1/register', '/v1/challenge', '/v1/session'):
            self.rate('auth:' + ip_hash, 90)
        if path == '/v1/register':
            self.rate('register:' + ip_hash, 30, 3600)
        public = path in ('/v1/register', '/v1/challenge', '/v1/session')
        if not public:
            with self.db() as auth_db:
                user = self.user(env, auth_db)
            self.rate('user:' + user, 240)
        with self.db() as db:
            self.clean(db)
            if method == 'POST' and path == '/v1/register':
                card = verify_card(body)
                old = db.execute('SELECT card FROM identities WHERE id=?', (card['id'],)).fetchone()
                if old and json.loads(old[0]) != card:
                    raise APIError(409, 'Identity already bound to different keys')
                db.execute('INSERT OR IGNORE INTO identities VALUES (?,?)', (card['id'], json.dumps(card)))
                return {'ok': True}
            if method == 'POST' and path == '/v1/challenge':
                identity = body.get('id', '')
                if not isinstance(identity, str) or not ID.fullmatch(identity):
                    raise APIError(400, 'Invalid identity')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (identity,)).fetchone():
                    raise APIError(404, 'Unknown identity')
                nonce = secrets.token_urlsafe(32)
                db.execute('INSERT INTO challenges VALUES (?,?,?)', (nonce, identity, now + 120))
                return {'nonce': nonce}
            if method == 'POST' and path == '/v1/session':
                nonce = body.get('nonce', '')
                identity = body.get('id', '')
                row = db.execute('SELECT card FROM identities WHERE id=?', (identity,)).fetchone()
                challenge = db.execute('SELECT 1 FROM challenges WHERE nonce=? AND identity=? AND expires>?', (nonce, identity, now)).fetchone()
                if not row or not challenge:
                    raise APIError(401, 'Invalid or expired challenge')
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(body.get('signature'), 64), f'VO1D-AUTH-1\n{identity}\n{nonce}'.encode())
                except InvalidSignature:
                    raise APIError(401, 'Invalid signature')
                # DELETE condition makes concurrent replay lose, even under multiple workers.
                if db.execute('DELETE FROM challenges WHERE nonce=?', (nonce,)).rowcount != 1:
                    raise APIError(401, 'Challenge already consumed')
                token = secrets.token_urlsafe(32)
                db.execute('INSERT INTO sessions VALUES (?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), identity, now + 86400))
                return {'token': token}
            if method == 'POST' and path == '/v1/code':
                existing = db.execute('SELECT code FROM codes WHERE identity=?', (user,)).fetchone()
                if existing:
                    return {'code': existing[0]}
                for _ in range(128):
                    code = ''.join(secrets.choice(CODE_ALPHABET) for _ in range(4))
                    try:
                        db.execute('INSERT INTO codes(code,identity) VALUES (?,?)', (code, user))
                        return {'code': code}
                    except sqlite3.IntegrityError:
                        continue
                raise APIError(500, 'Unable to allocate compact ID')
            if method == 'GET' and path.startswith('/v1/code/'):
                code = path.rsplit('/', 1)[1].upper()
                if not CODE.fullmatch(code):
                    raise APIError(400, 'Invalid compact ID')
                row = db.execute('SELECT i.card FROM codes c JOIN identities i ON i.id=c.identity WHERE c.code=?', (code,)).fetchone()
                if not row:
                    raise APIError(404, 'Compact ID not found')
                return json.loads(row[0])
            if method == 'GET' and path.startswith('/v1/identity/'):
                row = db.execute('SELECT card FROM identities WHERE id=?', (path.rsplit('/', 1)[1],)).fetchone()
                if not row:
                    raise APIError(404, 'Contact is not registered on this relay')
                return json.loads(row[0])
            if method == 'POST' and path == '/v1/envelopes':
                e = body
                keys = ('id', 'sender', 'recipient', 'ephemeralKey', 'salt', 'ciphertext', 'signature')
                if not all(isinstance(e.get(k), str) for k in keys) or type(e.get('expiresAt')) is not int:
                    raise APIError(400, 'Invalid envelope')
                if not UUID.fullmatch(e['id']) or e['sender'] != user or not ID.fullmatch(e['recipient']):
                    raise APIError(400, 'Invalid envelope identity')
                if not now < e['expiresAt'] <= now + RETENTION + 60:
                    raise APIError(400, 'Invalid expiry')
                b64(e['ephemeralKey'], 32)
                b64(e['salt'], 32)
                cipher = b64(e['ciphertext'])
                if not 28 <= len(cipher) <= MAX_ENVELOPE:
                    raise APIError(413, 'Message exceeds size limit')
                row = db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()
                card = json.loads(row[0])
                try:
                    Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(e['signature'], 64), header_bytes(e) + b'\n' + cipher)
                except InvalidSignature:
                    raise APIError(403, 'Invalid envelope signature')
                if not db.execute('SELECT 1 FROM identities WHERE id=?', (e['recipient'],)).fetchone():
                    raise APIError(404, 'Recipient not registered')
                if db.execute('SELECT 1 FROM blocks WHERE owner=? AND peer=?', (e['recipient'], user)).fetchone():
                    # Do not expose whether the recipient has blocked this sender.
                    return {'ok': True}
                encoded = json.dumps({k: e[k] for k in (*keys, 'expiresAt')}, separators=(',', ':'))
                digest = hashlib.sha256(encoded.encode()).hexdigest()
                old = db.execute('SELECT digest FROM seen WHERE id=? AND recipient=?', (e['id'], e['recipient'])).fetchone()
                if old:
                    if old[0] != digest:
                        raise APIError(409, 'Envelope ID collision')
                    return {'ok': True}
                count, size = db.execute('SELECT count(*), coalesce(sum(size),0) FROM envelopes WHERE recipient=?', (e['recipient'],)).fetchone()
                if count >= 1000 or size + len(encoded) > 100 * 1024 * 1024:
                    raise APIError(429, 'Recipient mailbox is full')
                db.execute('INSERT INTO envelopes VALUES (?,?,?,?,?,?)', (e['id'], e['recipient'], user, encoded, e['expiresAt'], len(encoded)))
                db.execute('INSERT INTO seen VALUES (?,?,?,?)', (e['id'], e['recipient'], digest, e['expiresAt']))
                return {'ok': True}
            if method == 'GET' and path == '/v1/inbox':
                rows = db.execute('SELECT body FROM envelopes WHERE recipient=? ORDER BY rowid LIMIT 10', (user,)).fetchall()
                return {'envelopes': [json.loads(row[0]) for row in rows]}
            if method == 'POST' and path == '/v1/ack':
                ids = body.get('ids')
                if not isinstance(ids, list) or len(ids) > 100 or not all(isinstance(i, str) for i in ids):
                    raise APIError(400, 'Invalid acknowledgement')
                db.executemany('DELETE FROM envelopes WHERE id=? AND recipient=?', [(i, user) for i in ids])
                return {'ok': True}
            if method == 'POST' and path == '/v1/block':
                peer = body.get('id', '')
                if not isinstance(peer, str) or not ID.fullmatch(peer):
                    raise APIError(400, 'Invalid contact')
                if body.get('blocked', True):
                    db.execute('INSERT OR IGNORE INTO blocks VALUES (?,?)', (user, peer))
                    db.execute('DELETE FROM envelopes WHERE recipient=? AND sender=?', (user, peer))
                else:
                    db.execute('DELETE FROM blocks WHERE owner=? AND peer=?', (user, peer))
                return {'ok': True}
            if method == 'DELETE' and path == '/v1/account':
                db.execute('DELETE FROM envelopes WHERE sender=? OR recipient=?', (user, user))
                db.execute('DELETE FROM seen WHERE recipient=?', (user,))
                db.execute('DELETE FROM blocks WHERE owner=? OR peer=?', (user, user))
                db.execute('DELETE FROM codes WHERE identity=?', (user,))
                db.execute('DELETE FROM sessions WHERE identity=?', (user,))
                db.execute('DELETE FROM challenges WHERE identity=?', (user,))
                db.execute('DELETE FROM identities WHERE id=?', (user,))
                return {'ok': True}
            raise APIError(404, 'Not found')

    def __call__(self, env, start_response):
        try:
            length = int(env.get('CONTENT_LENGTH') or 0)
            if length < 0 or length > MAX_BODY:
                raise APIError(413, 'Request too large')
            if env['REQUEST_METHOD'] == 'POST' and env.get('CONTENT_TYPE', '').split(';')[0] != 'application/json':
                raise APIError(415, 'JSON required')
            body = json.loads(env['wsgi.input'].read(length)) if length else {}
            if not isinstance(body, dict):
                raise APIError(400, 'JSON object required')
            result = self.dispatch(env, body)
            status = 200
        except APIError as e:
            result, status = {'error': e.message}, e.status
        except (ValueError, TypeError, KeyError, UnicodeError):
            result, status = {'error': 'Invalid request'}, 400
        except Exception:
            # No raw requests, tokens, identifiers or traceback are logged.
            result, status = {'error': 'Relay unavailable'}, 500
        payload = json.dumps(result, separators=(',', ':')).encode()
        reason = {200:'OK',400:'Bad Request',401:'Unauthorized',403:'Forbidden',404:'Not Found',409:'Conflict',413:'Payload Too Large',415:'Unsupported Media Type',429:'Too Many Requests',500:'Internal Server Error'}[status]
        start_response(f'{status} {reason}', [('Content-Type','application/json'),('Content-Length',str(len(payload))),('Cache-Control','no-store'),('X-Content-Type-Options','nosniff')])
        return [payload]


def create_app():
    return Relay()


if __name__ == '__main__':
    from wsgiref.simple_server import make_server, WSGIRequestHandler
    class QuietHandler(WSGIRequestHandler):
        def log_message(self, *args):
            pass
    print('VO1D development relay: http://127.0.0.1:8080 (production: use Docker + TLS)')
    make_server('0.0.0.0', 8080, create_app(), handler_class=QuietHandler).serve_forever()
