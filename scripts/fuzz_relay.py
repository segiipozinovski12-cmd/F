#!/usr/bin/env python3
"""Coverage-guided malformed HTTP/JSON API fuzzing of an ephemeral local relay.

No network, real user data, production DB or native sanitizer claim. Rate limits
are disabled ONLY for this instance, so the fuzzer reaches validation paths.
"""
import base64
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import secrets
from contextlib import nullcontext

REPLAY = '--replay' in sys.argv
if not REPLAY:
    import atheris
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
with nullcontext() if REPLAY else atheris.instrument_imports(include=['app','bots','moderation','prekeys','mailboxes','privacy','private_blobs','network_privacy','call_authority','commerce']):
    from app import Relay, card_bytes
    import moderation
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PATHS = ['/v2/reports','/v2/appeals','/v2/bots','/v2/prekeys','/v2/moderation/decision','/v2/moderation/assign','/v2/moderation/appeal-decision','/v2/moderation/mfa/recover','/v1/envelopes','/v2/mailboxes','/v2/commerce/redeem']

class Harness:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vo1d-fuzz-')
        self.relay = Relay(Path(self.temp.name)/'relay.sqlite3')
        self.relay.rate = lambda *args, **kwargs: None
        self.secret = Ed25519PrivateKey.generate()
        public = self.secret.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)
        import hashlib
        self.card = {'id':hashlib.sha256(public).hexdigest(),'signingKey':base64.b64encode(public).decode(),'agreementKey':base64.b64encode(X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw,PublicFormat.Raw)).decode()}
        self.card['binding'] = base64.b64encode(self.secret.sign(card_bytes(self.card))).decode()
        self.token = secrets.token_urlsafe(32); self.mod_token = secrets.token_urlsafe(32)
        with self.relay.db() as db:
            db.execute('INSERT INTO identities VALUES (?,?)',(self.card['id'],json.dumps(self.card)))
            db.execute('INSERT INTO sessions VALUES (?,?,?)',(hashlib.sha256(self.token.encode()).hexdigest(),self.card['id'],int(time.time())+3600))
            db.execute('INSERT INTO permanent_admin VALUES (1,?,?,?)',(self.card['id'],json.dumps(self.card),int(time.time())))
            db.execute('INSERT INTO moderator_sessions VALUES (?,?,?,?)',(hashlib.sha256(self.mod_token.encode()).hexdigest(),self.card['id'],hashlib.sha256(self.token.encode()).hexdigest(),int(time.time())+3600))

    def run(self, data):
        if len(data)>65536: return
        selector = data[0] if data else 0; raw = data[1:]
        env = dict(REQUEST_METHOD='POST',PATH_INFO=PATHS[selector%len(PATHS)],CONTENT_TYPE='application/json',CONTENT_LENGTH=str(len(raw)),REMOTE_ADDR='127.0.0.1')
        env['wsgi.input'] = io.BytesIO(raw); env['HTTP_AUTHORIZATION'] = 'Bearer '+self.token; env['HTTP_X_MODERATION_TOKEN'] = self.mod_token
        statuses = []
        response = b''.join(self.relay(env,lambda status,headers: statuses.append(int(status.split()[0]))))
        if not statuses or statuses[0]>=500:
            # libFuzzer writes the failing input to its configured local artifact.
            raise AssertionError('Malformed request caused internal relay failure')
        if len(response)>4*1024*1024: raise AssertionError('Unbounded API response')
        json.loads(response)

    def seeds(self):
        shapes = [b'',b'{}',b'[]',b'null',b'{"envelope":[]}',b'{"envelope":{},"subject":{},"reason":"spam","source":"message","consent":true}',b'{"report":[],"assignee":{},"expectedUpdated":0}',b'{"card":{},"name":[],"token":0,"username":"example_bot"}',b'{"code":null}',b'{"bundles":[{}]}',b'{"recoveryCode":false}']
        return [bytes([i])+shape for i in range(len(PATHS)) for shape in shapes]

def main():
    os.environ['VO1D_MODERATION_KEY'] = base64.b64encode(os.urandom(32)).decode()
    os.environ['VO1D_COMMERCE_SIGNING_KEY'] = base64.b64encode(os.urandom(32)).decode()
    harness = Harness()
    if REPLAY:
        for seed in harness.seeds(): harness.run(seed)
        print(f'Replayed {len(harness.seeds())} malformed API seeds without internal errors')
        harness.temp.cleanup(); return
    @atheris.instrument_func
    def test_one_input(data): harness.run(data)
    corpus = Path('build-evidence/fuzz-corpus'); corpus.mkdir(parents=True,exist_ok=True)
    for i,seed in enumerate(harness.seeds()): (corpus/f'seed-{i:03}').write_bytes(seed)
    atheris.Setup(sys.argv,test_one_input)
    atheris.Fuzz()

if __name__=='__main__': main()
