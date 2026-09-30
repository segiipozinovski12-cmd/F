"""Authenticated privacy controls. Invitation secrets are stored only as hashes."""
import hashlib
import re
import secrets
import sqlite3
import time

TOKEN = re.compile(r'^[A-Za-z0-9_-]{43}$')
PUSH_TOKEN = re.compile(r'^[a-fA-F0-9]{64,512}$')


def install(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS privacy (
          identity TEXT PRIMARY KEY, discoverable INTEGER NOT NULL DEFAULT 1,
          inactivity INTEGER NOT NULL DEFAULT 0, last_active INTEGER NOT NULL,
          trusted_calls INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS invites (
          digest TEXT PRIMARY KEY, owner TEXT NOT NULL, expires INTEGER NOT NULL,
          remaining INTEGER NOT NULL, created INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS invite_owner ON invites(owner);
        CREATE TABLE IF NOT EXISTS trusted (owner TEXT, peer TEXT, PRIMARY KEY(owner,peer));
        CREATE TABLE IF NOT EXISTS push_tokens (
          identity TEXT, token TEXT, kind TEXT, environment TEXT, updated INTEGER,
          PRIMARY KEY(identity,token,kind));
    ''')


def erase(db, identity):
    db.execute('DELETE FROM envelopes WHERE sender=? OR recipient=?', (identity, identity))
    db.execute('DELETE FROM seen WHERE recipient=?', (identity,))
    for table, column in [('identities','id'),('privacy','identity'),('codes','identity'),
                          ('usernames','identity'),('sessions','identity'),('challenges','identity'),
                          ('invites','owner'),('push_tokens','identity'),('blobs','owner')]:
        db.execute(f'DELETE FROM {table} WHERE {column}=?', (identity,))
    for table in ('trusted','blocks'):
        db.execute(f'DELETE FROM {table} WHERE owner=? OR peer=?', (identity,identity))


def clean(db, now):
    db.execute('DELETE FROM invites WHERE expires<=? OR remaining<=0', (now,))
    db.execute('DELETE FROM rates WHERE expires<=?', (now,))
    for row in db.execute('SELECT identity FROM privacy WHERE inactivity>0 AND last_active+inactivity*86400<=?', (now,)).fetchall():
        erase(db, row[0])


def visible(db, identity):
    row = db.execute('SELECT discoverable FROM privacy WHERE identity=?', (identity,)).fetchone()
    return row is None or bool(row[0])


def handle(relay, db, user, env, body, error):
    method, path = env['REQUEST_METHOD'], env['PATH_INFO']
    now = int(time.time())
    if method == 'GET' and path == '/v1/privacy':
        row = db.execute('SELECT discoverable,inactivity,trusted_calls FROM privacy WHERE identity=?', (user,)).fetchone()
        return {'discoverable': bool(row[0]) if row else True,
                'inactivityDays': row[1] if row else 0,
                'trustedCalls': bool(row[2]) if row else False}
    if method == 'POST' and path == '/v1/privacy':
        discoverable, days, calls = body.get('discoverable'), body.get('inactivityDays'), body.get('trustedCalls')
        if type(discoverable) is not bool or type(calls) is not bool or type(days) is not int or days not in (0,30,90,180,365):
            raise error(400, 'Invalid privacy settings')
        db.execute('INSERT INTO privacy VALUES (?,?,?,?,?) ON CONFLICT(identity) DO UPDATE SET discoverable=excluded.discoverable,inactivity=excluded.inactivity,trusted_calls=excluded.trusted_calls,last_active=excluded.last_active',
                   (user, discoverable, days, now, calls))
        return {'ok': True}
    if method == 'POST' and path == '/v1/trust':
        peer, value = body.get('id'), body.get('trusted')
        if not isinstance(peer,str) or not re.fullmatch('[a-f0-9]{64}',peer) or type(value) is not bool:
            raise error(400,'Invalid consent')
        if value:
            db.execute('INSERT OR IGNORE INTO trusted VALUES (?,?)',(user,peer))
        else:
            db.execute('DELETE FROM trusted WHERE owner=? AND peer=?',(user,peer))
        return {'ok':True}
    if method == 'POST' and path == '/v1/invites':
        ttl, uses = body.get('seconds',3600), body.get('uses',1)
        if type(ttl) is not int or not 60<=ttl<=604800 or type(uses) is not int or not 1<=uses<=100:
            raise error(400,'Invalid invitation expiry or use limit')
        if db.execute('SELECT count(*) FROM invites WHERE owner=?',(user,)).fetchone()[0]>=50:
            raise error(429,'Invitation limit reached')
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        db.execute('INSERT INTO invites VALUES (?,?,?,?,?)',(digest,user,now+ttl,uses,now))
        return {'token':token,'id':digest,'expiresAt':now+ttl,'remaining':uses}
    if method == 'GET' and path == '/v1/invites':
        rows=db.execute('SELECT digest AS id,expires AS expiresAt,remaining,created FROM invites WHERE owner=? ORDER BY created DESC',(user,)).fetchall()
        return {'invites':[dict(r) for r in rows]}
    if method == 'DELETE' and path.startswith('/v1/invites/'):
        db.execute('DELETE FROM invites WHERE owner=? AND digest=?',(user,path.rsplit('/',1)[1]))
        return {'ok':True}
    if method == 'POST' and path == '/v1/invites/redeem':
        token=body.get('token','')
        if not isinstance(token,str) or not TOKEN.fullmatch(token):
            raise error(400,'Invalid invitation')
        digest=hashlib.sha256(token.encode()).hexdigest()
        # Atomic decrement prevents two clients redeeming a one-use link.
        row=db.execute('UPDATE invites SET remaining=remaining-1 WHERE digest=? AND remaining>0 AND expires>? RETURNING owner',(digest,now)).fetchone()
        if row is None:
            raise error(404,'Invitation expired or already used')
        card=db.execute('SELECT card FROM identities WHERE id=?',(row[0],)).fetchone()
        if card is None:
            raise error(404,'Invitation unavailable')
        import json
        return {'card':json.loads(card[0])}
    if method == 'POST' and path == '/v1/code/rotate':
        from app import CODE_ALPHABET
        old=db.execute('SELECT code FROM codes WHERE identity=?',(user,)).fetchone()
        for _ in range(128):
            code=''.join(secrets.choice(CODE_ALPHABET) for _ in range(4))
            if old and code==old[0]:
                continue
            if db.execute('SELECT 1 FROM codes WHERE code=?',(code,)).fetchone():
                continue
            db.execute('DELETE FROM codes WHERE identity=?',(user,))
            db.execute('INSERT INTO codes VALUES (?,?)',(code,user))
            return {'code':code}
        raise error(500,'Unable to rotate code')
    if method == 'DELETE' and path == '/v1/username':
        db.execute('DELETE FROM usernames WHERE identity=?',(user,))
        return {'ok':True}
    if method == 'GET' and path == '/v1/sessions':
        current=hashlib.sha256(env.get('HTTP_AUTHORIZATION','')[7:].encode()).hexdigest()
        rows=db.execute('SELECT digest,expires FROM sessions WHERE identity=? ORDER BY expires DESC',(user,)).fetchall()
        return {'sessions':[{'id':r[0],'expiresAt':r[1],'current':r[0]==current} for r in rows]}
    if method == 'POST' and path == '/v1/sessions/revoke':
        current=hashlib.sha256(env.get('HTTP_AUTHORIZATION','')[7:].encode()).hexdigest()
        db.execute('DELETE FROM sessions WHERE identity=? AND digest<>?',(user,current))
        return {'ok':True}
    if method == 'DELETE' and path == '/v1/push':
        db.execute('DELETE FROM push_tokens WHERE identity=?',(user,))
        return {'ok':True}
    if method == 'POST' and path == '/v1/push':
        token,kind,environment=body.get('token',''),body.get('kind'),body.get('environment')
        if not isinstance(token,str) or not PUSH_TOKEN.fullmatch(token) or kind not in ('alert','voip') or environment not in ('sandbox','production'):
            raise error(400,'Invalid push registration')
        token=token.lower()
        # A token belongs to one identity at a time; avoid stale profile notifications.
        db.execute('DELETE FROM push_tokens WHERE token=? AND kind=?',(token,kind))
        if body.get('enabled',True) is not True:
            return {'ok':True}
        if db.execute('SELECT count(*) FROM push_tokens WHERE identity=?',(user,)).fetchone()[0]>=8:
            raise error(429,'Too many devices')
        db.execute('INSERT INTO push_tokens VALUES (?,?,?,?,?)',(user,token,kind,environment,now))
        return {'ok':True}
    if method == 'GET' and path == '/v1/storage':
        messages=db.execute('SELECT count(*),coalesce(sum(size),0) FROM envelopes WHERE recipient=?',(user,)).fetchone()
        blobs=db.execute('SELECT count(*),coalesce(sum(size),0) FROM blobs WHERE owner=?',(user,)).fetchone()
        return {'queuedMessages':messages[0],'mailboxBytes':messages[1],'files':blobs[0],'fileBytes':blobs[1]}
    return None
