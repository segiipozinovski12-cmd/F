import base64
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

import test_relay as fixtures
from push import PushService


class PushTests(unittest.IsolatedAsyncioTestCase):
    setUp = fixtures.RelayTests.setUp
    tearDown = fixtures.RelayTests.tearDown
    request = fixtures.RelayTests.request
    login = fixtures.RelayTests.login

    def service(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        key_path = Path(self.temp.name)/'provider.p8'
        key_path.write_bytes(self.key.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        with patch.dict(os.environ,{'VO1D_APNS_KEY_ID':'KEYID','VO1D_APNS_TEAM_ID':'TEAMID',
                                    'VO1D_APNS_KEY_PATH':str(key_path),'VO1D_APNS_TOPIC':'io.test.messenger'}):
            return PushService(self.relay)

    async def test_provider_jwt_has_valid_p256_signature(self):
        service = self.service()
        token = service.jwt()
        header, claims, signature = token.split('.')
        decode = lambda value: base64.urlsafe_b64decode(value+'='*(-len(value)%4))
        self.assertEqual(json.loads(decode(header)),{'alg':'ES256','kid':'KEYID'})
        self.assertEqual(json.loads(decode(claims))['iss'],'TEAMID')
        raw = decode(signature)
        self.assertEqual(len(raw),64)
        der = utils.encode_dss_signature(int.from_bytes(raw[:32],'big'),int.from_bytes(raw[32:],'big'))
        self.key.public_key().verify(der,(header+'.'+claims).encode(),ec.ECDSA(hashes.SHA256()))
        self.assertEqual(service.jwt(),token)

    async def test_neutral_alert_payload_debounce_and_environment(self):
        service = self.service()
        self.request('/v1/push','POST',{'token':'e'*64,'kind':'alert','environment':'sandbox'},self.a)
        calls = []
        async def post(url,**kwargs):
            calls.append((url,kwargs))
            return SimpleNamespace(status_code=200)
        service._client = SimpleNamespace(post=post)
        self.assertTrue(await service.send(self.alice_card['id']))
        self.assertFalse(await service.send(self.alice_card['id']))
        self.assertEqual(len(calls),1)
        url, request = calls[0]
        self.assertIn('api.sandbox.push.apple.com',url)
        self.assertEqual(request['headers']['apns-topic'],'io.test.messenger')
        self.assertEqual(set(request['json']),{'aps'})
        self.assertNotIn(self.alice_card['id'],json.dumps(request['json']))
        self.assertNotIn(self.bob_card['id'],json.dumps(request['json']))

    async def test_voip_payload_and_invalid_token_cleanup(self):
        service = self.service()
        self.request('/v1/push','POST',{'token':'f'*64,'kind':'voip','environment':'production'},self.b)
        calls = []
        async def post(url,**kwargs):
            calls.append((url,kwargs))
            return SimpleNamespace(status_code=410,json=lambda:{'reason':'Unregistered'})
        service._client = SimpleNamespace(post=post)
        self.assertFalse(await service.send(self.bob_card['id'],'voip',{'id':'call-id','from':self.alice_card['id']}))
        url, request = calls[0]
        self.assertIn('api.push.apple.com',url)
        self.assertEqual(request['headers']['apns-topic'],'io.test.messenger.voip')
        self.assertEqual(request['json']['callID'],'call-id')
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM push_tokens').fetchone()[0],0)

    async def test_disabled_provider_does_not_attempt_network(self):
        with patch.dict(os.environ,{'VO1D_APNS_KEY_ID':'','VO1D_APNS_TEAM_ID':'','VO1D_APNS_KEY_PATH':''}):
            service = PushService(self.relay)
        self.assertFalse(await service.send(self.alice_card['id']))
        self.assertIsNone(service._client)
