"""Revocable, short-lived call-only authority; never accepted by account APIs."""
import hashlib
import json
import secrets
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def bytes_for(cert):
    return f"VO1D-CALL-CAPABILITY-2\n{cert['owner']}\n{cert['key']}\n{cert['expiresAt']}\ncalls".encode()


def install(db):
    db.execute('''CREATE TABLE IF NOT EXISTS call_authorities (
        digest TEXT PRIMARY KEY, owner TEXT NOT NULL, certificate TEXT NOT NULL, expires INTEGER NOT NULL)''')


def handle(db,user,env,body,error,decode):
    method,path=env['REQUEST_METHOD'],env['PATH_INFO']
    if path!='/v2/call-authority': return None
    if method=='DELETE':
        db.execute('DELETE FROM call_authorities WHERE owner=?',(user,))
        return {'ok':True}
    if method!='POST': return None
    cert=body
    now=int(time.time())
    if set(cert)!={'owner','key','expiresAt','signature'} or cert['owner']!=user or type(cert['expiresAt']) is not int or not now<cert['expiresAt']<=now+86400:
        raise error(400,'Invalid call authority')
    decode(cert['key'],32)
    card=json.loads(db.execute('SELECT card FROM identities WHERE id=?',(user,)).fetchone()[0])
    try:
        Ed25519PublicKey.from_public_bytes(decode(card['signingKey'],32)).verify(decode(cert['signature'],64),bytes_for(cert))
    except InvalidSignature:
        raise error(403,'Invalid delegated call signature')
    count=db.execute('SELECT count(*) FROM call_authorities WHERE owner=? AND expires>?',(user,now)).fetchone()[0]
    if count>=8: raise error(429,'Call authority limit')
    token=secrets.token_urlsafe(32)
    db.execute('INSERT INTO call_authorities VALUES (?,?,?,?)',(hashlib.sha256(token.encode()).hexdigest(),user,json.dumps(cert),cert['expiresAt']))
    return {'token':token}


def authorize(db,auth,error):
    if not auth.startswith('CallCapability '): raise error(401,'Call authority required')
    digest=hashlib.sha256(auth[15:].encode()).hexdigest()
    row=db.execute('SELECT owner,certificate FROM call_authorities WHERE digest=? AND expires>?',(digest,int(time.time()))).fetchone()
    if row is None: raise error(401,'Call authority expired or revoked')
    return row[0],json.loads(row[1])
