import concurrent.futures
import sqlite3
import time
import unittest
import uuid
import os
from pathlib import Path
from unittest.mock import patch

import test_relay
from app import Relay, APIError
import commerce
import moderation


class FounderTests(unittest.TestCase):
    setUp = test_relay.RelayTests.setUp
    tearDown = test_relay.RelayTests.tearDown
    request = test_relay.RelayTests.request
    login = test_relay.RelayTests.login

    def arm_first_verified_login(self):
        with self.relay.db() as db:
            db.execute("INSERT OR REPLACE INTO relay_meta VALUES ('bootstrap_admin_policy','first_verified_registration')")

    def test_enabled_empty_deployment_bootstraps_without_an_account_reset(self):
        with patch.dict(os.environ, {'VO1D_FIRST_ACCOUNT_ADMIN': '1'}):
            self.relay = Relay(Path(self.temp.name) / 'new-deployment.sqlite3')
        token = self.login(self.alice, self.alice_card)
        self.assertEqual(self.request('/v1/discovery', token=token)[1]['username'], 'vo1d')
        self.assertTrue(self.request('/v3/economy/catalog', token=token)[1]['wallet']['premiumLifetime'])
        self.assertEqual(len(self.request('/v3/economy/inventory', token=token)[1]['artifacts']), 5)

    def test_first_verified_session_gets_five_unique_zero_editions_and_lifetime_premium(self):
        self.arm_first_verified_login()
        # Uploading a public card does not consume administrator ownership.
        self.assertEqual(self.request('/v1/register', 'POST', self.bob_card)[0], 200)
        with self.relay.db() as db:
            self.assertIsNone(moderation.owner(db))
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts').fetchone()[0], 0)
        token = self.login(self.bob, self.bob_card)
        self.assertEqual(self.request('/v1/discovery', token=token)[1]['username'], 'vo1d')
        inventory = self.request('/v3/economy/inventory', token=token)[1]['artifacts']
        self.assertEqual(len(inventory), 5)
        self.assertEqual({gift['collection'] for gift in inventory}, {row[0] for row in commerce.COLLECTIONS})
        self.assertTrue(all(gift['serial'] == 0 and gift['owner'] == self.bob_card['id'] and gift['visible'] for gift in inventory))
        wallet = self.request('/v3/economy/catalog', token=token)[1]['wallet']
        self.assertTrue(wallet['premium']); self.assertTrue(wallet['premiumLifetime'])
        self.assertEqual(self.request('/v3/economy/premium-authorize', 'POST', {}, token)[0], 200)
        self.assertEqual(self.request('/v3/economy/premium-authorize', 'POST', {}, self.a)[0], 403)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT sum(minted) FROM artifact_collections').fetchone()[0], 0)
        self.login(self.alice, self.alice_card)
        self.assertFalse(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['premium'])

    def test_concurrent_first_sessions_award_exactly_one_owner(self):
        self.arm_first_verified_login()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            tokens = list(pool.map(lambda pair: self.login(*pair), [(self.alice, self.alice_card), (self.bob, self.bob_card)]))
        with self.relay.db() as db:
            owner = moderation.owner(db)['owner']
            self.assertEqual(db.execute('SELECT owner FROM economy_founder').fetchone()[0], owner)
            self.assertEqual(db.execute('SELECT count(*) FROM economy_founder').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts WHERE owner=? AND serial=0', (owner,)).fetchone()[0], 5)
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts').fetchone()[0], 5)
        self.assertEqual(sum(self.request('/v3/economy/catalog', token=t)[1]['wallet']['premiumLifetime'] for t in tokens), 1)

    def test_existing_owner_migrates_once_without_reissuing_transferred_gifts(self):
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.a)[0], 200)
        self.relay = Relay(self.relay.path)
        gift = self.request('/v3/economy/inventory', token=self.a)[1]['artifacts'][0]
        self.assertEqual(self.request('/v3/economy/transfer', 'POST', {'requestID': str(uuid.uuid4()), 'artifactID': gift['id'], 'recipient': self.bob_card['id']}, self.a)[0], 200)
        self.relay = Relay(self.relay.path)
        self.login(self.alice, self.alice_card)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts').fetchone()[0], 5)
            self.assertEqual(db.execute('SELECT owner FROM artifacts WHERE id=?', (gift['id'],)).fetchone()[0], self.bob_card['id'])
            self.assertEqual(db.execute("SELECT count(*) FROM economy_ledger WHERE kind='founder_gift'").fetchone()[0], 5)
            self.assertEqual(db.execute("SELECT count(*) FROM economy_ledger WHERE kind='founder_premium'").fetchone()[0], 1)

    def test_paid_supply_starts_at_one_and_storekit_revocation_cannot_erase_founder_grant(self):
        self.arm_first_verified_login(); token = self.login(self.alice, self.alice_card)
        with self.relay.db() as db:
            db.execute("UPDATE artifact_collections SET published=1 WHERE id='nova'")
            commerce.change_balance(db, self.alice_card['id'], 500, 'fixture', 'credit', int(time.time()), APIError)
            commerce.apply_payment(db, self.alice_card['id'], {'transactionId': 'founder-apple-test', 'productId': commerce.PREMIUM_PRODUCT, 'revocationDate': 1}, int(time.time()), APIError)
        status, result = self.request('/v3/economy/buy', 'POST', {'requestID': str(uuid.uuid4()), 'collection': 'nova', 'expectedPrice': 500}, token)
        self.assertEqual(status, 200); self.assertEqual(result['artifact']['serial'], 1)
        self.assertTrue(result['wallet']['premiumLifetime']); self.assertTrue(result['wallet']['premium'])
        with self.relay.db() as db:
            self.assertEqual(db.execute("SELECT minted FROM artifact_collections WHERE id='nova'").fetchone()[0], 1)

    def test_gift_conflict_rolls_back_owner_and_entitlement_in_one_transaction(self):
        with self.relay.db() as db:
            db.execute('INSERT INTO artifacts(id,collection,serial,owner,price_paid,acquired,last_price) VALUES (?,?,0,?,0,1,0)', ('conflict', 'nova', self.bob_card['id']))
        with self.assertRaises(sqlite3.IntegrityError):
            with self.relay.db() as db:
                moderation.claim(db, self.alice_card['id'], 'vo1d', int(time.time()), APIError)
                commerce.grant_founder(db, self.alice_card['id'], int(time.time()))
        with self.relay.db() as db:
            self.assertIsNone(moderation.owner(db))
            self.assertEqual(db.execute('SELECT count(*) FROM economy_founder').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM artifacts').fetchone()[0], 1)


if __name__ == '__main__': unittest.main()
