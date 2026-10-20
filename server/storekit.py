"""App Store Server API: only Apple's live HTTPS response can credit a wallet.

The client sends a transaction ID, never a price or a trusted receipt. JWTs are
short lived; credentials stay on the server. Xcode/local transactions fail closed.
"""
import base64
import json
import os
import re
import time

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def api_token(error):
    issuer, key_id, key = (os.environ.get(k, '') for k in
                           ('VO1D_APPLE_ISSUER_ID', 'VO1D_APPLE_KEY_ID', 'VO1D_APPLE_PRIVATE_KEY'))
    bundle = os.environ.get('VO1D_APPLE_BUNDLE_ID', 'io.vo1d.messenger')
    if not all((issuer, key_id, key)):
        raise error(503, 'Покупки ещё не настроены администратором')
    now = int(time.time())
    header = b64url(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    claims = b64url(json.dumps({'iss': issuer, 'iat': now, 'exp': now + 120,
                                'aud': 'appstoreconnect-v1', 'bid': bundle}).encode())
    try:
        private = serialization.load_pem_private_key(key.replace('\\n', '\n').encode(), password=None)
        if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP256R1):
            raise ValueError()
        r, s = decode_dss_signature(private.sign((header + '.' + claims).encode(), ec.ECDSA(hashes.SHA256())))
    except (ValueError, TypeError):
        raise error(503, 'Проверка App Store временно недоступна')
    return header + '.' + claims + '.' + b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))


def verify_transaction(identifier, expected_account, error):
    if not isinstance(identifier, str) or not re.fullmatch(r'[0-9]{1,30}', identifier):
        raise error(400, 'Некорректный номер покупки App Store')
    token = api_token(error)
    environment = os.environ.get('VO1D_APPLE_ENVIRONMENT', 'Production')
    if environment not in ('Production', 'Sandbox'):
        raise error(503, 'Некорректная настройка App Store')
    host = 'api.storekit.apple.com' if environment == 'Production' else 'api.storekit-sandbox.apple.com'
    try:
        # Fixed Apple host, TLS verification on, no redirects or proxy inheritance.
        with httpx.Client(timeout=12, follow_redirects=False, trust_env=False) as client:
            response = client.get(f'https://{host}/inApps/v1/transactions/{identifier}',
                                  headers={'Authorization': 'Bearer ' + token})
        if response.status_code == 404:
            raise error(400, 'Покупка не найдена в App Store')
        if response.status_code != 200 or len(response.content) > 64000:
            raise error(503, 'App Store временно не подтвердил покупку')
        # signedTransactionInfo is fetched directly from authenticated Apple API,
        # never taken from a client-provided JWS or an untrusted certificate chain.
        encoded = response.json()['signedTransactionInfo'].split('.')
        if len(encoded) != 3:
            raise ValueError()
        payment = json.loads(base64.urlsafe_b64decode(encoded[1] + '=' * (-len(encoded[1]) % 4)))
        if (payment.get('transactionId') != identifier or
                payment.get('bundleId') != os.environ.get('VO1D_APPLE_BUNDLE_ID', 'io.vo1d.messenger') or
                payment.get('environment') != environment or
                str(payment.get('appAccountToken', '')).lower() != expected_account.lower() or
                payment.get('inAppOwnershipType') != 'PURCHASED' or
                payment.get('quantity', 1) != 1 or
                not isinstance(payment.get('purchaseDate'), int) or
                payment['purchaseDate'] > (time.time() + 60) * 1000):
            raise error(403, 'Покупка не принадлежит этой личности VO1D')
        return payment
    except (httpx.HTTPError, ValueError, KeyError, TypeError, AttributeError):
        raise error(503, 'Не удалось проверить покупку в App Store. Повтори позже.')
