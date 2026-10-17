import base64
import concurrent.futures
import time
import unittest
import test_moderation
import moderation


class RecoveryTests(unittest.TestCase):
    setUp = test_moderation.ModerationTests.setUp
    tearDown = test_moderation.ModerationTests.tearDown
    request = test_moderation.ModerationTests.request
    login = test_moderation.ModerationTests.login
    mod_request = test_moderation.ModerationTests.mod_request
    mr = test_moderation.ModerationTests.mr
    claim = test_moderation.ModerationTests.claim

    def enroll(self):
        self.claim()
        status, setup = self.request('/v2/moderation/mfa/setup', 'POST', {}, self.a)
        self.assertEqual(status, 200)
        secret = base64.b32decode(setup['secret'])
        status, result = self.request('/v2/moderation/mfa/verify', 'POST', {'code': moderation.totp(secret, int(time.time())//30)}, self.a)
        self.assertEqual(status, 200)
        self.assertEqual(len(result['recoveryCodes']), 8)
        self.assertEqual(len(set(result['recoveryCodes'])), 8)
        return result, secret

    def test_recovery_requires_account_keys_and_single_code_and_revokes_sessions(self):
        result, _ = self.enroll(); code = result['recoveryCodes'][0]
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': code}, self.b)[0], 403)
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': 'A'*22}, self.a)[0], 403)
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': code}, self.a)[0], 200)
        self.assertEqual(self.mr('/v2/moderation/queue', token=result['token'])[0], 401)
        self.a = self.login(self.alice, self.alice_card)
        self.assertEqual(self.request('/v2/moderation/access', token=self.a)[1], {'role': 'owner', 'mfaEnabled': False})
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': result['recoveryCodes'][1]}, self.a)[0], 403)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.b)[0], 409)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM moderator_recovery').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM moderator_mfa').fetchone()[0], 0)
            self.assertEqual(moderation.owner(db)['owner'], self.alice_card['id'])

    def test_codes_are_hashed_and_rotation_requires_mfa_session_plus_fresh_otp(self):
        result, secret = self.enroll()
        with self.relay.db() as db:
            stored = str([dict(r) for r in db.execute('SELECT * FROM moderator_recovery')])
            for code in result['recoveryCodes']: self.assertNotIn(code, stored)
        path = '/v2/moderation/mfa/recovery-codes'
        fresh = moderation.totp(secret, int(time.time())//30+1)
        self.assertEqual(self.request(path, 'POST', {'code': fresh}, self.a)[0], 403)
        self.assertEqual(self.mr(path, 'POST', {'code': '000000'}, token=result['token'])[0], 403)
        status, rotated = self.mr(path, 'POST', {'code': fresh}, token=result['token'])
        self.assertEqual(status, 200)
        self.assertEqual(self.mr(path, 'POST', {'code': fresh}, token=result['token'])[0], 403)
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': result['recoveryCodes'][0]}, self.a)[0], 403)
        self.assertEqual(self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': rotated['recoveryCodes'][0]}, self.a)[0], 200)

    def test_concurrent_recovery_code_cannot_be_consumed_twice(self):
        result, _ = self.enroll()
        def attempt(_): return self.request('/v2/moderation/mfa/recover', 'POST', {'recoveryCode': result['recoveryCodes'][0]}, self.a)[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: statuses = list(pool.map(attempt, range(2)))
        self.assertEqual(statuses.count(200), 1)
        self.assertTrue(set(statuses).issubset({200,401,403}))
