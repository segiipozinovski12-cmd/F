import asyncio
import os
import sqlite3
import unittest
import uuid
from contextlib import closing
from aiohttp import WSMsgType
import test_realtime


class NextRealtimeTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_realtime.RealtimeBlobTests.asyncSetUp
    asyncTearDown = test_realtime.RealtimeBlobTests.asyncTearDown
    login = test_realtime.RealtimeBlobTests.login

    async def test_revoked_account_session_cannot_keep_sending_on_existing_socket(self):
        _, _, token = await self.login(full=True)
        _, peer, _ = await self.login(full=True)
        socket = await self.client.ws_connect('/v1/call/socket', headers={'Authorization': 'Bearer ' + token})
        await socket.receive_json(timeout=2)
        with closing(sqlite3.connect(os.environ['VO1D_DB'])) as db:
            db.execute('DELETE FROM sessions'); db.commit()
        await asyncio.sleep(5.1)
        await socket.send_json({'type': 'end', 'to': peer['id'], 'callID': str(uuid.uuid4())})
        result = await socket.receive(timeout=2)
        self.assertIn(result.type, (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING))
        await socket.close()


if __name__ == '__main__': unittest.main()
