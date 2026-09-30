"""Capability mailboxes independent of account sessions and public identity IDs.

Capabilities are random 256-bit values. No owner or sender column is stored.
The same operator can still correlate network timing, IP and ciphertext sizes.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import time
from private_blobs import work_bits

TOKEN = re.compile(r'^[A-Za-z0-9_-]{43}$')
UUID = re.compile(r'^[A-Za-z0-9-]{16,64}$')
FIELDS = {'id','mailbox','ephemeralKey','salt','expiresAt','ciphertext'}


def install(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS retired_mailboxes (id TEXT PRIMARY KEY, read_digest TEXT NOT NULL, expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS private_mailboxes (
          id TEXT PRIMARY KEY, read_digest TEXT NOT NULL, write_digest TEXT NOT NULL,
          expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS private_envelopes (
          id TEXT, mailbox TEXT, body TEXT NOT NULL, size INTEGER NOT NULL,
          expires INTEGER NOT NULL, PRIMARY KEY(id,mailbox));
        CREATE TABLE IF NOT EXISTS private_seen (
          id TEXT, mailbox TEXT, digest TEXT NOT NULL, expires INTEGER NOT NULL,
          PRIMARY KEY(id,mailbox));
        CREATE INDEX IF NOT EXISTS private_inbox ON private_envelopes(mailbox,expires);
        CREATE TABLE IF NOT EXISTS private_invites (
          token TEXT PRIMARY KEY, mailbox TEXT NOT NULL, ciphertext TEXT NOT NULL, expires INTEGER NOT NULL);
    ''')


def clean(db, now):
    db.execute('DELETE FROM private_invites WHERE expires<=? OR mailbox IN (SELECT id FROM private_mailboxes WHERE expires<=?)',(now,now))
    db.execute('DELETE FROM private_envelopes WHERE expires<=? OR mailbox IN (SELECT id FROM private_mailboxes WHERE expires<=?)',(now,now))
    db.execute('DELETE FROM private_seen WHERE expires<=? OR mailbox IN (SELECT id FROM private_mailboxes WHERE expires<=?)',(now,now))
    db.execute('DELETE FROM private_mailboxes WHERE expires<=?',(now,))
    db.execute('DELETE FROM retired_mailboxes WHERE expires<=?',(now,))


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def authorize(db, mailbox, env, scope, error):
    auth = env.get('HTTP_AUTHORIZATION','')
    if not auth.startswith('Capability ') or not TOKEN.fullmatch(auth[11:]):
        raise error(401,'Mailbox capability required')
    row = db.execute('SELECT read_digest,write_digest,expires FROM private_mailboxes WHERE id=?',(mailbox,)).fetchone()
    if row is None and env['REQUEST_METHOD']=='DELETE':
        retired=db.execute('SELECT read_digest,expires FROM retired_mailboxes WHERE id=? AND expires>?',(mailbox,int(time.time()))).fetchone()
        if retired and hmac.compare_digest(retired[0],digest(auth[11:])): return retired[1]
    if row is None or row[2] <= int(time.time()) or not hmac.compare_digest(row[0 if scope=='read' else 1],digest(auth[11:])):
        raise error(403,'Invalid or expired mailbox capability')
    return row[2]


def handle(relay, env, body, ip_hash, error, decode):
    path, method = env['PATH_INFO'], env['REQUEST_METHOD']
    now = int(time.time())
    relay.rate('private-attempt:'+ip_hash,600)
    if path.startswith('/v2/private-invites/') and method=='GET':
        token=path.rsplit('/',1)[1]
        if not TOKEN.fullmatch(token): raise error(400,'Invalid private invitation')
        relay.rate('private-invite:'+ip_hash,120)
        with relay.db() as db:
            row=db.execute('DELETE FROM private_invites WHERE token=? AND expires>? RETURNING ciphertext',(token,now)).fetchone()
        if row is None: raise error(404,'Private invitation expired, revoked or already used')
        return {'ciphertext':row[0]}
    if path == '/v2/mailboxes' and method == 'POST':
        relay.rate('mailbox-create:'+ip_hash,64,3600)
        if set(body) != {'id','readToken','writeToken','expiresAt','proof'}:
            raise error(400,'Invalid mailbox fields')
        if any(not isinstance(body[k],str) or not TOKEN.fullmatch(body[k]) for k in ('id','readToken','writeToken')) or body['readToken']==body['writeToken']:
            raise error(400,'Invalid mailbox capability')
        expiry = body['expiresAt']
        if type(expiry) is not int or not now+60 <= expiry <= now+30*86400:
            raise error(400,'Invalid mailbox expiry')
        proof = body['proof']
        if not isinstance(proof,str) or not re.fullmatch('[0-9]{1,20}',proof):
            raise error(400,'Invalid work proof')
        bits = work_bits()
        value = hashlib.sha256(f"VO1D-MAILBOX-WORK-2\n{body['id']}\n{expiry}\n{proof}".encode()).digest()
        if int.from_bytes(value,'big') >> (256-bits) != 0:
            raise error(403,'Mailbox work proof rejected')
        with relay.db() as db:
            clean(db,now)
            if db.execute('SELECT 1 FROM retired_mailboxes WHERE id=?',(body['id'],)).fetchone(): raise error(409,'Mailbox address revoked')
            values=(body['id'],digest(body['readToken']),digest(body['writeToken']),expiry)
            old=db.execute('SELECT * FROM private_mailboxes WHERE id=?',(body['id'],)).fetchone()
            if old is not None and tuple(old)!=values:
                raise error(409,'Mailbox already exists')
            db.execute('INSERT OR IGNORE INTO private_mailboxes VALUES (?,?,?,?)',values)
        return {'ok':True}
    parts=path.strip('/').split('/')
    if len(parts) not in (3,4) or parts[:2]!=['v2','mailboxes'] or not TOKEN.fullmatch(parts[2]):
        raise error(404,'Mailbox route not found')
    mailbox=parts[2]
    scope='write' if method=='POST' and len(parts)==4 and parts[3]=='envelopes' else 'read'
    # Rate bucket names are hashes; neither tokens nor mailbox IDs are logged.
    relay.rate('private:'+digest(mailbox)+':'+scope,120)
    with relay.db() as db:
        clean(db,now)
        mailbox_expiry=authorize(db,mailbox,env,scope,error)
        action=parts[3] if len(parts)==4 else ''
        if method=='POST' and action=='invites':
            if set(body)!={'token','ciphertext','expiresAt'} or not isinstance(body['token'],str) or not TOKEN.fullmatch(body['token']):
                raise error(400,'Invalid private invitation')
            if type(body['expiresAt']) is not int or not now < body['expiresAt'] <= min(mailbox_expiry,now+86400):
                raise error(400,'Invalid invitation expiry')
            if not 28 <= len(decode(body['ciphertext'])) <= 32768:
                raise error(400,'Invalid encrypted invitation')
            old=db.execute('SELECT mailbox,ciphertext,expires FROM private_invites WHERE token=?',(body['token'],)).fetchone()
            values=(mailbox,body['ciphertext'],body['expiresAt'])
            if old is not None and tuple(old)!=values: raise error(409,'Invitation collision')
            db.execute('INSERT OR IGNORE INTO private_invites VALUES (?,?,?,?)',(body['token'],*values))
            return {'ok':True}
        if method=='GET' and action=='inbox':
            rows=db.execute('SELECT body FROM private_envelopes WHERE mailbox=? ORDER BY rowid LIMIT 24',(mailbox,)).fetchall()
            return {'envelopes':[json.loads(r[0]) for r in rows]}
        if method=='POST' and action=='envelopes':
            if set(body)!=FIELDS or body.get('mailbox')!=mailbox or not isinstance(body.get('id'),str) or not UUID.fullmatch(body['id']):
                raise error(400,'Invalid opaque envelope')
            if type(body.get('expiresAt')) is not int or not now<body['expiresAt']<=min(now+7*86400,mailbox_expiry):
                raise error(400,'Invalid envelope expiry')
            decode(body['ephemeralKey'],32); decode(body['salt'],32)
            encrypted=decode(body['ciphertext'])
            if len(encrypted) not in (2048+28,8192+28,32768+28,131072+28,524288+28,2097152+28,5242880+28):
                raise error(400,'Ciphertext must use a supported padding bucket')
            encoded=json.dumps(body,sort_keys=True,separators=(',',':'))
            checksum=hashlib.sha256(encoded.encode()).hexdigest()
            # Serialize duplicate detection and quotas before reading mailbox state.
            db.execute('UPDATE private_mailboxes SET expires=expires WHERE id=?',(mailbox,))
            old=db.execute('SELECT digest FROM private_seen WHERE id=? AND mailbox=?',(body['id'],mailbox)).fetchone()
            if old is not None:
                if old[0]!=checksum: raise error(409,'Opaque envelope ID collision')
                return {'ok':True}
            count,size=db.execute('SELECT count(*),coalesce(sum(size),0) FROM private_envelopes WHERE mailbox=?',(mailbox,)).fetchone()
            if count>=1000 or size+len(encoded)>100*1024*1024:
                raise error(429,'Mailbox quota reached')
            db.execute('INSERT INTO private_envelopes VALUES (?,?,?,?,?)',(body['id'],mailbox,encoded,len(encoded),body['expiresAt']))
            db.execute('INSERT INTO private_seen VALUES (?,?,?,?)',(body['id'],mailbox,checksum,body['expiresAt']))
            return {'ok':True}
        if method=='POST' and action=='ack':
            ids=body.get('ids')
            if not isinstance(ids,list) or len(ids)>100 or any(not isinstance(v,str) or not UUID.fullmatch(v) for v in ids):
                raise error(400,'Invalid acknowledgement')
            db.executemany('DELETE FROM private_envelopes WHERE mailbox=? AND id=?',[(mailbox,v) for v in ids])
            return {'ok':True}
        if method=='DELETE' and action=='':
            db.execute('INSERT OR IGNORE INTO retired_mailboxes SELECT id,read_digest,expires FROM private_mailboxes WHERE id=?',(mailbox,))
            db.execute('DELETE FROM private_invites WHERE mailbox=?',(mailbox,))
            db.execute('DELETE FROM private_envelopes WHERE mailbox=?',(mailbox,))
            db.execute('DELETE FROM private_seen WHERE mailbox=?',(mailbox,))
            db.execute('DELETE FROM private_mailboxes WHERE id=?',(mailbox,))
            return {'ok':True}
    raise error(404,'Mailbox route not found')
