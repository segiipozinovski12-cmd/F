import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import threading
import unittest
from wsgiref.simple_server import make_server, WSGIRequestHandler
import test_moderation
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[2]
NODE = os.environ.get('VO1D_NODE_BIN') or shutil.which('node')


class QuietHandler(WSGIRequestHandler):
    def log_message(self, *args): pass


@unittest.skipUnless(NODE and (ROOT/'bot-worker/node_modules/@signalapp/libsignal-client').exists(), 'Install pinned bot-worker dependencies and Node for HTTP integration')
class ExternalWorkerTests(unittest.TestCase):
    setUp = test_moderation.ModerationTests.setUp
    tearDown = test_moderation.ModerationTests.tearDown
    request = test_moderation.ModerationTests.request
    login = test_moderation.ModerationTests.login

    def node(self, *args):
        result = subprocess.run([NODE, str(ROOT/'bot-worker/test/integration-driver.mjs'), *map(str,args)], cwd=ROOT, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        return result.stdout.strip()

    def test_real_http_official_sdk_worker_reply_ack_restart_and_dedup(self):
        with make_server('127.0.0.1', 0, self.relay, handler_class=QuietHandler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                fixture = json.loads(self.node('init', self.alice_card['id'], f'http://127.0.0.1:{server.server_port}'))
                self.assertEqual(self.request('/v2/bots','POST',fixture['creation'],self.a)[0],200)
                payload = fixture['payload']; self.assertEqual(self.request('/v2/bots/'+payload['bot']['card']['id']+'/executor','POST',{'executor':payload['executorID'],'mode':'external'},self.a)[0],200)
                private = Ed25519PrivateKey.from_private_bytes(base64.b64decode(fixture['alice']['signing']))
                alice_token = self.login(private,fixture['aliceCard'])
                self.assertEqual(self.request('/v1/envelopes','POST',fixture['envelope'],alice_token)[0],200)
                source = Path(self.temp.name)/'payload.json'; vault = Path(self.temp.name)/'bot.vo1dbot'; source.write_text(json.dumps(payload))
                self.node('save',source,vault); instance = secrets.token_urlsafe(32)
                self.assertEqual(json.loads(self.node('tick',vault,instance)),{'processed':1,'pending':0})
                replies = self.request('/v1/inbox',token=alice_token)[1]['envelopes']; self.assertEqual(len(replies),1)
                source.write_text(json.dumps(dict(reply=replies[0],alice=fixture['alice'],aliceState=fixture['aliceState'],botCard=payload['bot']['card'])))
                self.assertEqual(self.node('verify',source),'Real HTTP bot reply decrypted')
                # Re-open encrypted state in a separate process. Lost responses
                # and repeated server submission do not create another reply.
                self.assertEqual(self.request('/v1/envelopes','POST',fixture['envelope'],alice_token)[0],200)
                self.assertEqual(json.loads(self.node('tick',vault,instance)),{'processed':1,'pending':0})
                self.assertEqual(len(self.request('/v1/inbox',token=alice_token)[1]['envelopes']),1)
            finally:
                server.shutdown(); thread.join(timeout=3)
