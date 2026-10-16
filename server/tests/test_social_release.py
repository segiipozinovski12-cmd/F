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
import commerce
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from reset_accounts import reset
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


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

    def test_voucher_is_signed_identity_bound_and_idempotent(self):
        with patch.dict(os.environ, {'VO1D_COMMERCE_SIGNING_KEY': base64.b64encode(os.urandom(32)).decode()}):
            with self.relay.db() as db:
                code = commerce.issue(db, 'premium', owner=self.alice_card['id'])
            self.assertEqual(self.request('/v2/commerce/redeem', 'POST', {'code': code}, self.b)[0], 404)
            status, receipt = self.request('/v2/commerce/redeem', 'POST', {'code': code}, self.a)
            self.assertEqual(status, 200)
            Ed25519PublicKey.from_public_bytes(base64.b64decode(commerce.public_key())).verify(base64.b64decode(receipt['signature']), commerce.signed_bytes(receipt))
            self.assertEqual(self.request('/v2/commerce/redeem', 'POST', {'code': code}, self.a)[1], receipt)
            self.assertEqual(len(self.request('/v2/commerce', token=self.a)[1]['receipts']), 1)

    def test_unbound_voucher_concurrent_redemption_has_one_winner(self):
        with patch.dict(os.environ, {'VO1D_COMMERCE_SIGNING_KEY': base64.b64encode(os.urandom(32)).decode()}):
            with self.relay.db() as db: code = commerce.issue(db, 'collectible', label='VOID #1')
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda token: self.request('/v2/commerce/redeem', 'POST', {'code': code}, token), [self.a, self.b]))
            self.assertEqual(sorted(r[0] for r in results), [200, 409])

    def test_offline_reset_preserves_backup_and_first_verified_login_wins(self):
        old_path = Path(self.relay.path)
        backup = old_path.parent / 'backup'
        reset(old_path, backup)
        self.relay = Relay(old_path)
        self.assertEqual(self.request('/v1/discovery', token=self.a)[0], 401)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM identities').fetchone()[0], 0)
        with __import__('sqlite3').connect(backup/'relay.sqlite3') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM identities').fetchone()[0], 2)
        # Registering a card alone cannot claim administrator authority.
        self.request('/v1/register', 'POST', self.alice_card)
        with self.relay.db() as db: self.assertEqual(db.execute('SELECT count(*) FROM permanent_admin').fetchone()[0], 0)
        token = self.login(self.bob, self.bob_card)
        self.assertEqual(self.request('/v1/discovery', token=token)[1]['username'], 'vo1d')
        token2 = self.login(self.alice, self.alice_card)
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, token2)[0], 409)


if __name__ == '__main__': unittest.main()
