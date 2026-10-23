import base64
import json
import os
import time
import unittest
from unittest.mock import patch

import test_relay
from app import APIError
import httpx
import storekit
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


class StoreKitVerificationTests(unittest.TestCase):
    def setUp(self):
        private = ec.generate_private_key(ec.SECP256R1())
        self.settings = {'VO1D_APPLE_ISSUER_ID': 'issuer', 'VO1D_APPLE_KEY_ID': 'key',
                         'VO1D_APPLE_PRIVATE_KEY': private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode(),
                         'VO1D_APPLE_BUNDLE_ID': 'io.vo1d.messenger', 'VO1D_APPLE_ENVIRONMENT': 'Production'}
        self.payment = {'transactionId': '12345', 'bundleId': 'io.vo1d.messenger', 'environment': 'Production',
                        'appAccountToken': 'expected-account', 'inAppOwnershipType': 'PURCHASED', 'quantity': 1,
                        'purchaseDate': int(time.time()) * 1000, 'productId': 'io.vo1d.coins.500'}

    def verify(self, payment):
        encoded = 'header.' + base64.urlsafe_b64encode(json.dumps(payment).encode()).rstrip(b'=').decode() + '.signature'
        with patch.dict(os.environ, self.settings, clear=True), patch('storekit.httpx.Client') as client:
            client.return_value.__enter__.return_value.get.return_value = httpx.Response(200, json={'signedTransactionInfo': encoded})
            result = storekit.verify_transaction('12345', 'expected-account', APIError)
            client.assert_called_once_with(timeout=12, follow_redirects=False, trust_env=False)
            self.assertEqual(client.return_value.__enter__.return_value.get.call_args.args[0], 'https://api.storekit.apple.com/inApps/v1/transactions/12345')
            return result

    def test_payment_readiness_rejects_absent_partial_invalid_and_wrong_curve_keys(self):
        for overrides in [{}, {'VO1D_APPLE_ISSUER_ID': ' '}, {'VO1D_APPLE_KEY_ID': ''},
                          {'VO1D_APPLE_PRIVATE_KEY': 'not-a-key'}, {'VO1D_APPLE_ENVIRONMENT': 'Xcode'},
                          {'VO1D_APPLE_BUNDLE_ID': ''}]:
            settings = dict(self.settings, **overrides) if overrides else {}
            with self.subTest(overrides=list(overrides)), patch.dict(os.environ, settings, clear=True):
                self.assertFalse(storekit.payments_configured())
        other = ec.generate_private_key(ec.SECP384R1()).private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
        with patch.dict(os.environ, dict(self.settings, VO1D_APPLE_PRIVATE_KEY=other), clear=True):
            self.assertFalse(storekit.payments_configured())
        for environment in ['Production', 'Sandbox']:
            with patch.dict(os.environ, dict(self.settings, VO1D_APPLE_ENVIRONMENT=environment), clear=True), patch('storekit.httpx.Client') as client:
                self.assertTrue(storekit.payments_configured())
                client.assert_not_called()

    def test_bundle_whitespace_is_normalized_only_in_server_configuration(self):
        self.settings['VO1D_APPLE_BUNDLE_ID'] = '  io.vo1d.messenger\n'
        with patch.dict(os.environ, self.settings, clear=True):
            self.assertTrue(storekit.payments_configured())
            token = storekit.api_token(APIError)
            encoded = token.split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
            self.assertEqual(claims['bid'], 'io.vo1d.messenger')
        self.assertEqual(self.verify(self.payment), self.payment)
        for bundle in ['other.app', ' io.vo1d.messenger ', 'io.vo1d.messenger.attacker']:
            with self.subTest(bundle=bundle), self.assertRaises(APIError) as caught:
                self.verify(dict(self.payment, bundleId=bundle))
            self.assertEqual(caught.exception.status, 403)

    def test_uses_only_fixed_apple_host_and_live_server_response(self):
        self.assertEqual(self.verify(self.payment), self.payment)

    def test_rejects_cross_account_bundle_environment_id_and_family_sharing(self):
        for key, value in [('appAccountToken', 'other'), ('bundleId', 'other.app'), ('environment', 'Sandbox'),
                           ('transactionId', '67890'), ('inAppOwnershipType', 'FAMILY_SHARED'), ('quantity', 2),
                           ('purchaseDate', int(time.time() + 3600) * 1000)]:
            with self.subTest(key=key), self.assertRaises(APIError) as caught:
                self.verify(dict(self.payment, **{key: value}))
            self.assertEqual(caught.exception.status, 403)

    def test_missing_credentials_and_fake_transaction_fail_closed(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(APIError) as caught:
            storekit.verify_transaction('12345', 'expected', APIError)
        self.assertEqual(caught.exception.status, 503)
        for value in ['https://attacker.test', '../12345', 12345, '', '1?redirect=x']:
            with self.subTest(value=value), self.assertRaises(APIError) as caught:
                storekit.verify_transaction(value, 'expected', APIError)
            self.assertEqual(caught.exception.status, 400)


if __name__ == '__main__': unittest.main()
