import base64
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

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

    async def login(self, full=False):
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
        return (private, card, session["token"]) if full else session["token"]

    async def test_range_resume_and_foreign_owner_delete(self):
        token = await self.login()
        other = await self.login()
        ciphertext = os.urandom(4096)
        response = await self.client.put('/v1/blob', data=ciphertext,
            headers={'Authorization':'Bearer '+token,'Content-Type':'application/octet-stream'})
        receipt = await response.json()
        path = '/v1/blob/'+receipt['id']
        response = await self.client.get(path, headers={'Authorization':'Bearer '+other,'Range':'bytes=1024-'})
        self.assertEqual(response.status,206)
        self.assertEqual(response.headers['Content-Range'],'bytes 1024-4095/4096')
        self.assertEqual(await response.read(),ciphertext[1024:])
        response = await self.client.delete(path,headers={'Authorization':'Bearer '+other})
        self.assertEqual(response.status,403)
        response = await self.client.get(path,headers={'Authorization':'Bearer '+token,'Range':'bytes=5000-'})
        self.assertEqual(response.status,416)

    async def test_call_routes_signed_offers_and_rejects_third_identity(self):
        ap, ac, at = await self.login(full=True)
        bp, bc, bt = await self.login(full=True)
        _, cc, ct = await self.login(full=True)
        a = await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+at})
        b = await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+bt})
        c = await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+ct})
        for ws in (a,b,c):
            self.assertEqual((await ws.receive_json(timeout=2))['type'],'ready')
        call = str(uuid.uuid4())
        key = encode(os.urandom(32))
        signed = f"VO1D-CALL-KEY-2\n{call}\n{ac['id']}\n{bc['id']}\n{key}".encode()
        offer = {'type':'invite','to':bc['id'],'callID':call,'key':key,'keySignature':encode(ap.sign(signed))}
        await a.send_json(offer)
        received = await b.receive_json(timeout=2)
        self.assertEqual(received['from'],ac['id'])
        self.assertEqual(received['keySignature'],offer['keySignature'])
        answer_key = encode(os.urandom(32))
        answer_signature = encode(bp.sign(f"VO1D-CALL-KEY-2\n{call}\n{bc['id']}\n{ac['id']}\n{answer_key}".encode()))
        await b.send_json({'type':'answer','to':ac['id'],'callID':call,'key':answer_key,'keySignature':answer_signature})
        self.assertEqual((await a.receive_json(timeout=2))['key'],answer_key)
        payload = encode(os.urandom(64))
        await c.send_json({'type':'audio','to':bc['id'],'callID':call,'sequence':'1','payload':payload})
        self.assertEqual((await c.receive_json(timeout=2))['code'],'call_mismatch')
        await a.send_json({'type':'audio','to':bc['id'],'callID':call,'sequence':'1','payload':payload})
        frame = await b.receive_json(timeout=2)
        self.assertEqual(frame['payload'],payload)
        self.assertEqual(frame['sequence'],'1')
        self.assertEqual(frame['from'],ac['id'])
        await a.send_json({'type':'end','to':bc['id'],'callID':call})
        self.assertEqual((await b.receive_json(timeout=2))['type'],'end')
        for ws in (a,b,c):
            await ws.close()

    async def test_untrusted_call_and_missing_key_are_rejected(self):
        _, ac, at = await self.login(full=True)
        _, bc, bt = await self.login(full=True)
        response = await self.client.post('/v1/privacy',json={'discoverable':True,'inactivityDays':0,'trustedCalls':True},
            headers={'Authorization':'Bearer '+bt})
        self.assertEqual(response.status,200)
        a = await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+at})
        await a.receive_json(timeout=2)
        packet = {'type':'invite','to':bc['id'],'callID':str(uuid.uuid4())}
        await a.send_json(packet)
        self.assertEqual((await a.receive_json(timeout=2))['code'],'invalid_call_key')
        packet.update(key=encode(os.urandom(32)),keySignature=encode(os.urandom(64)))
        await a.send_json(packet)
        self.assertEqual((await a.receive_json(timeout=2))['code'],'peer_unavailable')
        await a.close()

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
