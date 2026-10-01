"""Unlinked blob reservations with separate upload, read and deletion capabilities.

Only ciphertext metadata and capability digests are stored. This does not hide
traffic timing, IP addresses or file sizes from the operator.
"""
import hashlib
import hmac
import os
import re
import time

TOKEN = re.compile(r'^[A-Za-z0-9_-]{43}$')
HEX = re.compile(r'^[a-f0-9]{64}$')
MAX_BYTES = 50 * 1024 * 1024 + 64


def work_bits():
    return max(18, min(24, int(os.environ.get('VO1D_MAILBOX_POW_BITS', '18'))))


def install(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS private_blobs (
          id TEXT PRIMARY KEY, upload_digest TEXT NOT NULL, read_digest TEXT NOT NULL,
          delete_digest TEXT NOT NULL, size INTEGER NOT NULL, digest TEXT NOT NULL,
          expires INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0,
          lease INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS private_blob_expiry ON private_blobs(expires);
        CREATE TABLE IF NOT EXISTS private_blob_seen (id TEXT PRIMARY KEY, expires INTEGER NOT NULL, delete_digest TEXT NOT NULL);
    ''')
    if 'delete_digest' not in {r[1] for r in db.execute('PRAGMA table_info(private_blob_seen)')}:
        db.execute("ALTER TABLE private_blob_seen ADD COLUMN delete_digest TEXT NOT NULL DEFAULT ''")


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def authorize(db, blob_id, auth, scope, error):
    if not TOKEN.fullmatch(blob_id) or not auth.startswith('BlobCapability ') or not TOKEN.fullmatch(auth[15:]):
        raise error(401, 'Blob capability required')
    row = db.execute('SELECT * FROM private_blobs WHERE id=? AND expires>?', (blob_id, int(time.time()))).fetchone()
    if row is None and scope == 'delete':
        retired = db.execute('SELECT delete_digest FROM private_blob_seen WHERE id=? AND expires>?',(blob_id,int(time.time()))).fetchone()
        if retired and hmac.compare_digest(retired[0],digest(auth[15:])): return None
    if row is None or not hmac.compare_digest(row[scope + '_digest'], digest(auth[15:])):
        raise error(403, 'Invalid or expired blob capability')
    return row


def ticket(relay, body, ip_hash, error):
    relay.rate('private-blob-ticket:' + ip_hash, 24, 3600)
    fields = {'id', 'uploadToken', 'readToken', 'deleteToken', 'size', 'digest', 'expiresAt', 'proof'}
    if not isinstance(body, dict) or set(body) != fields:
        raise error(400, 'Invalid blob reservation')
    for key in ('id', 'uploadToken', 'readToken', 'deleteToken'):
        if not isinstance(body[key], str) or not TOKEN.fullmatch(body[key]):
            raise error(400, 'Invalid blob capability')
    if len({body[k] for k in ('uploadToken', 'readToken', 'deleteToken')}) != 3:
        raise error(400, 'Distinct blob capabilities required')
    now, expiry = int(time.time()), body['expiresAt']
    if type(body['size']) is not int or not 29 <= body['size'] <= MAX_BYTES:
        raise error(413, 'Blob exceeds size limit')
    if type(expiry) is not int or not now + 60 <= expiry <= now + 7 * 86400:
        raise error(400, 'Invalid blob expiry')
    if not isinstance(body['digest'], str) or not HEX.fullmatch(body['digest']):
        raise error(400, 'Invalid blob digest')
    if not isinstance(body['proof'], str) or not re.fullmatch('[0-9]{1,20}', body['proof']):
        raise error(400, 'Invalid work proof')
    signed = f"VO1D-BLOB-WORK-2\n{body['id']}\n{body['size']}\n{body['digest']}\n{expiry}\n{body['proof']}".encode()
    if int.from_bytes(hashlib.sha256(signed).digest(), 'big') >> (256 - work_bits()):
        raise error(403, 'Blob work proof rejected')
    values = (body['id'], digest(body['uploadToken']), digest(body['readToken']), digest(body['deleteToken']), body['size'], body['digest'], expiry)
    with relay.db() as db:
        db.execute('BEGIN IMMEDIATE')
        old = db.execute('SELECT id,upload_digest,read_digest,delete_digest,size,digest,expires FROM private_blobs WHERE id=?', (body['id'],)).fetchone()
        if old:
            if tuple(old) != values:
                raise error(409, 'Blob reservation collision')
        else:
            if db.execute('SELECT 1 FROM private_blob_seen WHERE id=?', (body['id'],)).fetchone():
                raise error(409, 'Blob reservation revoked')
            count, size = db.execute('SELECT count(*),coalesce(sum(size),0) FROM private_blobs WHERE expires>?', (now,)).fetchone()
            quota = max(MAX_BYTES, int(os.environ.get('VO1D_PRIVATE_BLOB_QUOTA', str(1024 * 1024 * 1024))))
            if count >= 1000 or size + body['size'] > quota:
                raise error(429, 'Private blob storage quota reached')
            db.execute('INSERT INTO private_blobs(id,upload_digest,read_digest,delete_digest,size,digest,expires) VALUES (?,?,?,?,?,?,?)', values)
            db.execute('INSERT INTO private_blob_seen VALUES (?,?,?)', (body['id'], expiry,digest(body['deleteToken'])))
    return {'id': body['id'], 'size': body['size'], 'digest': body['digest'], 'expiresAt': expiry}
