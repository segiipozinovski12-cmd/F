import base64
import copy
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
import test_relay as fixtures
from prekeys import signed_bytes


class PrekeyTests(unittest.TestCase):
    setUp = fixtures.RelayTests.setUp
    tearDown = fixtures.RelayTests.tearDown
    request = fixtures.RelayTests.request
    login = fixtures.RelayTests.login

    def bundle(self, key_id=1):
        b64 = lambda b: base64.b64encode(b).decode()
        public = b64(b'\x05' + bytes(range(32)))
        owner = self.alice_card['id']
        binding = self.alice.sign(f'VO1D-SIGNAL-IDENTITY-2\n{owner}\n{public}'.encode())
        result = dict(owner=owner,identityKey=public,identityBinding=b64(binding),registrationId=1,deviceId=1,
                      signedPrekeyId=1,signedPrekey=public,signedPrekeySignature=b64(bytes(64)),
                      prekeyId=key_id,prekey=public,kyberPrekeyId=key_id+100,
                      kyberPrekey=b64(bytes(1569)),kyberPrekeySignature=b64(bytes(64)),expiresAt=int(time.time())+3600)
        result['signature']=b64(self.alice.sign(signed_bytes(result)))
        return result

    def publish(self, bundles):
        return self.request('/v2/prekeys','POST',{'bundles':bundles},self.a)

    def claim(self):
        return self.request('/v2/prekeys/'+self.alice_card['id'],'POST',{},self.b)

    def test_withdraw_is_one_use_and_publication_retry_does_not_resurrect(self):
        bundle=self.bundle()
        self.assertEqual(self.publish([bundle])[0],200)
        self.assertEqual(self.claim(),(200,bundle))
        self.assertEqual(self.publish([bundle])[0],200)
        self.assertEqual(self.claim()[0],404)
        self.assertEqual(self.request('/v2/prekeys',token=self.a)[1]['available'],0)

    def test_concurrent_claims_return_distinct_keys(self):
        self.publish([self.bundle(i) for i in range(1,13)])
        with ThreadPoolExecutor(max_workers=6) as workers:
            results=list(workers.map(lambda _:self.claim(),range(18)))
        claimed=[body['prekeyId'] for status,body in results if status==200]
        self.assertEqual(len(claimed),12)
        self.assertEqual(len(set(claimed)),12)
        self.assertEqual(sum(status==404 for status,_ in results),6)

    def test_mutated_certificate_and_atomic_invalid_batch(self):
        bad=self.bundle(2); bad['prekey']=self.bob_card['agreementKey']
        self.assertEqual(self.publish([self.bundle(),bad])[0],400)
        self.assertEqual(self.request('/v2/prekeys',token=self.a)[1]['available'],0)
        bad=self.bundle(); bad['registrationId']=2
        self.assertEqual(self.publish([bad])[0],403)
        self.assertEqual(self.claim()[0],404)

    def test_owner_types_expiry_and_unknown_fields(self):
        for field,value in [('owner',self.bob_card['id']),('deviceId',True),('prekeyId',0),('expiresAt',int(time.time())-1),('plaintext','secret')]:
            bundle=self.bundle(); bundle[field]=value
            self.assertEqual(self.publish([bundle])[0],400)
        self.assertEqual(self.publish([])[0],400)
        self.assertEqual(self.publish([self.bundle(),self.bundle()])[0],400)

    def test_same_id_different_bundle_is_rejected(self):
        original=self.bundle(); self.publish([original])
        changed=copy.deepcopy(original); changed['registrationId']=2
        changed['signature']=base64.b64encode(self.alice.sign(signed_bytes(changed))).decode()
        self.assertEqual(self.publish([changed])[0],409)

    def test_expiry_and_account_deletion_remove_prekeys(self):
        self.publish([self.bundle()])
        with self.relay.db() as db: db.execute('UPDATE signal_prekeys SET expires=0')
        self.assertEqual(self.claim()[0],404)
        self.publish([self.bundle(2)])
        self.request('/v1/account','DELETE',token=self.a)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM signal_prekeys').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT count(*) FROM signal_identities').fetchone()[0],0)
