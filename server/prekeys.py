"""Bound PQXDH bundles. One-use withdrawal and publication are transactional.

The relay verifies the account binding and complete bundle with Ed25519. XEdDSA
and Kyber signatures are verified by libsignal on the recipient, not reimplemented.
"""
import hashlib
import json
import re
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

FIELDS = ('owner','identityKey','identityBinding','registrationId','deviceId',
          'signedPrekeyId','signedPrekey','signedPrekeySignature','prekeyId','prekey',
          'kyberPrekeyId','kyberPrekey','kyberPrekeySignature','expiresAt')


def signed_bytes(bundle):
    return ('VO1D-PREKEY-2\n' + '\n'.join(str(bundle[k]) for k in FIELDS)).encode()


def install(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS signal_identities (
          owner TEXT PRIMARY KEY, public_key TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS signal_prekeys (
          owner TEXT, key_id INTEGER, body TEXT NOT NULL, digest TEXT NOT NULL,
          expires INTEGER NOT NULL, claimed INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(owner,key_id));
        CREATE INDEX IF NOT EXISTS signal_available ON signal_prekeys(owner,claimed,expires);
    ''')


def clean(db, now):
    db.execute('DELETE FROM signal_prekeys WHERE expires<=?', (now,))


def erase(db, owner):
    db.execute('DELETE FROM signal_prekeys WHERE owner=?', (owner,))
    db.execute('DELETE FROM signal_identities WHERE owner=?', (owner,))


def handle(db, user, env, body, error, decode):
    method, path = env['REQUEST_METHOD'], env['PATH_INFO']
    now = int(time.time())
    if method == 'GET' and path == '/v2/prekeys':
        count = db.execute('SELECT count(*) FROM signal_prekeys WHERE owner=? AND claimed=0 AND expires>?', (user, now)).fetchone()[0]
        return {'available': count, 'protocol': 2}
    if method == 'POST' and path == '/v2/prekeys':
        bundles = body.get('bundles')
        if not isinstance(bundles, list) or not 1 <= len(bundles) <= 48:
            raise error(400, 'Expected 1 to 48 key bundles')
        card = json.loads(db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()[0])
        signer = Ed25519PublicKey.from_public_bytes(decode(card['signingKey'], 32))
        validated = []
        ids = set()
        public_key = None
        for bundle in bundles:
            if not isinstance(bundle, dict) or set(bundle) != set(FIELDS) | {'signature'}:
                raise error(400, 'Invalid key bundle fields')
            for key in ('registrationId','deviceId','signedPrekeyId','prekeyId','kyberPrekeyId','expiresAt'):
                if type(bundle[key]) is not int or not 0 < bundle[key] < 2**32:
                    raise error(400, 'Invalid integer in key bundle')
            if bundle['owner'] != user or bundle['deviceId'] != 1 or not now < bundle['expiresAt'] <= now + 7 * 86400:
                raise error(400, 'Invalid owner, device or expiry')
            if bundle['prekeyId'] in ids:
                raise error(400, 'Duplicate one-use key')
            ids.add(bundle['prekeyId'])
            for field in ('identityKey','signedPrekey','prekey'):
                if decode(bundle[field],33)[0] != 5:
                    raise error(400, 'Invalid Signal public key')
            for field in ('identityBinding','signedPrekeySignature','kyberPrekeySignature','signature'):
                decode(bundle[field],64)
            if not 1000 <= len(decode(bundle['kyberPrekey'])) <= 2000:
                raise error(400, 'Invalid Kyber public key')
            if public_key is not None and public_key != bundle['identityKey']:
                raise error(400, 'Mixed Signal identities')
            public_key = bundle['identityKey']
            binding = f"VO1D-SIGNAL-IDENTITY-2\n{user}\n{public_key}".encode()
            try:
                signer.verify(decode(bundle['identityBinding'],64),binding)
                signer.verify(decode(bundle['signature'],64),signed_bytes(bundle))
            except InvalidSignature:
                raise error(403, 'Invalid key certificate')
            encoded = json.dumps(bundle,sort_keys=True,separators=(',',':'))
            digest = hashlib.sha256(encoded.encode()).hexdigest()
            old = db.execute('SELECT digest FROM signal_prekeys WHERE owner=? AND key_id=?',(user,bundle['prekeyId'])).fetchone()
            if old is not None and old[0] != digest:
                raise error(409,'One-use key ID already bound')
            validated.append((user,bundle['prekeyId'],encoded,digest,bundle['expiresAt']))
        old_identity = db.execute('SELECT public_key FROM signal_identities WHERE owner=?',(user,)).fetchone()
        if old_identity is not None and old_identity[0] != public_key:
            raise error(409,'Signal identity changed; create a separate profile instead')
        existing = db.execute('SELECT count(*) FROM signal_prekeys WHERE owner=?',(user,)).fetchone()[0]
        new = sum(db.execute('SELECT 1 FROM signal_prekeys WHERE owner=? AND key_id=?',(row[0],row[1])).fetchone() is None for row in validated)
        if existing + new > 512:
            raise error(429,'Prekey storage limit')
        db.execute('INSERT OR IGNORE INTO signal_identities VALUES (?,?)',(user,public_key))
        # Ignore exact retries, preserving the claimed flag rather than resurrecting keys.
        db.executemany('INSERT OR IGNORE INTO signal_prekeys(owner,key_id,body,digest,expires) VALUES (?,?,?,?,?)',validated)
        return {'ok':True}
    if method == 'POST' and path.startswith('/v2/prekeys/'):
        owner = path.rsplit('/',1)[1]
        if not re.fullmatch('[a-f0-9]{64}',owner):
            raise error(400,'Invalid recipient')
        if db.execute('SELECT 1 FROM blocks WHERE owner=? AND peer=?',(owner,user)).fetchone():
            raise error(404,'No prekeys available')
        # The first SQL statement is a write, acquiring the SQLite writer lock before selection.
        row = db.execute('''UPDATE signal_prekeys SET claimed=1 WHERE owner=? AND key_id=(
            SELECT key_id FROM signal_prekeys WHERE owner=? AND claimed=0 AND expires>? ORDER BY key_id LIMIT 1)
            AND claimed=0 RETURNING body''',(owner,owner,now)).fetchone()
        if row is None:
            raise error(404,'No fresh one-use prekeys; retry after the contact connects')
        return json.loads(row[0])
    return None
