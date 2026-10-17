import base64
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import test_relay
from app import Relay
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from reset_accounts import reset


class SocialReleaseTests(unittest.TestCase):
    setUp = test_relay.RelayTests.setUp
    tearDown = test_relay.RelayTests.tearDown
    login = test_relay.RelayTests.login
    request = test_relay.RelayTests.request

    def test_discovery_survives_process_restart_and_visibility_is_respected(self):
        status, code = self.request('/v1/code', 'POST', {}, self.a)
        self.assertEqual(status, 200)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'test'}, self.a)[0], 200)
        self.relay = Relay(self.relay.path)
        self.assertEqual(self.request('/v1/discovery', token=self.a)[1], {'code': code['code'], 'username': 'test'})
        self.assertEqual(self.request('/v1/username/test', token=self.b)[1]['card']['id'], self.alice_card['id'])
        self.assertEqual(self.request('/v1/code/'+code['code'], token=self.b)[1]['id'], self.alice_card['id'])
        self.request('/v1/privacy', 'POST', {'discoverable': False, 'inactivityDays': 0, 'trustedCalls': True}, self.a)
        self.assertEqual(self.request('/v1/username/test', token=self.b)[0], 404)
        self.assertEqual(self.request('/v1/code/'+code['code'], token=self.b)[0], 404)

    def test_retired_commerce_endpoints_are_unavailable(self):
        self.assertEqual(self.request('/v2/commerce', token=self.a)[0], 404)
        self.assertEqual(self.request('/v2/commerce/redeem', 'POST', {'code': 'retired'}, self.a)[0], 404)

    def test_deletion_scrubs_legacy_entitlements_without_reactivating_feature(self):
        with self.relay.db() as db:
            db.execute('CREATE TABLE commerce_receipts (id TEXT, owner TEXT, body TEXT)')
            db.execute('CREATE TABLE commerce_vouchers (owner TEXT, used_by TEXT, receipt TEXT)')
            db.execute('INSERT INTO commerce_receipts VALUES (?,?,?)', ('old', self.alice_card['id'], '{}'))
            db.execute('INSERT INTO commerce_vouchers VALUES (?,?,?)', (self.alice_card['id'], self.alice_card['id'], '{}'))
        self.assertEqual(self.request('/v1/account', 'DELETE', token=self.a)[0], 200)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM commerce_receipts').fetchone()[0], 0)
            row = db.execute('SELECT * FROM commerce_vouchers').fetchone()
            self.assertIsNone(row['owner']); self.assertEqual(row['used_by'], 'deleted'); self.assertIsNone(row['receipt'])

    def test_offline_reset_preserves_backup_and_only_explicit_username_claim_wins(self):
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.b)[0], 200)
        self.assertFalse(self.request('/health')[1]['adminBootstrapPending'])
        old_path = Path(self.relay.path)
        backup = old_path.parent / 'backup'
        reset(old_path, backup, rollout_id="test-reset")
        self.relay = Relay(old_path)
        self.assertEqual(self.request('/v1/discovery', token=self.a)[0], 401)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM identities').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM permanent_admin').fetchone()[0], 0)
        with __import__('sqlite3').connect(backup/'relay.sqlite3') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM identities').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT count(*) FROM permanent_admin').fetchone()[0], 1)
        health = self.request('/health')[1]
        self.assertEqual(health['accountReset'], 'test-reset')
        self.assertTrue(health['adminBootstrapPending'])
        # Old clients cannot silently recreate deleted accounts or win admin.
        self.assertEqual(self.request('/v1/register', 'POST', self.alice_card)[0], 410)
        epoch = self.request('/v2/capabilities')[1]['accountEpoch']
        for card in (self.alice_card, self.bob_card):
            self.assertEqual(self.request('/v1/register', 'POST', dict(card, accountEpoch=epoch, enroll=True))[0], 200)
        # Registering a public card still cannot claim administrator authority.
        with self.relay.db() as db: self.assertEqual(db.execute('SELECT count(*) FROM permanent_admin').fetchone()[0], 0)
        token = self.login(self.bob, self.bob_card)
        self.assertIsNone(self.request('/v1/discovery', token=token)[1]['username'])
        self.assertTrue(self.request('/health')[1]['adminBootstrapPending'])
        token2 = self.login(self.alice, self.alice_card)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, token2)[0], 200)
        self.assertFalse(self.request('/health')[1]['adminBootstrapPending'])
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, token)[0], 409)
        self.relay = Relay(old_path)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'other'}, token2)[0], 409)

    def test_reset_rollout_refuses_other_services_and_missing_persistent_volume(self):
        import reset_rollout
        with patch.dict(os.environ, {}, clear=True), patch.object(reset_rollout, 'reset') as operation:
            self.assertFalse(reset_rollout.apply_requested_reset())
            operation.assert_not_called()

    def test_new_reset_assigns_admin_only_after_verified_registration(self):
        path = Path(self.relay.path)
        reset(path, path.parent / 'admin-backup', first_registration_admin=True)
        self.relay = Relay(path)
        epoch = self.request('/v2/capabilities')[1]['accountEpoch']
        for card in (self.alice_card, self.bob_card):
            old_client = dict(card, accountEpoch=epoch, enroll=True)
            self.assertEqual(self.request('/v1/register', 'POST', old_client)[0], 410)
            self.assertEqual(self.request('/v1/register', 'POST', dict(old_client, enrollmentVersion=2))[0], 200)
        self.assertTrue(self.request('/health')[1]['adminBootstrapPending'])
        # A replayed public card cannot win. Proof of the signing key is required.
        self.assertEqual(self.request('/v1/session', 'POST', {'id':self.alice_card['id'], 'nonce':'bad', 'signature':'bad'})[0], 401)
        bob = self.login(self.bob, self.bob_card)
        self.assertEqual(self.request('/v1/discovery', token=bob)[1]['username'], 'vo1d')
        alice = self.login(self.alice, self.alice_card)
        self.assertIsNone(self.request('/v1/discovery', token=alice)[1]['username'])
        self.assertEqual(self.request('/v1/username', 'POST', {'username':'other'}, bob)[0], 409)
        self.assertEqual(self.request('/v1/username', 'DELETE', token=bob)[0], 409)
        self.relay = Relay(path)
        self.assertFalse(self.request('/health')[1]['adminBootstrapPending'])

    def test_permanent_purge_removes_only_named_account_reset_backups(self):
        from reset_rollout import purge_account_backups
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'reset-backup-vo1d-user-request-20261017-a4ba0300'
            old.mkdir(); (old / 'relay.sqlite3').write_bytes(b'private account records')
            unrelated = root / 'unrelated'; unrelated.mkdir()
            purge_account_backups(root)
            self.assertFalse(old.exists()); self.assertTrue(unrelated.is_dir())
            purge_account_backups(root)  # Idempotent after a completed reset.


if __name__ == '__main__': unittest.main()
