import base64
import hashlib
import secrets
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
import test_relay as fixtures

class MailboxTests(unittest.TestCase):
    setUp=fixtures.RelayTests.setUp
    tearDown=fixtures.RelayTests.tearDown
    request=fixtures.RelayTests.request
    login=fixtures.RelayTests.login

    def mailbox(self):
        result=dict(id=secrets.token_urlsafe(32),readToken=secrets.token_urlsafe(32),writeToken=secrets.token_urlsafe(32),expiresAt=int(time.time())+86400)
        prefix=f"VO1D-MAILBOX-WORK-2\n{result['id']}\n{result['expiresAt']}\n".encode()
        nonce=0
        while int.from_bytes(hashlib.sha256(prefix+str(nonce).encode()).digest(),'big') >> 238:
            nonce+=1
        result['proof']=str(nonce)
        self.assertEqual(self.request('/v2/mailboxes','POST',result)[0],200)
        return result

    def call(self, box, action, method='GET', body=None, scope='read'):
        # The fixture prefixes Bearer; substitute a capability in the WSGI environment.
        original=self.relay.user
        import io,json
        raw=json.dumps(body).encode() if body is not None else b''
        env={'REQUEST_METHOD':method,'PATH_INFO':'/v2/mailboxes/'+box['id']+('/'+action if action else ''),
             'CONTENT_LENGTH':str(len(raw)),'CONTENT_TYPE':'application/json','REMOTE_ADDR':'127.0.0.1',
             'HTTP_AUTHORIZATION':'Capability '+box[scope+'Token'],'wsgi.input':io.BytesIO(raw)}
        response={}
        def start(status,headers): response['status']=int(status.split()[0])
        return_body=b''.join(self.relay(env,start))
        return response['status'],json.loads(return_body)

    def envelope(self,box):
        import uuid
        b64=lambda b:base64.b64encode(b).decode()
        return dict(id=str(uuid.uuid4()),mailbox=box['id'],ephemeralKey=b64(bytes(32)),salt=b64(bytes(32)),
                    expiresAt=int(time.time())+3600,ciphertext=b64(bytes(2076)))

    def test_deleted_address_cannot_be_recreated_by_late_retry(self):
        box=self.mailbox()
        self.assertEqual(self.call(box,'','DELETE')[0],200)
        self.assertEqual(self.call(box,'','DELETE')[0],200)
        self.assertEqual(self.request('/v2/mailboxes','POST',box)[0],409)
        self.assertEqual(self.call(box,'inbox')[0],403)
        self.assertEqual(self.call(box,'envelopes','POST',self.envelope(box),'write')[0],403)

    def test_independent_caps_no_account_sender_and_no_token_storage(self):
        box=self.mailbox(); envelope=self.envelope(box)
        self.assertEqual(self.call(box,'envelopes','POST',envelope,'write')[0],200)
        self.assertEqual(self.call(box,'inbox')[1]['envelopes'],[envelope])
        self.assertEqual(self.call(box,'inbox',scope='write')[0],403)
        self.assertEqual(self.call(box,'envelopes','POST',envelope,'read')[0],403)
        with self.relay.db() as db:
            record=str(tuple(db.execute('SELECT * FROM private_mailboxes').fetchone()))
            self.assertNotIn(box['readToken'],record)
            self.assertNotIn(box['writeToken'],record)
            self.assertNotIn(self.alice_card['id'],record)
            self.assertNotIn(self.bob_card['id'],record)

    def test_ack_retry_collision_and_owner_isolation(self):
        box=self.mailbox(); other=self.mailbox(); e=self.envelope(box)
        self.call(box,'envelopes','POST',e,'write')
        self.call(other,'ack','POST',{'ids':[e['id']]})
        self.assertEqual(len(self.call(box,'inbox')[1]['envelopes']),1)
        self.call(box,'ack','POST',{'ids':[e['id']]})
        self.assertEqual(self.call(box,'envelopes','POST',e,'write')[0],200)
        self.assertEqual(self.call(box,'inbox')[1]['envelopes'],[])
        e['ciphertext']=base64.b64encode(b'x'*2076).decode()
        self.assertEqual(self.call(box,'envelopes','POST',e,'write')[0],409)

    def test_metadata_plaintext_and_unpadded_payload_rejected(self):
        box=self.mailbox()
        for field,value in [('sender',self.alice_card['id']),('plaintext','secret'),('writeToken',box['writeToken'])]:
            e=self.envelope(box); e[field]=value
            self.assertEqual(self.call(box,'envelopes','POST',e,'write')[0],400)
        e=self.envelope(box); e['ciphertext']=base64.b64encode(bytes(100)).decode()
        self.assertEqual(self.call(box,'envelopes','POST',e,'write')[0],400)

    def test_delete_revokes_both_capabilities_and_queued_content(self):
        box=self.mailbox(); self.call(box,'envelopes','POST',self.envelope(box),'write')
        self.assertEqual(self.call(box,'',method='DELETE',scope='write')[0],403)
        self.assertEqual(self.call(box,'',method='DELETE')[0],200)
        self.assertEqual(self.call(box,'inbox')[0],403)
        with self.relay.db() as db:
            for table in ('private_mailboxes','private_envelopes','private_seen'):
                self.assertEqual(db.execute('SELECT count(*) FROM '+table).fetchone()[0],0)

    def test_concurrent_retry_is_deduplicated(self):
        box=self.mailbox(); e=self.envelope(box)
        with ThreadPoolExecutor(max_workers=6) as workers:
            results=list(workers.map(lambda _:self.call(box,'envelopes','POST',e,'write')[0],range(12)))
        self.assertEqual(results,[200]*12)
        self.assertEqual(len(self.call(box,'inbox')[1]['envelopes']),1)

    def test_private_invite_is_opaque_one_use_and_revocable(self):
        box=self.mailbox(); token=secrets.token_urlsafe(32)
        body=dict(token=token,ciphertext=base64.b64encode(b'x'*256).decode(),expiresAt=int(time.time())+3600)
        self.assertEqual(self.call(box,'invites','POST',body,scope='write')[0],403)
        self.assertEqual(self.call(box,'invites','POST',body)[0],200)
        self.assertEqual(self.request('/v2/private-invites/'+token)[1],{'ciphertext':body['ciphertext']})
        self.assertEqual(self.request('/v2/private-invites/'+token)[0],404)
        other=secrets.token_urlsafe(32); body['token']=other
        self.call(box,'invites','POST',body)
        self.call(box,'',method='DELETE')
        self.assertEqual(self.request('/v2/private-invites/'+other)[0],404)
