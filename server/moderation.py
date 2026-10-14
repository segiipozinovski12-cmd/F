"""Opt-in encrypted reports. No mailbox, ratchet or conversation decryption API."""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import time

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.twofactor.totp import TOTP

REASONS = {'spam', 'harassment', 'threats', 'impersonation', 'illegal_content', 'other'}
SOURCES = {'profile', 'chat', 'message'}
STATUSES = {'open', 'reviewing', 'dismissed', 'resolved'}
MAX_EVIDENCE = 256 * 1024
RETENTION = 7 * 86400
IDENTITY = re.compile(r'^[a-f0-9]{64}$')
CASE_ID = re.compile(r'^[A-Za-z0-9-]{16,64}$')


def install(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS permanent_admin (
          singleton INTEGER PRIMARY KEY CHECK(singleton=1), owner TEXT NOT NULL,
          card TEXT NOT NULL, created INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS moderators (
          identity TEXT PRIMARY KEY, role TEXT NOT NULL CHECK(role IN ('admin','reviewer')));
        CREATE TABLE IF NOT EXISTS moderator_mfa (
          identity TEXT PRIMARY KEY, secret BLOB NOT NULL, verified INTEGER NOT NULL,
          last_counter INTEGER NOT NULL DEFAULT -1, pending_until INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS moderator_sessions (
          digest TEXT PRIMARY KEY, identity TEXT NOT NULL, account_session TEXT NOT NULL,
          expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS reports (
          id TEXT PRIMARY KEY, reporter TEXT NOT NULL, subject TEXT NOT NULL,
          reason TEXT NOT NULL, source TEXT NOT NULL, digest TEXT NOT NULL,
          envelope TEXT NOT NULL, sender_card TEXT NOT NULL, status TEXT NOT NULL,
          created INTEGER NOT NULL, expires INTEGER NOT NULL, updated INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS report_queue ON reports(status,created);
        CREATE INDEX IF NOT EXISTS report_reporter ON reports(reporter,created);
        CREATE TABLE IF NOT EXISTS report_appeals (
          id TEXT PRIMARY KEY, identity TEXT NOT NULL, report TEXT UNIQUE NOT NULL,
          digest TEXT NOT NULL, envelope TEXT NOT NULL, sender_card TEXT NOT NULL,
          created INTEGER NOT NULL, expires INTEGER NOT NULL, status TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sanctions (
          subject TEXT PRIMARY KEY, action TEXT NOT NULL, expires INTEGER NOT NULL,
          report TEXT NOT NULL, actor TEXT NOT NULL, created INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS moderation_audit (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, entry TEXT NOT NULL,
          previous TEXT NOT NULL, digest TEXT NOT NULL);
    ''')
    # Migrate an existing first claim without changing its keys or ownership.
    db.execute('''INSERT OR IGNORE INTO permanent_admin
      SELECT 1,u.identity,i.card,u.updated FROM usernames u JOIN identities i
      ON i.id=u.identity WHERE u.username='vo1d' ''')


def owner(db):
    return db.execute('SELECT owner,card FROM permanent_admin WHERE singleton=1').fetchone()


def claim(db, user, username, now, error):
    """Called inside the username write transaction; ownership never cascades."""
    current = owner(db)
    if username == 'vo1d':
        if current and current['owner'] != user:
            raise error(409, 'Username is already taken')
        if current is None:
            card = db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()[0]
            db.execute('INSERT INTO permanent_admin VALUES (1,?,?,?)', (user, card, now))
            audit(db, user, 'claim_admin', 'vo1d', now)
    elif current and current['owner'] == user:
        raise error(409, 'The permanent administrator username cannot be changed')


def role(db, user):
    current = owner(db)
    if current and current['owner'] == user:
        return 'owner'
    row = db.execute('SELECT role FROM moderators WHERE identity=?', (user,)).fetchone()
    return row[0] if row else None


def audit(db, actor, action, target, now):
    previous = db.execute('SELECT digest FROM moderation_audit ORDER BY seq DESC LIMIT 1').fetchone()
    previous = previous[0] if previous else '0' * 64
    entry = json.dumps(dict(actor=actor, action=action, target=target, at=now), sort_keys=True, separators=(',', ':'))
    digest = hashlib.sha256((previous + '\n' + entry).encode()).hexdigest()
    db.execute('INSERT INTO moderation_audit(entry,previous,digest) VALUES (?,?,?)', (entry, previous, digest))
    db.execute('DELETE FROM moderation_audit WHERE seq <= (SELECT max(seq)-50000 FROM moderation_audit)')


def clean(db, now):
    db.execute('DELETE FROM moderator_sessions WHERE expires<=?', (now,))
    db.execute('DELETE FROM moderator_mfa WHERE verified=0 AND pending_until<=?', (now,))
    db.execute('DELETE FROM sanctions WHERE expires<=?', (now,))
    db.execute("UPDATE report_appeals SET envelope='',sender_card='' WHERE expires<=? AND envelope<>''", (now,))
    db.execute("UPDATE reports SET envelope='',sender_card='' WHERE expires<=? AND envelope<>''", (now,))
    db.execute('DELETE FROM report_appeals WHERE created<=?', (now - 90 * 86400,))
    db.execute('DELETE FROM reports WHERE created<=?', (now - 90 * 86400,))


def erase(db, user):
    # Keep the permanent owner tombstone and pinned public card, never private keys.
    current = owner(db)
    tables = ('moderator_sessions', 'moderators') if current and current['owner'] == user else ('moderator_sessions', 'moderator_mfa', 'moderators')
    for table in tables:
        db.execute(f'DELETE FROM {table} WHERE identity=?', (user,))
    db.execute('DELETE FROM reports WHERE reporter=?', (user,))
    db.execute('DELETE FROM report_appeals WHERE identity=?', (user,))


def enforce(db, user, error):
    row = db.execute("SELECT action FROM sanctions WHERE subject=? AND expires>? AND action IN ('restrict','ban')", (user, int(time.time()))).fetchone()
    if row:
        raise error(403, 'Account sending is restricted; review the moderation notice or appeal')


def master_key(error):
    try:
        value = base64.b64decode(os.environ.get('VO1D_MODERATION_KEY', ''), validate=True)
        if len(value) != 32:
            raise ValueError()
        return value
    except (ValueError, TypeError):
        raise error(503, 'Operator must configure a persistent moderation encryption key')


def protect(secret, user, error):
    nonce = secrets.token_bytes(12)
    return nonce + AESGCM(master_key(error)).encrypt(nonce, secret, ('VO1D-MFA-1\n' + user).encode())


def unprotect(value, user, error):
    try:
        return AESGCM(master_key(error)).decrypt(value[:12], value[12:], ('VO1D-MFA-1\n' + user).encode())
    except InvalidTag:
        raise error(503, 'Moderation encryption key does not match stored MFA data')


def totp(secret, counter):
    return TOTP(secret, 6, hashes.SHA1(), 30).generate(counter * 30).decode()


def check_otp(db, user, code, now, error):
    if not isinstance(code, str) or not re.fullmatch(r'[0-9]{6}', code):
        raise error(400, 'Enter a six-digit authenticator code')
    row = db.execute('SELECT * FROM moderator_mfa WHERE identity=?', (user,)).fetchone()
    if row is None or (not row['verified'] and row['pending_until'] <= now):
        raise error(403, 'Set up an authenticator first')
    key = unprotect(row['secret'], user, error)
    for counter in range(now // 30 - 1, now // 30 + 2):
        if counter > row['last_counter'] and hmac.compare_digest(totp(key, counter), code):
            changed = db.execute('UPDATE moderator_mfa SET last_counter=?,verified=1 WHERE identity=? AND last_counter<?', (counter, user, counter)).rowcount
            if changed == 1:
                return
    raise error(403, 'Invalid or already used authenticator code')


def authorize(db, user, env, error, roles=('owner', 'admin', 'reviewer')):
    current_role = role(db, user)
    if current_role not in roles:
        raise error(403, 'Moderator role required')
    token = env.get('HTTP_X_MODERATION_TOKEN', '')
    if not isinstance(token, str) or len(token) != 43:
        raise error(403, 'Moderator MFA session required')
    account = hashlib.sha256(env.get('HTTP_AUTHORIZATION', '')[7:].encode()).hexdigest()
    row = db.execute('SELECT 1 FROM moderator_sessions WHERE digest=? AND identity=? AND account_session=? AND expires>?',
                     (hashlib.sha256(token.encode()).hexdigest(), user, account, int(time.time()))).fetchone()
    if not row:
        raise error(403, 'Moderator MFA session expired')
    return current_role


def sealed(body, user, db, now, error, b64):
    from app import header_bytes, agreement_key
    e = body.get('envelope')
    keys = {'id', 'sender', 'recipient', 'ephemeralKey', 'salt', 'ciphertext', 'signature', 'expiresAt'}
    current = owner(db)
    if current is None:
        raise error(503, 'Administrator @vo1d has not claimed this relay')
    if not isinstance(e, dict) or set(e) != keys or any(not isinstance(e[k], str) for k in keys - {'expiresAt'}):
        raise error(400, 'Only a sealed report envelope is accepted')
    if not CASE_ID.fullmatch(e['id']) or e['sender'] != user or e['recipient'] != current['owner']:
        raise error(400, 'Invalid report sender or administrator recipient')
    if type(e['expiresAt']) is not int or not now < e['expiresAt'] <= now + RETENTION + 60:
        raise error(400, 'Report expiry must be within seven days')
    agreement_key(e['ephemeralKey'])
    b64(e['salt'], 32)
    ciphertext = b64(e['ciphertext'])
    if not 28 <= len(ciphertext) <= MAX_EVIDENCE:
        raise error(413, 'Selected evidence exceeds the report size limit')
    card = db.execute('SELECT card FROM identities WHERE id=?', (user,)).fetchone()[0]
    try:
        Ed25519PublicKey.from_public_bytes(b64(json.loads(card)['signingKey'], 32)).verify(b64(e['signature'], 64), header_bytes(e) + b'\n' + ciphertext)
    except InvalidSignature:
        raise error(403, 'Invalid report signature')
    encoded = json.dumps(e, sort_keys=True, separators=(',', ':'))
    return e, encoded, card


def evidence_bytes(db):
    return db.execute('SELECT coalesce(sum(length(envelope)),0) FROM (SELECT envelope FROM reports UNION ALL SELECT envelope FROM report_appeals)').fetchone()[0]


def handle(relay, db, user, env, body, error, b64):
    method, path = env['REQUEST_METHOD'], env['PATH_INFO']
    if not path.startswith(('/v2/reports', '/v2/moderation', '/v2/appeals')):
        return None
    now = int(time.time())
    current = owner(db)
    if method == 'GET' and path == '/v2/reports/config':
        return {'username': 'vo1d', 'card': json.loads(current['card']) if current else None,
                'maxEvidenceBytes': MAX_EVIDENCE, 'retentionSeconds': RETENTION}
    if method == 'POST' and path == '/v2/reports':
        if set(body) != {'subject', 'reason', 'source', 'consent', 'envelope'} or body.get('consent') is not True:
            raise error(400, 'Explicit consent and only selected sealed evidence are required')
        subject, reason, source = body.get('subject'), body.get('reason'), body.get('source')
        if not isinstance(subject, str) or not IDENTITY.fullmatch(subject) or subject == user:
            raise error(400, 'Invalid report subject')
        if not isinstance(reason, str) or reason not in REASONS or not isinstance(source, str) or source not in SOURCES:
            raise error(400, 'Invalid report reason or source')
        e, encoded, card = sealed(body, user, db, now, error, b64)
        digest = hashlib.sha256((subject + '\n' + reason + '\n' + source + '\n' + encoded).encode()).hexdigest()
        previous = db.execute('SELECT reporter,digest FROM reports WHERE id=?', (e['id'],)).fetchone()
        if previous:
            if previous['reporter'] != user or previous['digest'] != digest:
                raise error(409, 'Report ID collision')
            return {'id': e['id'], 'ok': True}
        if db.execute('SELECT count(*) FROM reports WHERE reporter=? AND created>?', (user, now - 86400)).fetchone()[0] >= 5:
            raise error(429, 'Daily report limit reached')
        if db.execute('SELECT count(*) FROM reports WHERE reporter=? AND subject=? AND created>?', (user, subject, now - 3600)).fetchone()[0]:
            raise error(429, 'A recent report for this user is already queued')
        if db.execute('SELECT count(*) FROM reports').fetchone()[0] >= 10000:
            raise error(429, 'Moderation queue is full')
        if evidence_bytes(db) + len(encoded) > 64 * 1024 * 1024:
            raise error(429, 'Moderation evidence storage quota reached')
        db.execute('INSERT INTO reports VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
                   (e['id'], user, subject, reason, source, digest, encoded, card, 'open', now, e['expiresAt'], now))
        audit(db, user, 'submit_report', e['id'], now)
        return {'id': e['id'], 'ok': True}
    if method == 'GET' and path == '/v2/reports/mine':
        rows = db.execute('SELECT id,reason,source,status,created,expires FROM reports WHERE reporter=? ORDER BY created DESC LIMIT 100', (user,)).fetchall()
        return {'reports': [dict(r) for r in rows]}
    if method == 'GET' and path == '/v2/reports/notices':
        rows = db.execute('SELECT report AS id,action,expires,created FROM sanctions WHERE subject=? AND expires>?', (user, now)).fetchall()
        return {'notices': [dict(r) for r in rows]}
    if method == 'POST' and path == '/v2/appeals':
        if set(body) != {'report', 'consent', 'envelope'} or body.get('consent') is not True:
            raise error(400, 'Explicit consent required')
        case = body.get('report')
        if not isinstance(case, str) or not CASE_ID.fullmatch(case):
            raise error(400, 'Invalid case ID')
        sanction = db.execute('SELECT 1 FROM sanctions WHERE subject=? AND report=? AND expires>?', (user, case, now)).fetchone()
        if not sanction:
            raise error(404, 'No active decision to appeal')
        e, encoded, card = sealed(body, user, db, now, error, b64)
        digest = hashlib.sha256(encoded.encode()).hexdigest()
        previous = db.execute('SELECT * FROM report_appeals WHERE report=? OR id=?', (case, e['id'])).fetchone()
        if previous:
            if previous['identity'] == user and previous['report'] == case and previous['id'] == e['id'] and previous['digest'] == digest:
                return {'ok': True, 'id': e['id']}
            raise error(409, 'An appeal has already been submitted')
        if evidence_bytes(db) + len(encoded) > 64 * 1024 * 1024:
            raise error(429, 'Moderation evidence storage quota reached')
        db.execute('INSERT INTO report_appeals VALUES (?,?,?,?,?,?,?,?,?)', (e['id'], user, case, digest, encoded, card, now, e['expiresAt'], 'open'))
        audit(db, user, 'appeal', case, now)
        return {'ok': True, 'id': e['id']}
    if method == 'GET' and path == '/v2/moderation/access':
        row = db.execute('SELECT verified FROM moderator_mfa WHERE identity=?', (user,)).fetchone()
        return {'role': role(db, user), 'mfaEnabled': bool(row and row[0])}
    if path in ('/v2/moderation/mfa/setup', '/v2/moderation/mfa/verify') and method == 'POST':
        if role(db, user) is None:
            raise error(403, 'Moderator role required')
        if path.endswith('/setup'):
            row = db.execute('SELECT verified FROM moderator_mfa WHERE identity=?', (user,)).fetchone()
            if row and row[0]:
                raise error(409, 'Authenticator is already enabled')
            secret = secrets.token_bytes(20)
            db.execute('INSERT OR REPLACE INTO moderator_mfa VALUES (?,?,0,-1,?)', (user, protect(secret, user, error), now + 600))
            audit(db, user, 'mfa_setup', user, now)
            return {'secret': base64.b32encode(secret).decode().rstrip('='), 'expiresAt': now + 600}
        check_otp(db, user, body.get('code'), now, error)
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        account = hashlib.sha256(env.get('HTTP_AUTHORIZATION', '')[7:].encode()).hexdigest()
        db.execute('DELETE FROM moderator_sessions WHERE identity=?', (user,))
        db.execute('INSERT INTO moderator_sessions VALUES (?,?,?,?)', (digest, user, account, now + 900))
        audit(db, user, 'mfa_login', user, now)
        return {'token': token, 'expiresAt': now + 900}
    current_role = authorize(db, user, env, error)
    if method == 'POST' and path == '/v2/moderation/logout':
        db.execute('DELETE FROM moderator_sessions WHERE identity=?', (user,))
        return {'ok': True}
    if method == 'GET' and path == '/v2/moderation/queue':
        rows = db.execute('SELECT id,subject,reason,source,status,created,expires,updated FROM reports ORDER BY CASE status WHEN \'open\' THEN 0 WHEN \'reviewing\' THEN 1 ELSE 2 END,created LIMIT 100').fetchall()
        return {'reports': [dict(r) for r in rows]}
    if method == 'GET' and path == '/v2/moderation/appeals':
        rows = db.execute('SELECT id,identity,report,created,expires,status FROM report_appeals ORDER BY created LIMIT 100').fetchall()
        return {'appeals': [dict(r) for r in rows]}
    if method == 'GET' and path == '/v2/moderation/audit':
        rows = db.execute('SELECT seq,entry,previous,digest FROM moderation_audit ORDER BY seq DESC LIMIT 200').fetchall()
        return {'events': [dict(r) for r in rows]}
    if method == 'GET' and path == '/v2/moderation/metrics':
        counts = {r[0]: r[1] for r in db.execute('SELECT status,count(*) FROM reports GROUP BY status')}
        oldest = db.execute("SELECT min(created) FROM reports WHERE status IN ('open','reviewing')").fetchone()[0]
        return {'queue': counts, 'evidenceBytes': evidence_bytes(db),
                'openAppeals': db.execute("SELECT count(*) FROM report_appeals WHERE status='open'").fetchone()[0],
                'oldestOpenSeconds': max(0, now - oldest) if oldest else 0}
    if method == 'GET' and path == '/v2/moderation/roles':
        if current_role != 'owner':
            raise error(403, 'Only the permanent administrator can list moderator roles')
        return {'moderators': [dict(r) for r in db.execute('SELECT identity,role FROM moderators ORDER BY identity')]}
    if method == 'POST' and path == '/v2/moderation/roles':
        if current_role != 'owner':
            raise error(403, 'Only the permanent administrator can manage roles')
        target, value = body.get('identity'), body.get('role')
        if not isinstance(target, str) or not IDENTITY.fullmatch(target) or target == user or value not in ('admin', 'reviewer', 'none'):
            raise error(400, 'Invalid moderator assignment')
        if not db.execute('SELECT 1 FROM identities WHERE id=?', (target,)).fetchone():
            raise error(404, 'Moderator identity not registered')
        if db.execute('SELECT count(*) FROM moderators').fetchone()[0] >= 32 and not db.execute('SELECT 1 FROM moderators WHERE identity=?', (target,)).fetchone():
            raise error(429, 'Moderator limit reached')
        db.execute('DELETE FROM moderator_sessions WHERE identity=?', (target,))
        if value == 'none':
            db.execute('DELETE FROM moderators WHERE identity=?', (target,))
            db.execute('DELETE FROM moderator_mfa WHERE identity=?', (target,))
        else:
            db.execute('INSERT OR REPLACE INTO moderators VALUES (?,?)', (target, value))
        audit(db, user, 'role_' + value, target, now)
        return {'ok': True}
    if method == 'GET' and path.startswith(('/v2/moderation/report/', '/v2/moderation/appeal/')):
        case = path.rsplit('/', 1)[1]
        table = 'report_appeals' if '/appeal/' in path else 'reports'
        row = db.execute(f'SELECT * FROM {table} WHERE id=?', (case,)).fetchone()
        if row is None:
            raise error(404, 'Case not found')
        if current_role != 'owner':
            raise error(403, 'Evidence was voluntarily encrypted only to @vo1d')
        if not row['envelope'] or row['expires'] <= now:
            raise error(410, 'Selected evidence has expired; case metadata remains available')
        audit(db, user, 'read_evidence', case, now)
        return {'id': case, 'envelope': json.loads(row['envelope']), 'senderCard': json.loads(row['sender_card'])}
    if method == 'POST' and path == '/v2/moderation/decision':
        case, status, action = body.get('report'), body.get('status'), body.get('action', 'none')
        duration, expected = body.get('seconds', 86400), body.get('expectedUpdated')
        if not isinstance(case, str) or not isinstance(status, str) or status not in STATUSES or action not in ('none', 'warn', 'restrict', 'ban', 'lift'):
            raise error(400, 'Invalid moderation decision')
        if type(duration) is not int or not 60 <= duration <= 30 * 86400 or type(expected) is not int:
            raise error(400, 'Invalid duration or expected revision')
        if action != 'none' and current_role not in ('owner', 'admin'):
            raise error(403, 'Administrator role required for sanctions')
        if (action in ('warn', 'restrict', 'ban', 'lift') and status != 'resolved'):
            raise error(400, 'A sanction requires a resolved decision')
        row = db.execute('SELECT * FROM reports WHERE id=?', (case,)).fetchone()
        if row is None:
            raise error(404, 'Report not found')
        if row['updated'] != expected:
            raise error(409, 'Case changed; refresh before deciding')
        if row['status'] in ('resolved', 'dismissed') and current_role == 'reviewer':
            raise error(403, 'Only administrators can reopen a closed decision')
        if current and row['subject'] == current['owner'] and action != 'none':
            raise error(403, 'Permanent administrator cannot be reassigned or sanctioned through reports')
        if action == 'lift':
            db.execute('DELETE FROM sanctions WHERE subject=? AND report=?', (row['subject'], case))
            db.execute("UPDATE report_appeals SET status='resolved' WHERE report=?", (case,))
        elif action != 'none':
            old = db.execute('SELECT action FROM sanctions WHERE subject=?', (row['subject'],)).fetchone()
            if old and {'warn': 1, 'restrict': 2, 'ban': 3}[old[0]] > {'warn': 1, 'restrict': 2, 'ban': 3}[action]:
                raise error(409, 'Use an explicit lift before lowering an active sanction')
            db.execute('INSERT OR REPLACE INTO sanctions VALUES (?,?,?,?,?,?)', (row['subject'], action, now + duration, case, user, now))
        db.execute('UPDATE reports SET status=?,updated=? WHERE id=?', (status, max(now, expected + 1), case))
        audit(db, user, 'decision_' + status + '_' + action, case, now)
        return {'ok': True}
    raise error(404, 'Not found')
