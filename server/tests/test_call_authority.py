import base64
import hashlib
import time
import unittest
import test_relay as fixtures
from app import APIError
from call_authority import authorize, bytes_for

class CallAuthorityTests(unittest.TestCase):
    setUp=fixtures.RelayTests.setUp
    tearDown=fixtures.RelayTests.tearDown
    request=fixtures.RelayTests.request
    login=fixtures.RelayTests.login

    def certificate(self):
        cert=dict(owner=self.alice_card['id'],key=self.bob_card['signingKey'],expiresAt=int(time.time())+3600)
        cert['signature']=base64.b64encode(self.alice.sign(bytes_for(cert))).decode()
        return cert

    def test_call_token_cannot_authenticate_any_account_operation(self):
        cert=self.certificate()
        status,result=self.request('/v2/call-authority','POST',cert,self.a)
        self.assertEqual(status,200)
        token=result['token']
        with self.relay.db() as db:
            owner,stored=authorize(db,'CallCapability '+token,APIError)
            self.assertEqual(owner,self.alice_card['id']); self.assertEqual(stored,cert)
            self.assertNotIn(token,str(tuple(db.execute('SELECT * FROM call_authorities').fetchone())))
        for path,method,body in [('/v1/inbox','GET',None),('/v1/account','DELETE',None),('/v2/prekeys','GET',None),('/v1/push','POST',{})]:
            self.assertEqual(self.request(path,method,body,token)[0],401)

    def test_revocation_is_owner_scoped(self):
        token=self.request('/v2/call-authority','POST',self.certificate(),self.a)[1]['token']
        self.request('/v2/call-authority','DELETE',token=self.b)
        with self.relay.db() as db: self.assertEqual(authorize(db,'CallCapability '+token,APIError)[0],self.alice_card['id'])
        self.request('/v2/call-authority','DELETE',token=self.a)
        with self.relay.db() as db:
            with self.assertRaises(APIError): authorize(db,'CallCapability '+token,APIError)

    def test_signature_scope_expiry_and_key_mutation(self):
        cert=self.certificate(); cert['key']=self.alice_card['signingKey']
        self.assertEqual(self.request('/v2/call-authority','POST',cert,self.a)[0],403)
        for field,value in [('owner',self.bob_card['id']),('expiresAt',True),('expiresAt',int(time.time())+90000),('scope','account')]:
            cert=self.certificate(); cert[field]=value
            self.assertEqual(self.request('/v2/call-authority','POST',cert,self.a)[0],400)
        token=self.request('/v2/call-authority','POST',self.certificate(),self.a)[1]['token']
        with self.relay.db() as db:
            db.execute('UPDATE call_authorities SET expires=0')
            with self.assertRaises(APIError): authorize(db,'CallCapability '+token,APIError)
