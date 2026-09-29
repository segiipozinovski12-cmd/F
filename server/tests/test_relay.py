import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import Relay, card_bytes, header_bytes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def encode(data):
    return base64.b64encode(data).decode()


def identity():
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    agreement = X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    card = {'id':hashlib.sha256(public).hexdigest(),'signingKey':encode(public),'agreementKey':encode(agreement)}
    card['binding'] = encode(private.sign(card_bytes(card)))
    return private, card


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.relay = Relay(Path(self.temp.name) / 'test.sqlite3')
        self.alice, self.alice_card = identity()
        self.bob, self.bob_card = identity()
        self.a = self.login(self.alice, self.alice_card)
        self.b = self.login(self.bob, self.bob_card)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, path, method='GET', body=None, token=None):
        data = json.dumps(body).encode() if body is not None else b''
        env = {'REQUEST_METHOD':method,'PATH_INFO':path,'CONTENT_LENGTH':str(len(data)),'CONTENT_TYPE':'application/json','REMOTE_ADDR':'127.0.0.1','wsgi.input':io.BytesIO(data)}
        if token:
            env['HTTP_AUTHORIZATION'] = 'Bearer ' + token
        result = {}
        def start(status, headers):
            result['status'] = int(status.split()[0]); result['headers'] = dict(headers)
        out = b''.join(self.relay(env, start))
        return result['status'], json.loads(out)

    def login(self, private, card):
        self.assertEqual(self.request('/v1/register', 'POST', card)[0], 200)
        _, challenge = self.request('/v1/challenge', 'POST', {'id':card['id']})
        signed = f"VO1D-AUTH-1\n{card['id']}\n{challenge['nonce']}".encode()
        status, result = self.request('/v1/session', 'POST', {'id':card['id'],'nonce':challenge['nonce'],'signature':encode(private.sign(signed))})
        self.assertEqual(status, 200)
        return result['token']

    def envelope(self, sender=None, recipient=None, private=None):
        sender = sender or self.alice_card['id']; recipient = recipient or self.bob_card['id']; private = private or self.alice
        import uuid
        e = {'id':str(uuid.uuid4()),'sender':sender,'recipient':recipient,'ephemeralKey':encode(bytes(32)),'salt':encode(bytes(32)),'expiresAt':int(time.time())+3600,'ciphertext':encode(b'x'*100)}
        e['signature']=encode(private.sign(header_bytes(e)+b'\n'+base64.b64decode(e['ciphertext'])))
        return e

    def send(self, e):
        return self.request('/v1/envelopes', 'POST', e, self.a)

    def test_mailbox_delivery_ack_and_isolation(self):
        e = self.envelope()
        self.assertEqual(self.send(e)[0], 200)
        self.assertEqual(self.request('/v1/inbox', token=self.a)[1]['envelopes'], [])
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'][0]['id'], e['id'])
        self.request('/v1/ack', 'POST', {'ids':[e['id']]}, self.a)
        self.assertEqual(len(self.request('/v1/inbox', token=self.b)[1]['envelopes']), 1)
        self.request('/v1/ack', 'POST', {'ids':[e['id']]}, self.b)
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'], [])

    def test_retry_does_not_duplicate_after_ack(self):
        e = self.envelope(); self.send(e); self.send(e)
        self.assertEqual(len(self.request('/v1/inbox', token=self.b)[1]['envelopes']), 1)
        self.request('/v1/ack', 'POST', {'ids':[e['id']]}, self.b)
        self.assertEqual(self.send(e)[0], 200)
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'], [])

    def test_modified_replay_is_rejected(self):
        e = self.envelope(); self.send(e)
        e['ciphertext'] = encode(b'y'*100)
        e['signature'] = encode(self.alice.sign(header_bytes(e)+b'\n'+b'y'*100))
        self.assertEqual(self.send(e)[0], 409)

    def test_modified_ciphertext_is_rejected(self):
        e = self.envelope(); e['ciphertext'] = encode(b'y'*100)
        self.assertEqual(self.send(e)[0], 403)

    def test_sender_impersonation_rejected(self):
        e = self.envelope(sender=self.bob_card['id'])
        self.assertEqual(self.send(e)[0], 400)

    def test_unsigned_account_rejected(self):
        _, card = identity(); card['binding'] = encode(bytes(64))
        self.assertEqual(self.request('/v1/register', 'POST', card)[0], 400)

    def test_key_substitution_rejected(self):
        card = dict(self.alice_card); card['agreementKey'] = self.bob_card['agreementKey']
        self.assertEqual(self.request('/v1/register', 'POST', card)[0], 400)

    def test_auth_replay_is_rejected(self):
        _, challenge = self.request('/v1/challenge', 'POST', {'id':self.alice_card['id']})
        data = f"VO1D-AUTH-1\n{self.alice_card['id']}\n{challenge['nonce']}".encode()
        body = {'id':self.alice_card['id'],'nonce':challenge['nonce'],'signature':encode(self.alice.sign(data))}
        self.assertEqual(self.request('/v1/session', 'POST', body)[0], 200)
        self.assertEqual(self.request('/v1/session', 'POST', body)[0], 401)

    def test_account_deletion_revokes_session_and_mail(self):
        self.send(self.envelope())
        self.assertEqual(self.request('/v1/account', 'DELETE', token=self.a)[0], 200)
        self.assertEqual(self.request('/v1/inbox', token=self.a)[0], 401)
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'], [])

    def test_block_drops_mail_without_exposing_block(self):
        self.request('/v1/block', 'POST', {'id':self.alice_card['id'],'blocked':True}, self.b)
        self.assertEqual(self.send(self.envelope())[0], 200)
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'], [])
        self.request('/v1/block', 'POST', {'id':self.alice_card['id'],'blocked':False}, self.b)
        self.assertEqual(self.send(self.envelope())[0], 200)
        self.assertEqual(len(self.request('/v1/inbox', token=self.b)[1]['envelopes']), 1)

    def test_expired_message_rejected(self):
        e = self.envelope(); e['expiresAt'] = 1
        self.assertEqual(self.send(e)[0], 400)

    def test_expired_mail_removed(self):
        e = self.envelope(); self.send(e)
        with self.relay.db() as db:
            db.execute('UPDATE envelopes SET expires=1')
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'], [])

    def test_authentication_required(self):
        self.assertEqual(self.request('/v1/inbox')[0], 401)
        self.assertEqual(self.request('/v1/inbox', token='fake')[0], 401)

    def test_invalid_json_shape(self):
        self.assertEqual(self.request('/v1/register', 'POST', [1,2])[0], 400)

    def test_lookup_returns_bound_keys(self):
        status, card = self.request('/v1/identity/'+self.bob_card['id'], token=self.a)
        self.assertEqual(status, 200); self.assertEqual(card, self.bob_card)

    def test_rate_limit(self):
        for _ in range(4):
            self.relay.rate('isolated', 4)
        with self.assertRaises(Exception) as caught:
            self.relay.rate('isolated', 4)
        self.assertEqual(caught.exception.status, 429)

    def test_tokens_are_stored_hashed(self):
        with self.relay.db() as db:
            values = [row[0] for row in db.execute('SELECT digest FROM sessions')]
        self.assertNotIn(self.a, values)
        self.assertIn(hashlib.sha256(self.a.encode()).hexdigest(), values)

    def test_large_content_length_rejected_before_read(self):
        env={'REQUEST_METHOD':'POST','PATH_INFO':'/v1/envelopes','CONTENT_LENGTH':str(20*1024*1024),'wsgi.input':io.BytesIO(b'')}
        status=[]
        self.relay(env, lambda s,h: status.append(s))
        self.assertTrue(status[0].startswith('413'))

if __name__ == '__main__':
    unittest.main()
