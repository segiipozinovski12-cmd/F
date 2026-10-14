"""BotFather registry and scoped ciphertext-only worker credentials."""
import hashlib
import json
import re
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

NAME = re.compile(r'^[a-z0-9_]{5,20}$')
TOKEN = re.compile(r'^[A-Za-z0-9_-]{43}$')


def install(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS bots (
        identity TEXT PRIMARY KEY, owner TEXT NOT NULL, username TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL, token_digest TEXT NOT NULL, enabled INTEGER NOT NULL,
        created INTEGER NOT NULL, commands TEXT NOT NULL DEFAULT '[]');
      CREATE INDEX IF NOT EXISTS bot_owner ON bots(owner);
    ''')


def creation_bytes(owner, card, username, name, digest):
    return f"VO1D-BOT-CREATE-1\n{owner}\n{card['id']}\n{username}\n{name}\n{digest}".encode()


def authorize(db, env, error):
    import moderation
    auth = env.get('HTTP_AUTHORIZATION', '')
    token = auth[len('BotCapability '):]
    if not TOKEN.fullmatch(token):
        raise error(401, 'Invalid bot credential')
    row = db.execute('SELECT b.identity,b.owner FROM bots b JOIN identities i ON i.id=b.identity WHERE b.token_digest=? AND b.enabled=1',
                     (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
    if row is None:
        raise error(401, 'Bot credential revoked or unavailable')
    path, method = env.get('PATH_INFO', ''), env.get('REQUEST_METHOD', '')
    allowed = ((method == 'GET' and (path in ('/v1/inbox', '/v2/prekeys') or path.startswith('/v1/identity/'))) or
               (method == 'POST' and (path in ('/v1/ack', '/v1/envelopes', '/v2/prekeys') or path.startswith('/v2/prekeys/'))))
    if not allowed:
        raise error(403, 'Bot credential is restricted to encrypted messaging and prekeys')
    moderation.enforce(db, row['identity'], error)
    moderation.enforce(db, row['owner'], error)
    return row['identity']


def enforce(db, identity, error):
    import moderation
    row = db.execute('SELECT owner,enabled FROM bots WHERE identity=?', (identity,)).fetchone()
    if row:
        if not row['enabled']:
            raise error(403, 'Bot disabled by its owner')
        moderation.enforce(db, row['owner'], error)


def public(row):
    return dict(id=row['identity'], username=row['username'], name=row['name'], enabled=bool(row['enabled']), commands=json.loads(row['commands']))


def erase(db, owner):
    import privacy
    for row in db.execute('SELECT identity FROM bots WHERE owner=?', (owner,)).fetchall():
        privacy.erase(db, row[0])
    db.execute('DELETE FROM bots WHERE owner=? OR identity=?', (owner, owner))


def handle(db, user, env, body, error, b64):
    from app import verify_card, RESERVED_USERNAMES
    method, path = env['REQUEST_METHOD'], env['PATH_INFO']
    if not path.startswith('/v2/bots'):
        return None
    now = int(time.time())
    if method == 'GET' and path.startswith('/v2/bots/directory/'):
        row = db.execute('SELECT * FROM bots WHERE identity=?', (path.rsplit('/', 1)[1],)).fetchone()
        return {'bot': public(row) if row else None}
    if db.execute('SELECT 1 FROM bots WHERE identity=?', (user,)).fetchone():
        raise error(403, 'Bot identities cannot manage other bots')
    if method == 'GET' and path == '/v2/bots':
        return {'bots': [public(r) for r in db.execute('SELECT * FROM bots WHERE owner=? ORDER BY created', (user,))]}
    if method == 'POST' and path == '/v2/bots':
        if set(body) != {'card', 'name', 'username', 'token', 'ownershipSignature'}:
            raise error(400, 'Bot card, name, username, scoped token and ownership proof required')
        card = verify_card(body['card'])
        import moderation
        permanent = moderation.owner(db)
        if permanent and permanent['owner'] == card['id']:
            raise error(400, 'The permanent administrator cannot be converted to a bot')
        username, name, token = body.get('username'), body.get('name'), body.get('token')
        if not isinstance(username, str) or not NAME.fullmatch(username) or not username.endswith('_bot') or username in RESERVED_USERNAMES:
            raise error(400, 'Bot username must be 5-20 lowercase characters and end in _bot')
        if not isinstance(name, str) or not 1 <= len(name) <= 40 or any(ord(c) < 32 for c in name) or not isinstance(token, str) or not TOKEN.fullmatch(token):
            raise error(400, 'Invalid bot name or credential')
        if card['id'] == user:
            raise error(400, 'A bot must have independent keys')
        digest = hashlib.sha256(token.encode()).hexdigest()
        try:
            Ed25519PublicKey.from_public_bytes(b64(card['signingKey'], 32)).verify(b64(body['ownershipSignature'], 64), creation_bytes(user, card, username, name, digest))
        except InvalidSignature:
            raise error(403, 'Bot ownership proof invalid')
        old = db.execute('SELECT * FROM bots WHERE identity=?', (card['id'],)).fetchone()
        if old:
            if old['owner'] != user or old['username'] != username or old['name'] != name or old['token_digest'] != digest:
                raise error(409, 'Bot already registered; use the owner management API')
            return {'ok': True, 'bot': public(old)}
        if db.execute('SELECT count(*) FROM bots WHERE owner=?', (user,)).fetchone()[0] >= 20:
            raise error(429, 'Bot limit reached')
        if db.execute('SELECT 1 FROM usernames WHERE username=?', (username,)).fetchone():
            raise error(409, 'Username is already taken')
        previous = db.execute('SELECT card FROM identities WHERE id=?', (card['id'],)).fetchone()
        if previous and json.loads(previous[0]) != card:
            raise error(409, 'Identity already registered with different keys')
        if db.execute('SELECT 1 FROM usernames WHERE identity=?', (card['id'],)).fetchone():
            raise error(409, 'Identity already has a username')
        db.execute('INSERT OR IGNORE INTO identities VALUES (?,?)', (card['id'], json.dumps(card)))
        db.execute('INSERT OR IGNORE INTO privacy(identity,last_active) VALUES (?,?)', (card['id'], now))
        db.execute('INSERT INTO usernames VALUES (?,?,?)', (username, card['id'], now))
        db.execute('INSERT INTO bots(identity,owner,username,name,token_digest,enabled,created) VALUES (?,?,?,?,?,1,?)', (card['id'], user, username, name, digest, now))
        return {'ok': True, 'bot': public(db.execute('SELECT * FROM bots WHERE identity=?', (card['id'],)).fetchone())}
    deletion = re.fullmatch(r'/v2/bots/([a-f0-9]{64})', path)
    if method == 'DELETE' and deletion:
        bot_id = deletion.group(1)
        row = db.execute('SELECT owner FROM bots WHERE identity=?', (bot_id,)).fetchone()
        if row is None:
            return {'ok': True}
        if row['owner'] != user:
            raise error(404, 'Owned bot not found')
        import privacy
        privacy.erase(db, bot_id)
        return {'ok': True}
    match = re.fullmatch(r'/v2/bots/([a-f0-9]{64})/(token|settings)', path)
    if method == 'POST' and match:
        bot_id, operation = match.groups()
        row = db.execute('SELECT * FROM bots WHERE identity=? AND owner=?', (bot_id, user)).fetchone()
        if row is None:
            raise error(404, 'Owned bot not found')
        if operation == 'token':
            token = body.get('token')
            if not isinstance(token, str) or not TOKEN.fullmatch(token):
                raise error(400, 'Invalid replacement credential')
            db.execute('UPDATE bots SET token_digest=? WHERE identity=?', (hashlib.sha256(token.encode()).hexdigest(), bot_id))
        else:
            enabled, commands = body.get('enabled'), body.get('commands')
            if type(enabled) is not bool or not isinstance(commands, list) or len(commands) > 32 or any(not isinstance(c, str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,31}', c) for c in commands) or len(commands) != len(set(commands)):
                raise error(400, 'Invalid bot state or command list')
            db.execute('UPDATE bots SET enabled=?,commands=? WHERE identity=?', (enabled, json.dumps(commands), bot_id))
        return {'ok': True}
    raise error(404, 'Not found')
