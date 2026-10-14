import base64
import concurrent.futures
import hashlib
import io
import json
import os
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import test_relay
from app import Relay, card_bytes, header_bytes
import moderation
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


class ModerationTests(unittest.TestCase):
    request = test_relay.RelayTests.request
    login = test_relay.RelayTests.login

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.relay = Relay(Path(self.temp.name) / 'relay.sqlite3')
        self.master = patch.dict(os.environ, {'VO1D_MODERATION_KEY': base64.b64encode(os.urandom(32)).decode()})
        self.master.start()
        self.alice, self.alice_card = test_relay.identity()
        self.agreement = X25519PrivateKey.generate()
        self.alice_card['agreementKey'] = test_relay.encode(self.agreement.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
        self.alice_card['binding'] = test_relay.encode(self.alice.sign(card_bytes(self.alice_card)))
        self.bob, self.bob_card = test_relay.identity()
        self.charlie, self.charlie_card = test_relay.identity()
        self.a = self.login(self.alice, self.alice_card)
        self.b = self.login(self.bob, self.bob_card)
        self.c = self.login(self.charlie, self.charlie_card)

    def tearDown(self):
        self.master.stop()
        self.temp.cleanup()

    def claim(self):
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'Vo1D'}, self.a)[0], 200)

    def mod_request(self, path, method='GET', body=None, token=None, account=None):
        data = json.dumps(body).encode() if body is not None else b''
        path, _, query = path.partition('?')
        env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': query, 'CONTENT_LENGTH': str(len(data)), 'CONTENT_TYPE': 'application/json',
               'REMOTE_ADDR': '127.0.0.1', 'wsgi.input': io.BytesIO(data), 'HTTP_AUTHORIZATION': 'Bearer ' + (account or self.a)}
        if token:
            env['HTTP_X_MODERATION_TOKEN'] = token
        status = []
        def start(value, headers):
            status.append(int(value.split()[0]))
        return status, b''.join(self.relay(env, start))

    def mr(self, *args, **kwargs):
        status, out = self.mod_request(*args, **kwargs)
        return status[0], json.loads(out)

    def mfa(self, account=None):
        account = account or self.a
        status, setup = self.request('/v2/moderation/mfa/setup', 'POST', {}, account)
        self.assertEqual(status, 200)
        secret = base64.b32decode(setup['secret'])
        status, result = self.request('/v2/moderation/mfa/verify', 'POST', {'code': moderation.totp(secret, int(time.time()) // 30)}, account)
        self.assertEqual(status, 200)
        return result['token'], secret

    def report(self, subject=None):
        ephemeral = X25519PrivateKey.generate()
        e = dict(id=str(uuid.uuid4()), sender=self.bob_card['id'], recipient=self.alice_card['id'],
                 ephemeralKey=test_relay.encode(ephemeral.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
                 salt=test_relay.encode(os.urandom(32)), expiresAt=int(time.time()) + 3600, ciphertext='', signature='')
        secret = ephemeral.exchange(X25519PublicKey.from_public_bytes(base64.b64decode(self.alice_card['agreementKey'])))
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=base64.b64decode(e['salt']), info=header_bytes(e)).derive(secret)
        clear = json.dumps({'comment': 'Only this selected evidence', 'messages': ['chosen message']}).encode()
        nonce = os.urandom(12)
        e['ciphertext'] = test_relay.encode(nonce + AESGCM(key).encrypt(nonce, clear, header_bytes(e)))
        e['signature'] = test_relay.encode(self.bob.sign(header_bytes(e) + b'\n' + base64.b64decode(e['ciphertext'])))
        return dict(subject=subject or self.charlie_card['id'], reason='spam', source='message', consent=True, envelope=e)

    def submit(self):
        body = self.report()
        self.assertEqual(self.request('/v2/reports', 'POST', body, self.b)[0], 200)
        return body['envelope']['id']

    def test_first_claim_is_permanent_through_rename_delete_restart_and_recovery(self):
        self.claim()
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.b)[0], 409)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'another'}, self.a)[0], 409)
        self.assertEqual(self.request('/v1/account', 'DELETE', token=self.a)[0], 200)
        self.relay = Relay(self.relay.path)
        self.assertFalse(self.request('/v1/username/check/vo1d', token=self.b)[1]['available'])
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.b)[0], 409)
        self.a = self.login(self.alice, self.alice_card)
        self.claim()
        self.assertEqual(self.request('/v2/moderation/access', token=self.a)[1]['role'], 'owner')

    def test_concurrent_claim_has_exactly_one_winner(self):
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda token: self.request('/v1/username', 'POST', {'username': 'vo1d'}, token)[0], (self.a, self.b)))
        self.assertEqual(sorted(results), [200, 409])

    def test_admin_encryption_key_rotation_requires_migration_even_after_deletion(self):
        self.claim()
        changed = dict(self.alice_card, agreementKey=self.bob_card['agreementKey'])
        changed['binding'] = test_relay.encode(self.alice.sign(card_bytes(changed)))
        self.assertEqual(self.request('/v1/register', 'POST', changed)[0], 409)
        self.request('/v1/account', 'DELETE', token=self.a)
        self.assertEqual(self.request('/v1/register', 'POST', changed)[0], 409)

    def test_ciphertext_is_only_revealed_to_owner_after_mfa(self):
        self.claim()
        case = self.submit()
        self.assertEqual(self.mr('/v2/moderation/queue')[0], 403)
        mod, _ = self.mfa()
        self.assertEqual(self.mr('/v2/moderation/queue', token=mod)[1]['reports'][0]['id'], case)
        status, payload = self.mr('/v2/moderation/report/' + case, token=mod)
        self.assertEqual(status, 200)
        e = payload['envelope']
        secret = self.agreement.exchange(X25519PublicKey.from_public_bytes(base64.b64decode(e['ephemeralKey'])))
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=base64.b64decode(e['salt']), info=header_bytes(e)).derive(secret)
        combined = base64.b64decode(e['ciphertext'])
        self.assertIn(b'Only this selected evidence', AESGCM(key).decrypt(combined[:12], combined[12:], header_bytes(e)))
        with self.relay.db() as db:
            self.assertNotIn('Only this selected evidence', db.execute('SELECT envelope FROM reports').fetchone()[0])
            self.assertEqual(db.execute('SELECT count(*) FROM envelopes').fetchone()[0], 0)

    def test_consent_plaintext_and_signature_rejections(self):
        self.claim()
        for change in ({'consent': False}, {'comment': 'plaintext'}, {'subject': []}, {'reason': []}):
            body = self.report(); body.update(change)
            self.assertEqual(self.request('/v2/reports', 'POST', body, self.b)[0], 400)
        body = self.report(); body['envelope']['signature'] = test_relay.encode(bytes(64))
        self.assertEqual(self.request('/v2/reports', 'POST', body, self.b)[0], 403)
        body = self.report(); body['envelope']['recipient'] = self.charlie_card['id']
        self.assertEqual(self.request('/v2/reports', 'POST', body, self.b)[0], 400)

    def test_retry_is_idempotent_but_changed_metadata_and_flood_are_rejected(self):
        self.claim(); body = self.report()
        for _ in range(2):
            self.assertEqual(self.request('/v2/reports', 'POST', body, self.b)[0], 200)
        changed = dict(body, reason='other')
        self.assertEqual(self.request('/v2/reports', 'POST', changed, self.b)[0], 409)
        self.assertEqual(self.request('/v2/reports', 'POST', self.report(), self.b)[0], 429)

    def test_mfa_replay_binding_expiry_and_no_reset(self):
        self.claim(); token, secret = self.mfa()
        code = moderation.totp(secret, int(time.time()) // 30)
        self.assertEqual(self.request('/v2/moderation/mfa/verify', 'POST', {'code': code}, self.a)[0], 403)
        self.assertEqual(self.request('/v2/moderation/mfa/setup', 'POST', {}, self.a)[0], 409)
        new_account = self.login(self.alice, self.alice_card)
        self.assertEqual(self.mr('/v2/moderation/queue', token=token, account=new_account)[0], 403)
        with self.relay.db() as db:
            db.execute('UPDATE moderator_sessions SET expires=0')
        self.assertEqual(self.mr('/v2/moderation/queue', token=token)[0], 403)

    def test_unconfigured_master_fails_closed_and_secret_is_not_plaintext(self):
        self.claim()
        with patch.dict(os.environ, {'VO1D_MODERATION_KEY': ''}):
            self.assertEqual(self.request('/v2/moderation/mfa/setup', 'POST', {}, self.a)[0], 503)
        _, secret = self.mfa()
        with self.relay.db() as db:
            stored = db.execute('SELECT secret FROM moderator_mfa').fetchone()[0]
            self.assertNotIn(secret, stored)

    def test_roles_cannot_read_evidence_or_escalate_privileges(self):
        self.claim(); case = self.submit(); mod, _ = self.mfa()
        self.assertEqual(self.mr('/v2/moderation/roles', 'POST', {'identity': self.charlie_card['id'], 'role': 'reviewer'}, mod)[0], 200)
        reviewer, _ = self.mfa(self.c)
        self.assertEqual(self.mr('/v2/moderation/queue', token=reviewer, account=self.c)[0], 200)
        self.assertEqual(self.mr('/v2/moderation/report/' + case, token=reviewer, account=self.c)[0], 403)
        self.assertEqual(self.mr('/v2/moderation/roles', 'POST', {'identity': self.bob_card['id'], 'role': 'admin'}, reviewer, self.c)[0], 403)
        revision = self.mr('/v2/moderation/queue', token=mod)[1]['reports'][0]['updated']
        decision = dict(report=case, status='resolved', action='ban', seconds=3600, expectedUpdated=revision)
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, reviewer, self.c)[0], 403)
        self.assertEqual(self.mr('/v2/moderation/roles', 'POST', {'identity': self.charlie_card['id'], 'role': 'none'}, mod)[0], 200)
        self.assertEqual(self.mr('/v2/moderation/queue', token=reviewer, account=self.c)[0], 403)

    def test_decision_revision_sanction_notice_and_appeal_access(self):
        self.claim(); case = self.submit(); mod, _ = self.mfa()
        revision = self.mr('/v2/moderation/queue', token=mod)[1]['reports'][0]['updated']
        decision = dict(report=case, status='resolved', action='ban', seconds=3600, expectedUpdated=revision)
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, mod)[0], 200)
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, mod)[0], 409)
        self.assertEqual(self.request('/v1/envelopes', 'POST', {}, self.c)[0], 403)
        self.assertEqual(self.request('/v2/reports/notices', token=self.c)[1]['notices'][0]['action'], 'ban')
        appeal = self.report()['envelope']
        appeal['sender'] = self.charlie_card['id']
        appeal['signature'] = test_relay.encode(self.charlie.sign(header_bytes(appeal) + b'\n' + base64.b64decode(appeal['ciphertext'])))
        body = dict(report=case, consent=True, envelope=appeal)
        self.assertEqual(self.request('/v2/appeals', 'POST', body, self.b)[0], 404)
        self.assertEqual(self.request('/v2/appeals', 'POST', body, self.c)[0], 200)
        self.assertEqual(self.request('/v2/appeals', 'POST', body, self.c)[0], 200)
        decision.update(action='lift', expectedUpdated=self.mr('/v2/moderation/queue', token=mod)[1]['reports'][0]['updated'])
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, mod)[0], 200)
        self.assertEqual(self.request('/v2/reports/notices', token=self.c)[1]['notices'], [])

    def test_retention_and_hash_chained_audit(self):
        self.claim(); self.submit(); mod, _ = self.mfa()
        events = self.mr('/v2/moderation/audit', token=mod)[1]['events']
        previous = '0' * 64
        for event in reversed(events):
            self.assertEqual(event['previous'], previous)
            previous = hashlib.sha256((previous + '\n' + event['entry']).encode()).hexdigest()
            self.assertEqual(previous, event['digest'])
        with self.relay.db() as db:
            moderation.clean(db, int(time.time()) + 8 * 86400)
            self.assertEqual(db.execute('SELECT envelope FROM reports').fetchone()[0], '')
            moderation.clean(db, int(time.time()) + 91 * 86400)
            self.assertEqual(db.execute('SELECT count(*) FROM reports').fetchone()[0], 0)
            self.assertIsNotNone(moderation.owner(db))

    def test_delete_owner_does_not_reset_enabled_mfa(self):
        self.claim(); self.mfa()
        self.request('/v1/account', 'DELETE', token=self.a)
        self.a = self.login(self.alice, self.alice_card)
        self.assertEqual(self.request('/v2/moderation/mfa/setup', 'POST', {}, self.a)[0], 409)
        self.assertEqual(self.mr('/v2/moderation/queue')[0], 403)
        self.assertEqual(self.request('/v1/username', 'DELETE', token=self.a)[0], 409)

    def test_valid_signature_cannot_register_non_contributory_agreement_key(self):
        private, card = test_relay.identity()
        card['agreementKey'] = test_relay.encode(bytes(32))
        card['binding'] = test_relay.encode(private.sign(card_bytes(card)))
        self.assertEqual(self.request('/v1/register', 'POST', card)[0], 400)


if __name__ == '__main__':
    unittest.main()
