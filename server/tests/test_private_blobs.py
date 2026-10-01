import asyncio
import hashlib
import os
import secrets
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import APIError
from private_blobs import ticket
from realtime import RealtimeGateway
import test_realtime


class PrivateBlobTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_realtime.RealtimeBlobTests.asyncSetUp
    asyncTearDown = test_realtime.RealtimeBlobTests.asyncTearDown
    login = test_realtime.RealtimeBlobTests.login

    async def reservation(self, payload):
        body = {k:secrets.token_urlsafe(32) for k in ('id','uploadToken','readToken','deleteToken')}
        body.update(size=len(payload),digest=hashlib.sha256(payload).hexdigest(),expiresAt=int(time.time())+3600)
        prefix = f"VO1D-BLOB-WORK-2\n{body['id']}\n{body['size']}\n{body['digest']}\n{body['expiresAt']}\n".encode()
        def work():
            nonce=0
            while int.from_bytes(hashlib.sha256(prefix+str(nonce).encode()).digest(),'big') >> 238:
                nonce+=1
            return str(nonce)
        body['proof']=await asyncio.to_thread(work)
        return body

    async def upload(self, body, payload):
        return await self.client.put('/v2/blobs/'+body['id'],data=payload,headers={'Authorization':'BlobCapability '+body['uploadToken'],'Content-Type':'application/octet-stream'})

    async def test_independent_capabilities_and_range_without_account(self):
        payload=os.urandom(4096); body=await self.reservation(payload)
        response=await self.client.post('/v2/blobs/ticket',json=body); self.assertEqual(response.status,200)
        self.assertEqual((await self.upload(body,payload)).status,200)
        path='/v2/blobs/'+body['id']
        for token in (body['uploadToken'],body['deleteToken']):
            response=await self.client.get(path,headers={'Authorization':'BlobCapability '+token}); self.assertEqual(response.status,403)
        response=await self.client.get(path,headers={'Authorization':'BlobCapability '+body['readToken'],'Range':'bytes=1024-'})
        self.assertEqual(response.status,206); self.assertEqual(await response.read(),payload[1024:])
        response=await self.client.delete(path,headers={'Authorization':'BlobCapability '+body['readToken']}); self.assertEqual(response.status,403)
        response=await self.client.delete(path,headers={'Authorization':'BlobCapability '+body['deleteToken']}); self.assertEqual(response.status,200)
        response=await self.client.delete(path,headers={'Authorization':'BlobCapability '+body['deleteToken']}); self.assertEqual(response.status,200)
        response=await self.client.get(path,headers={'Authorization':'BlobCapability '+body['readToken']}); self.assertEqual(response.status,403)
        response=await self.client.post('/v2/blobs/ticket',json=body); self.assertEqual(response.status,409)
        import sqlite3
        with sqlite3.connect(os.environ['VO1D_DB']) as db:
            columns={r[1] for r in db.execute('PRAGMA table_info(private_blobs)')}
            self.assertTrue(columns.isdisjoint({'owner','sender','identity','readToken','deleteToken','uploadToken'}))

    async def test_wrong_digest_then_exact_retry_and_mutated_reservation(self):
        data=os.urandom(2048); body=await self.reservation(data)
        self.assertEqual((await self.client.post('/v2/blobs/ticket',json=body)).status,200)
        self.assertEqual((await self.upload(body,os.urandom(len(data)))).status,400)
        self.assertEqual((await self.upload(body,data)).status,200)
        self.assertEqual((await self.upload(body,data)).status,200)
        changed=dict(body,readToken=secrets.token_urlsafe(32))
        self.assertEqual((await self.client.post('/v2/blobs/ticket',json=changed)).status,409)

    async def test_delete_during_write_cannot_resurrect_blob(self):
        data=os.urandom(4096); body=await self.reservation(data)
        await self.client.post('/v2/blobs/ticket',json=body)
        started, release=threading.Event(),threading.Event()
        original=RealtimeGateway._prepare_blob
        def blocked(path,payload):
            started.set(); release.wait(3); return original(path,payload)
        with patch.object(RealtimeGateway,'_prepare_blob',staticmethod(blocked)):
            transfer=asyncio.create_task(self.upload(body,data))
            for _ in range(200):
                if started.is_set(): break
                await asyncio.sleep(.005)
            self.assertTrue(started.is_set())
            try:
                response=await self.client.delete('/v2/blobs/'+body['id'],headers={'Authorization':'BlobCapability '+body['deleteToken']})
                self.assertEqual(response.status,200)
            finally:
                release.set()
            self.assertEqual((await transfer).status,410)
        self.assertFalse((Path(os.environ['VO1D_BLOB_DIR'])/body['id']).exists())
        self.assertFalse(list(Path(os.environ['VO1D_BLOB_DIR']).glob('*.tmp-*')))

    async def test_quota_reservation_includes_unfinished_uploads(self):
        first=await self.reservation(os.urandom(30*1024*1024))
        second=await self.reservation(os.urandom(30*1024*1024))
        with patch.dict(os.environ,{'VO1D_PRIVATE_BLOB_QUOTA':str(51*1024*1024)}):
            self.assertEqual((await self.client.post('/v2/blobs/ticket',json=first)).status,200)
            self.assertEqual((await self.client.post('/v2/blobs/ticket',json=second)).status,429)

    async def test_invalid_range_and_fresh_orphan_grace(self):
        data=os.urandom(512); body=await self.reservation(data)
        await self.client.post('/v2/blobs/ticket',json=body); await self.upload(body,data)
        path='/v2/blobs/'+body['id']; headers={'Authorization':'BlobCapability '+body['readToken']}
        for raw in ('bytes=9-8','bytes=999-','bytes=-0','bytes=0-1,4-5','garbage'):
            response=await self.client.get(path,headers=dict(headers,Range=raw)); self.assertEqual(response.status,416)
        response=await self.client.get(path,headers=dict(headers,Range='bytes=-10'))
        self.assertEqual(await response.read(),data[-10:])
        orphan=Path(os.environ['VO1D_BLOB_DIR'])/secrets.token_urlsafe(32); orphan.write_bytes(b'new')
        gateway=RealtimeGateway(); gateway._cleanup_blobs(include_orphans=True)
        self.assertTrue(orphan.exists())
        os.utime(orphan,(time.time()-7200,time.time()-7200)); gateway._cleanup_blobs(include_orphans=True)
        self.assertFalse(orphan.exists())
