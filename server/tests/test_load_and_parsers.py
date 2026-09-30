import asyncio
import base64
import json
import os
import random
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
import test_mailboxes
import test_realtime


class MailboxLoadTests(unittest.TestCase):
    setUp = test_mailboxes.MailboxTests.setUp
    tearDown = test_mailboxes.MailboxTests.tearDown
    request = test_mailboxes.MailboxTests.request
    login = test_mailboxes.MailboxTests.login
    mailbox = test_mailboxes.MailboxTests.mailbox
    call = test_mailboxes.MailboxTests.call
    envelope = test_mailboxes.MailboxTests.envelope

    def test_concurrent_queue_batch_ack_and_no_message_loss(self):
        box=self.mailbox()
        messages=[self.envelope(box) for _ in range(100)]
        with ThreadPoolExecutor(max_workers=12) as pool:
            statuses=list(pool.map(lambda e:self.call(box,'envelopes','POST',e,'write')[0],messages))
        self.assertEqual(statuses,[200]*100)
        received=[]
        while len(received)<100:
            status,result=self.call(box,'inbox'); self.assertEqual(status,200)
            batch=result['envelopes']; self.assertGreater(len(batch),0); self.assertLessEqual(len(batch),24)
            received.extend(e['id'] for e in batch)
            self.assertEqual(self.call(box,'ack','POST',{'ids':[e['id'] for e in batch]})[0],200)
        self.assertEqual(set(received),{e['id'] for e in messages})
        self.assertEqual(len(received),len(set(received)))


class GatewayParserTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_realtime.RealtimeBlobTests.asyncSetUp
    asyncTearDown = test_realtime.RealtimeBlobTests.asyncTearDown
    login = test_realtime.RealtimeBlobTests.login

    async def test_invalid_json_shapes_and_depth_never_return_server_error(self):
        bodies=[b'{',b'[1,2]',b'null',b'"text"',b'false',b'{"size":NaN}',b'{"size":Infinity}',b'{"size":-Infinity}',b'{"id":"\\ud800"}',b'['*1500+b'0'+b']'*1500]
        rng=random.Random(6042)
        bodies += [bytes(rng.randrange(256) for _ in range(rng.randrange(1,120))) for _ in range(100)]
        for data in bodies:
            response=await self.client.post('/v2/blobs/ticket',data=data,headers={'Content-Type':'application/json'})
            self.assertLess(response.status,500)

    async def test_websocket_bad_frames_cannot_crash_connection(self):
        token=await self.login()
        ws=await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+token})
        await ws.receive_json(timeout=2)
        for packet in ('{','[]','null','42','{"type":{}}','['*1500+'0'+']'*1500):
            await ws.send_str(packet)
            result=await ws.receive_json(timeout=2)
            self.assertEqual(result['type'],'error')
        await ws.close()

    async def test_call_resumes_same_route_and_rejects_third_identity(self):
        a_private,a_card,a_token=await self.login(full=True)
        b_private,b_card,b_token=await self.login(full=True)
        _,c_card,c_token=await self.login(full=True)
        a=await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+a_token})
        b=await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+b_token})
        await a.receive_json(timeout=2); await b.receive_json(timeout=2)
        call=str(uuid.uuid4())
        def offer(kind, private, card, target):
            key=base64.b64encode(os.urandom(32)).decode()
            signature=base64.b64encode(private.sign(f"VO1D-CALL-KEY-2\n{call}\n{card['id']}\n{target}\n{key}".encode())).decode()
            return dict(type=kind,to=target,callID=call,key=key,keySignature=signature)
        await a.send_json(offer('invite',a_private,a_card,b_card['id'])); await b.receive_json(timeout=2)
        await b.send_json(offer('answer',b_private,b_card,a_card['id'])); await a.receive_json(timeout=2)
        await a.close(); self.assertEqual((await b.receive_json(timeout=2))['type'],'paused')
        c=await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+c_token}); await c.receive_json(timeout=2)
        resume=dict(type='resume',to=b_card['id'],callID=call,payload=base64.b64encode(os.urandom(48)).decode(),sequence='20')
        await c.send_json(resume); self.assertEqual((await c.receive_json(timeout=2))['code'],'call_mismatch')
        a=await self.client.ws_connect('/v1/call/socket',headers={'Authorization':'Bearer '+a_token}); await a.receive_json(timeout=2)
        await a.send_json(resume); self.assertEqual((await b.receive_json(timeout=2))['type'],'resume')
        await b.send_json(dict(resume,type='resumed',to=a_card['id'],sequence='21')); self.assertEqual((await a.receive_json(timeout=2))['type'],'resumed')
        await a.send_json(dict(type='end',to=b_card['id'],callID=call)); self.assertEqual((await b.receive_json(timeout=2))['type'],'end')
        for ws in (a,b,c): await ws.close()
