"""Single-use, operator-issued Premium/collectible vouchers. No payment simulation.
A payment adapter may issue a voucher only after independently verifying settlement.
"""
import base64
import hashlib
import json
import os
import re
import secrets
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def install(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS commerce_vouchers (
        digest TEXT PRIMARY KEY, kind TEXT NOT NULL, days INTEGER NOT NULL,
        label TEXT NOT NULL, symbol TEXT NOT NULL, expires INTEGER NOT NULL,
        owner TEXT, used_by TEXT, receipt TEXT);
      CREATE TABLE IF NOT EXISTS commerce_receipts (
        id TEXT PRIMARY KEY, owner TEXT NOT NULL, body TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS commerce_owner ON commerce_receipts(owner);
    ''')


def signing_key():
    value = os.environ.get('VO1D_COMMERCE_SIGNING_KEY', '')
    if not value:
        return None
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode(value, validate=True))


def public_key():
    key = signing_key()
    return base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode() if key else None


def signed_bytes(receipt):
    return (f"VO1D-COMMERCE-1\n{receipt['kind']}\n{receipt['id']}\n{receipt['owner']}\n"
            f"{receipt['expiresAt']}\n{base64.b64encode(receipt['label'].encode()).decode()}\n{receipt['symbol']}").encode()


def issue(db, kind, days=30, label='VO1D PREMIUM', symbol='sparkles', owner=None):
    if kind not in ('premium', 'collectible') or not 1 <= days <= 366:
        raise ValueError('Invalid voucher')
    if owner is not None and not re.fullmatch('[a-f0-9]{64}', owner):
        raise ValueError('Invalid owner')
    if not 1 <= len(label) <= 40 or symbol not in ('sparkles', 'moon.stars.fill', 'diamond.fill', 'flame.fill', 'bolt.fill'):
        raise ValueError('Invalid collectible')
    code = secrets.token_urlsafe(32)
    db.execute('INSERT INTO commerce_vouchers VALUES (?,?,?,?,?,?,?,NULL,NULL)',
               (hashlib.sha256(code.encode()).hexdigest(), kind, days, label, symbol, int(time.time()) + 7*86400, owner))
    return code


def handle(db, user, env, body, error):
    path, method = env['PATH_INFO'], env['REQUEST_METHOD']
    if method == 'GET' and path == '/v2/commerce':
        return {'enabled': signing_key() is not None, 'issuer': public_key(),
                'receipts': [json.loads(r[0]) for r in db.execute('SELECT body FROM commerce_receipts WHERE owner=?', (user,))]}
    if path != '/v2/commerce/redeem' or method != 'POST':
        return None
    key = signing_key()
    if key is None:
        raise error(503, 'Premium issuer is not configured')
    code = body.get('code')
    if not isinstance(code, str) or not re.fullmatch('[A-Za-z0-9_-]{43}', code):
        raise error(400, 'Invalid voucher')
    digest = hashlib.sha256(code.encode()).hexdigest()
    now = int(time.time())
    # Acquire the writer lock before reading/stacking entitlements. Exact retries
    # return the same receipt; another identity cannot reuse the voucher.
    db.execute('UPDATE commerce_vouchers SET digest=digest WHERE digest=?', (digest,))
    row = db.execute('SELECT * FROM commerce_vouchers WHERE digest=?', (digest,)).fetchone()
    if row is None or (row['owner'] is not None and row['owner'] != user):
        raise error(404, 'Voucher unavailable')
    if row['used_by'] is not None:
        if row['used_by'] != user:
            raise error(409, 'Voucher already redeemed')
        return json.loads(row['receipt'])
    if row['expires'] <= now:
        raise error(410, 'Voucher expired')
    if db.execute('SELECT count(*) FROM commerce_receipts WHERE owner=?', (user,)).fetchone()[0] >= 200:
        raise error(429, 'Receipt limit')
    previous = [json.loads(r[0]) for r in db.execute('SELECT body FROM commerce_receipts WHERE owner=?', (user,))]
    until = max([now] + [r['expiresAt'] for r in previous if r['kind'] == 'premium'])
    receipt = dict(kind=row['kind'], id=secrets.token_hex(16), owner=user,
                   expiresAt=until + row['days']*86400 if row['kind'] == 'premium' else 0,
                   label=row['label'], symbol=row['symbol'])
    receipt['signature'] = base64.b64encode(key.sign(signed_bytes(receipt))).decode()
    encoded = json.dumps(receipt)
    db.execute('INSERT INTO commerce_receipts VALUES (?,?,?)', (receipt['id'], user, encoded))
    db.execute('UPDATE commerce_vouchers SET used_by=?,receipt=? WHERE digest=?', (user, encoded, digest))
    return receipt
