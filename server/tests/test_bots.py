import hashlib
import io
import json
import secrets
import unittest
import test_relay
from app import header_bytes
import bots
import test_moderation


class BotTests(unittest.TestCase):
    setUp = test_moderation.ModerationTests.setUp
    tearDown = test_moderation.ModerationTests.tearDown
    request = test_relay.RelayTests.request
    login = test_relay.RelayTests.login

    def create_body(self):
        private, card = test_relay.identity()
        token = secrets.token_urlsafe(32)
        body = dict(card=card, name='Example Bot', username='example_bot', token=token)
        digest = hashlib.sha256(token.encode()).hexdigest()
        body['ownershipSignature'] = test_relay.encode(private.sign(bots.creation_bytes(self.alice_card['id'], card, body['username'], body['name'], digest)))
        return private, body

    def worker(self, token, path, method='GET', body=None):
        raw = json.dumps(body).encode() if body is not None else b''
        env = dict(REQUEST_METHOD=method, PATH_INFO=path, CONTENT_LENGTH=str(len(raw)), CONTENT_TYPE='application/json', REMOTE_ADDR='127.0.0.1')
        env['wsgi.input'] = io.BytesIO(raw)
        env['HTTP_AUTHORIZATION'] = 'BotCapability ' + token
        status = []
        def start(value, headers): status.append(int(value.split()[0]))
        output = b''.join(self.relay(env, start))
        return status[0], json.loads(output)

    def test_create_bot_and_lookup_with_independent_keys(self):
        _, body = self.create_body()
        status, result = self.request('/v2/bots', 'POST', body, self.a)
        self.assertEqual(status, 200)
        self.assertNotEqual(result['bot']['id'], self.alice_card['id'])
        lookup = self.request('/v1/username/example_bot', token=self.b)[1]['card']
        self.assertEqual(lookup['id'], body['card']['id'])
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.a)[0], 200)
        self.assertNotIn('token', str(self.request('/v2/bots', token=self.a)[1]))
        with self.relay.db() as db:
            self.assertNotIn(body['token'], str(dict(db.execute('SELECT * FROM bots').fetchone())))

    def test_bad_ownership_proof_and_owner_substitution(self):
        _, body = self.create_body()
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.b)[0], 403)
        body['ownershipSignature'] = test_relay.encode(bytes(64))
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.a)[0], 403)
        body['name'] = []
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.a)[0], 400)

    def test_bot_father_reserved_and_username_collision(self):
        self.assertFalse(self.request('/v1/username/check/vo1d_bot_father', token=self.a)[1]['valid'])
        _, body = self.create_body()
        self.request('/v1/username', 'POST', {'username': body['username']}, self.b)
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.a)[0], 409)

    def test_token_is_scoped_to_own_ciphertext_mailbox(self):
        private, body = self.create_body()
        self.assertEqual(self.request('/v2/bots', 'POST', body, self.a)[0], 200)
        token = body['token']
        self.assertEqual(self.worker(token, '/v1/inbox'), (200, {'envelopes': []}))
        for path, method, value in [('/v2/moderation/queue','GET',None),('/v2/bots','GET',None),('/v1/account','DELETE',None),('/v1/username','POST',{'username':'hijack'})]:
            self.assertEqual(self.worker(token, path, method, value)[0], 403)
        e = test_relay.RelayTests.envelope(self, sender=body['card']['id'], recipient=self.bob_card['id'], private=private)
        self.assertEqual(self.worker(token, '/v1/envelopes', 'POST', e)[0], 200)
        self.assertEqual(self.request('/v1/inbox', token=self.b)[1]['envelopes'][0]['id'], e['id'])
        e['sender'] = self.alice_card['id']
        self.assertEqual(self.worker(token, '/v1/envelopes', 'POST', e)[0], 400)

    def test_token_rotation_disable_owner_access_and_deletion(self):
        _, body = self.create_body(); self.request('/v2/bots', 'POST', body, self.a)
        path = '/v2/bots/' + body['card']['id']
        new = secrets.token_urlsafe(32)
        self.assertEqual(self.request(path + '/token', 'POST', {'token': new}, self.b)[0], 404)
        self.assertEqual(self.request(path + '/token', 'POST', {'token': new}, self.a)[0], 200)
        self.assertEqual(self.worker(body['token'], '/v1/inbox')[0], 401)
        self.assertEqual(self.worker(new, '/v1/inbox')[0], 200)
        self.assertEqual(self.request(path + '/settings', 'POST', {'enabled': False, 'commands': ['start','help']}, self.a)[0], 200)
        self.assertEqual(self.worker(new, '/v1/inbox')[0], 401)
        self.request(path + '/settings', 'POST', {'enabled': True, 'commands': []}, self.a)
        self.request('/v1/account', 'DELETE', token=self.a)
        self.assertEqual(self.worker(new, '/v1/inbox')[0], 401)
        self.assertEqual(self.request('/v1/identity/' + body['card']['id'], token=self.b)[0], 404)

    def test_owner_restriction_cannot_be_bypassed_by_bot(self):
        _, body = self.create_body(); self.request('/v2/bots', 'POST', body, self.a)
        with self.relay.db() as db:
            db.execute("INSERT INTO sanctions VALUES (?,?,strftime('%s','now')+3600,?,?,0)", (self.alice_card['id'], 'ban', 'case', self.bob_card['id']))
        self.assertEqual(self.worker(body['token'], '/v1/inbox')[0], 403)
        _, second = self.create_body()
        self.assertEqual(self.request('/v2/bots', 'POST', second, self.a)[0], 403)


if __name__ == '__main__': unittest.main()
