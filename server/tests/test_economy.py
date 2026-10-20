import concurrent.futures
import json
import time
import unittest
import uuid
from unittest.mock import patch

import test_relay
from app import APIError, Relay
import commerce


class EconomyTests(unittest.TestCase):
    setUp = test_relay.RelayTests.setUp
    tearDown = test_relay.RelayTests.tearDown
    login = test_relay.RelayTests.login
    request = test_relay.RelayTests.request

    def post(self, route, body=None, token=None):
        return self.request('/v3/economy/' + route, 'POST', {'requestID': str(uuid.uuid4()), **(body or {})}, token or self.a)

    def credit(self, token_owner=None, coins=100000):
        with self.relay.db() as db:
            commerce.change_balance(db, token_owner or self.alice_card['id'], coins, 'test', 'fixture', int(time.time()), APIError)

    def publish(self, upgrades=True):
        self.assertEqual(self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.a)[0], 200)
        self.assertEqual(self.post('admin/publish', {'collection': 'nova', 'confirmed': True})[0], 200)
        if upgrades:
            self.assertEqual(self.post('admin/upgrades', {'collection': 'nova', 'confirmed': True})[0], 200)

    def buy(self):
        status, result = self.post('buy', {'collection': 'nova', 'expectedPrice': 500})
        self.assertEqual(status, 200, result)
        return result['artifact']

    def test_additive_install_keeps_users_chats_and_exact_draft_supplies(self):
        envelope = test_relay.RelayTests.envelope(self)
        self.request('/v1/envelopes', 'POST', envelope, self.a)
        self.relay = Relay(self.relay.path)
        self.assertEqual(len(self.request('/v1/inbox', token=self.b)[1]['envelopes']), 1)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['collections'], [])
        with self.relay.db() as db:
            self.assertEqual([r[0] for r in db.execute('SELECT supply FROM artifact_collections ORDER BY supply')], [2000, 5000, 10000, 35000, 55000])
            self.assertEqual(db.execute('SELECT count(*) FROM identities').fetchone()[0], 2)
        self.assertEqual(self.request('/v2/commerce', token=self.a)[0], 404)

    def test_admin_authority_confirmation_and_release_gate(self):
        self.assertEqual(self.post('admin/publish', {'collection': 'nova', 'confirmed': True}, self.b)[0], 403)
        self.request('/v1/username', 'POST', {'username': 'vo1d'}, self.a)
        self.assertEqual(self.post('admin/publish', {'collection': 'nova'})[0], 400)
        self.assertEqual(self.post('admin/upgrades', {'collection': 'nova', 'confirmed': True})[0], 409)
        self.credit()
        self.assertEqual(self.post('buy', {'collection': 'nova', 'expectedPrice': 500})[0], 404)
        self.publish(upgrades=False)
        gift = self.buy()
        self.assertIsNone(gift['traits'])
        self.assertEqual(self.post('upgrade', {'artifactID': gift['id'], 'expectedPrice': 100})[0], 409)

    def test_no_client_balance_or_price_or_serial_is_trusted(self):
        self.publish()
        self.assertEqual(self.post('buy', {'collection': 'nova', 'expectedPrice': 500, 'balance': 10000})[0], 409)
        self.credit(coins=1000)
        self.assertEqual(self.post('buy', {'collection': 'nova', 'expectedPrice': 0})[0], 409)
        result = self.post('buy', {'collection': 'nova', 'expectedPrice': 500, 'serial': 555, 'owner': self.bob_card['id']})[1]
        self.assertEqual(result['artifact']['serial'], 1)
        self.assertEqual(result['artifact']['owner'], self.alice_card['id'])
        self.assertEqual(result['wallet']['balance'], 500)

    def test_purchase_and_upgrade_retries_return_same_result_once(self):
        self.publish(); self.credit(coins=1000)
        payload = {'requestID': str(uuid.uuid4()), 'collection': 'nova', 'expectedPrice': 500}
        first = self.request('/v3/economy/buy', 'POST', payload, self.a)
        self.assertEqual(self.request('/v3/economy/buy', 'POST', payload, self.a), first)
        self.assertEqual(self.request('/v3/economy/buy', 'POST', dict(payload, requestID=payload['requestID'].upper()), self.a), first)
        gift = first[1]['artifact']
        upgrade = {'requestID': str(uuid.uuid4()), 'artifactID': gift['id'], 'expectedPrice': 100,
                   'traits': {'model': 'monochrome'}}
        with patch.object(commerce.secrets, 'randbelow', return_value=0):
            upgraded = self.request('/v3/economy/upgrade', 'POST', upgrade, self.a)
        self.assertEqual(upgraded[0], 200)
        self.assertEqual(self.request('/v3/economy/upgrade', 'POST', upgrade, self.a), upgraded)
        self.assertEqual(upgraded[1]['artifact']['traits']['model']['id'], 'original')
        self.assertEqual(self.post('upgrade', {'artifactID': gift['id'], 'expectedPrice': 100})[0], 409)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['balance'], 400)
        payload['collection'] = 'prism'
        self.assertEqual(self.request('/v3/economy/buy', 'POST', payload, self.a)[0], 409)

    def test_rolls_are_independent_and_every_category_sums_to_10000(self):
        for variants in commerce.TRAITS.values():
            self.assertEqual(sum(t[2] for t in variants), 10000)
        with patch.object(commerce.secrets, 'randbelow', side_effect=[9999, 0, 0]):
            mixed = commerce.roll()
            self.assertEqual(mixed['backdrop']['id'], 'obsidian')
            self.assertEqual(mixed['model']['id'], 'original')
        with patch.object(commerce.secrets, 'randbelow', side_effect=[0, 9999, 9999]):
            mixed = commerce.roll()
            self.assertEqual(mixed['backdrop']['id'], 'jade')
            self.assertEqual(mixed['model']['id'], 'monochrome')

    def test_concurrent_last_purchase_never_oversells_or_double_debits(self):
        self.publish(); self.credit(); self.credit(self.bob_card['id'])
        with self.relay.db() as db:
            db.execute("UPDATE artifact_collections SET minted=supply-1 WHERE id='nova'")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda token: self.post('buy', {'collection': 'nova', 'expectedPrice': 500}, token), [self.a, self.b]))
        self.assertEqual(sorted(r[0] for r in results), [200, 409])
        winner = next(r[1] for r in results if r[0] == 200)
        self.assertEqual(winner['artifact']['serial'], 55000)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT sum(balance) FROM economy_wallets').fetchone()[0], 199500)

    def test_transfer_visibility_and_ownership_cannot_be_forged(self):
        self.publish(); self.credit(); gift = self.buy()
        self.assertEqual(self.post('visibility', {'artifactID': gift['id'], 'visible': True}, self.b)[0], 404)
        self.assertEqual(self.request('/v3/economy/profile/' + self.alice_card['id'], token=self.b)[1]['artifacts'], [])
        self.post('visibility', {'artifactID': gift['id'], 'visible': True})
        self.assertEqual(len(self.request('/v3/economy/profile/' + self.alice_card['id'], token=self.b)[1]['artifacts']), 1)
        moved = self.post('transfer', {'artifactID': gift['id'], 'recipient': self.bob_card['id']})
        self.assertEqual(moved[0], 200)
        self.assertFalse(moved[1]['artifact']['visible'])
        self.assertEqual(moved[1]['artifact']['lastPricePaid'], 0)
        self.assertEqual(self.post('list', {'artifactID': gift['id'], 'price': 200})[0], 404)
        self.assertEqual(len(self.request('/v3/economy/inventory', token=self.b)[1]['artifacts']), 1)

    def test_market_settles_atomically_and_stale_listing_cannot_buy_new_owner(self):
        self.publish(); self.credit(); self.credit(self.bob_card['id']); gift = self.buy()
        sale = self.post('list', {'artifactID': gift['id'], 'price': 1000})[1]['artifact']
        self.assertEqual(self.post('transfer', {'artifactID': gift['id'], 'recipient': self.bob_card['id']})[0], 409)
        self.assertEqual(self.post('market/buy', {'listingID': sale['listingID'], 'expectedPrice': 1000})[0], 409)
        result = self.post('market/buy', {'listingID': sale['listingID'], 'expectedPrice': 1000}, self.b)
        self.assertEqual(result[0], 200)
        self.assertEqual(result[1]['wallet']['balance'], 99000)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['balance'], 100500)
        self.assertEqual(self.post('market/buy', {'listingID': sale['listingID'], 'expectedPrice': 1000})[0], 409)
        self.assertEqual(result[1]['artifact']['pricePaid'], 500)
        self.assertEqual(result[1]['artifact']['lastPricePaid'], 1000)

    def test_concurrent_market_buy_has_one_winner(self):
        self.publish(); self.credit(); self.credit(self.bob_card['id']); gift = self.buy()
        sale = self.post('list', {'artifactID': gift['id'], 'price': 100})[1]['artifact']
        def buy(_): return self.post('market/buy', {'listingID': sale['listingID'], 'expectedPrice': 100}, self.b)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(buy, range(2)))
        self.assertEqual(sorted(r[0] for r in results), [200, 409])
        self.assertEqual(self.request('/v3/economy/catalog', token=self.b)[1]['wallet']['balance'], 99900)

    def test_transcription_needs_active_server_entitlement(self):
        self.assertEqual(self.post('transcription-authorize')[0], 403)
        with self.relay.db() as db:
            db.execute('INSERT INTO economy_wallets(owner,premium_until) VALUES (?,?)', (self.alice_card['id'], int(time.time()) + 100))
        self.assertEqual(self.post('transcription-authorize')[0], 200)
        with self.relay.db() as db: db.execute('UPDATE economy_wallets SET premium_until=1')
        self.assertEqual(self.post('transcription-authorize')[0], 403)

    def test_apple_transaction_replay_does_not_mint_coins(self):
        payment = {'transactionId': '12345', 'productId': 'io.vo1d.coins.500'}
        with patch('storekit.verify_transaction', return_value=payment):
            self.assertEqual(self.post('payment', {'transactionID': '12345'})[1]['wallet']['balance'], 500)
            self.assertEqual(self.post('payment', {'transactionID': '12345'})[1]['wallet']['balance'], 500)
            self.assertEqual(self.post('payment', {'transactionID': '12345'}, self.b)[0], 409)
        self.assertEqual(self.post('payment', {'transactionID': 'not-an-apple-id', 'coins': 1000000})[0], 400)

    def test_subscription_replay_never_extends_expiry_and_revocation_removes_it(self):
        payment = {'transactionId': '23456', 'productId': commerce.PREMIUM_PRODUCT, 'expiresDate': (int(time.time()) + 300) * 1000}
        with patch('storekit.verify_transaction', return_value=payment):
            first = self.post('payment', {'transactionID': '23456'})
            again = self.post('payment', {'transactionID': '23456'})
            self.assertEqual(first[1]['wallet']['premiumUntil'], again[1]['wallet']['premiumUntil'])
            self.assertTrue(first[1]['wallet']['premium'])
            payment['revocationDate'] = int(time.time()) * 1000
            self.assertFalse(self.post('payment', {'transactionID': '23456'})[1]['wallet']['premium'])

    def test_refund_records_debt_and_cannot_be_replayed_to_restore_money(self):
        self.publish()
        payment = {'transactionId': '12345', 'productId': 'io.vo1d.coins.500'}
        with patch('storekit.verify_transaction', return_value=payment):
            self.post('payment', {'transactionID': '12345'})
            gift = self.buy()
            payment['revocationDate'] = int(time.time()) * 1000
            refunded = self.post('payment', {'transactionID': '12345'})[1]['wallet']
            self.assertEqual(refunded['balance'], 0)
            self.assertEqual(refunded['refundDebt'], 500)
            self.assertEqual(self.post('payment', {'transactionID': '12345'})[1]['wallet']['refundDebt'], 500)
            self.assertEqual(self.post('transfer', {'artifactID': gift['id'], 'recipient': self.bob_card['id']})[0], 409)
            payment = {'transactionId': '34567', 'productId': 'io.vo1d.coins.500'}
        with patch('storekit.verify_transaction', return_value=payment):
            settled = self.post('payment', {'transactionID': '34567'})[1]['wallet']
            self.assertEqual(settled['balance'], 0)
            self.assertEqual(settled['refundDebt'], 0)

    def test_notifications_verify_with_apple_and_handle_renewals_and_refunds(self):
        import base64
        def jws(value): return 'header.' + base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b'=').decode() + '.untrusted'
        original = {'transactionId': '12345', 'originalTransactionId': '12345', 'productId': commerce.PREMIUM_PRODUCT, 'expiresDate': (int(time.time()) + 300) * 1000}
        with patch('storekit.verify_transaction', return_value=original): self.post('payment', {'transactionID': '12345'})
        hint = {'transactionId': '12346', 'originalTransactionId': '12345', 'productId': 'forged', 'expiresDate': 9999999999999}
        notification = {'signedPayload': jws({'data': {'signedTransactionInfo': jws(hint)}})}
        renewal = dict(original, transactionId='12346', expiresDate=(int(time.time()) + 600) * 1000)
        with patch('storekit.verify_transaction', return_value=renewal) as verify:
            self.assertEqual(self.request('/v3/storekit/notifications', 'POST', notification)[0], 200)
            verify.assert_called_once_with('12346', commerce.account_token(self.alice_card['id']), APIError)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['premiumUntil'], renewal['expiresDate'] // 1000)
        revoked = dict(renewal, revocationDate=int(time.time()) * 1000)
        with patch('storekit.verify_transaction', return_value=revoked):
            self.assertEqual(self.request('/v3/storekit/notifications', 'POST', notification)[0], 200)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['premiumUntil'], original['expiresDate'] // 1000)

    def test_malformed_notification_objects_do_not_reach_payment_verification(self):
        import base64
        def jws(value): return 'header.' + base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b'=').decode() + '.untrusted'
        with patch('storekit.verify_transaction') as verify:
            for value in [[], 1, 'text', None]:
                outer = {'signedPayload': jws({'data': {'signedTransactionInfo': jws(value)}})}
                self.assertEqual(self.request('/v3/storekit/notifications', 'POST', outer)[0], 400)
            verify.assert_not_called()

    def test_failed_market_payment_rolls_back_seller_and_owner(self):
        self.publish(); self.credit(); gift = self.buy()
        sale = self.post('list', {'artifactID': gift['id'], 'price': 1000})[1]['artifact']
        self.assertEqual(self.post('market/buy', {'listingID': sale['listingID'], 'expectedPrice': 1000}, self.b)[0], 409)
        self.assertEqual(self.request('/v3/economy/catalog', token=self.a)[1]['wallet']['balance'], 99500)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT owner FROM artifacts WHERE id=?', (gift['id'],)).fetchone()[0], self.alice_card['id'])
            self.assertEqual(db.execute('SELECT count(*) FROM artifact_listings').fetchone()[0], 1)

    def test_deletion_retires_serials_without_touching_other_users(self):
        self.publish(); self.credit(); gift = self.buy()
        self.assertEqual(self.request('/v1/account', 'DELETE', token=self.a)[0], 200)
        with self.relay.db() as db:
            self.assertIsNone(db.execute('SELECT owner FROM artifacts WHERE id=?', (gift['id'],)).fetchone()[0])
            self.assertEqual(db.execute("SELECT minted FROM artifact_collections WHERE id='nova'").fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT id FROM identities').fetchone()[0], self.bob_card['id'])


if __name__ == '__main__': unittest.main()
