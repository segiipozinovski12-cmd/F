import base64
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest

from aiohttp.test_utils import TestClient, TestServer
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import card_bytes
from realtime import create_app


def encode(data):
    return base64.b64encode(data).decode()


def identity():
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    agreement = X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    card = {
        "id": hashlib.sha256(public).hexdigest(),
        "signingKey": encode(public),
        "agreementKey": encode(agreement),
    }
    card["binding"] = encode(private.sign(card_bytes(card)))
    return private, card


class RealtimeBlobTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        os.environ["VO1D_DB"] = str(Path(self.temp.name) / "relay.sqlite3")
        os.environ["VO1D_BLOB_DIR"] = str(Path(self.temp.name) / "blobs")
        self.client = TestClient(TestServer(create_app()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        os.environ.pop("VO1D_DB", None)
        os.environ.pop("VO1D_BLOB_DIR", None)
        self.temp.cleanup()

    async def login(self):
        private, card = identity()
        response = await self.client.post("/v1/register", json=card)
        self.assertEqual(response.status, 200)

        response = await self.client.post("/v1/challenge", json={"id": card["id"]})
        self.assertEqual(response.status, 200)
        challenge = await response.json()

        auth = f"VO1D-AUTH-1\n{card['id']}\n{challenge['nonce']}".encode()
        response = await self.client.post(
            "/v1/session",
            json={
                "id": card["id"],
                "nonce": challenge["nonce"],
                "signature": encode(private.sign(auth)),
            },
        )
        self.assertEqual(response.status, 200)
        session = await response.json()
        return session["token"]

    async def test_blob_roundtrip_and_owner_delete(self):
        token = await self.login()
        headers = {
            "Authorization": "Bearer " + token,
            "Content-Type": "application/octet-stream",
        }
        ciphertext = os.urandom(64 * 1024)

        response = await self.client.put("/v1/blob", data=ciphertext, headers=headers)
        self.assertEqual(response.status, 200)
        receipt = await response.json()
        self.assertEqual(receipt["size"], len(ciphertext))
        self.assertEqual(receipt["digest"], hashlib.sha256(ciphertext).hexdigest())

        blob_id = receipt["id"]
        response = await self.client.get(
            "/v1/blob/" + blob_id,
            headers={"Authorization": "Bearer " + token},
        )
        self.assertEqual(response.status, 200)
        downloaded = await response.read()
        self.assertEqual(downloaded, ciphertext)
        self.assertEqual(
            response.headers.get("X-VO1D-Blob-Digest"),
            hashlib.sha256(ciphertext).hexdigest(),
        )

        response = await self.client.delete(
            "/v1/blob/" + blob_id,
            headers={"Authorization": "Bearer " + token},
        )
        self.assertEqual(response.status, 200)

        response = await self.client.get(
            "/v1/blob/" + blob_id,
            headers={"Authorization": "Bearer " + token},
        )
        self.assertEqual(response.status, 404)

    async def test_blob_requires_session(self):
        response = await self.client.put(
            "/v1/blob",
            data=os.urandom(64),
            headers={"Content-Type": "application/octet-stream"},
        )
        self.assertEqual(response.status, 401)


if __name__ == "__main__":
    unittest.main()
