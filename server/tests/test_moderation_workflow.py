"""Queue traversal, simultaneous assignment and appeal isolation contracts."""
import concurrent.futures
import json
import time
import unittest
import uuid
from urllib.parse import urlencode

import test_moderation
import test_relay
from app import header_bytes


class WorkflowTests(unittest.TestCase):
    setUp = test_moderation.ModerationTests.setUp
    tearDown = test_moderation.ModerationTests.tearDown
    request = test_moderation.ModerationTests.request
    login = test_moderation.ModerationTests.login
    claim = test_moderation.ModerationTests.claim
    mfa = test_moderation.ModerationTests.mfa
    mr = test_moderation.ModerationTests.mr
    mod_request = test_moderation.ModerationTests.mod_request
    report = test_moderation.ModerationTests.report
    submit = test_moderation.ModerationTests.submit

    def seed(self, count):
        now = int(time.time())
        with self.relay.db() as db:
            for index in range(count):
                db.execute('''INSERT INTO reports(id,reporter,subject,reason,source,digest,envelope,sender_card,status,created,expires,updated)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''', (str(uuid.uuid4()), self.bob_card['id'], self.charlie_card['id'],
                  'spam' if index % 2 else 'other', 'chat', 'digest', '', '', 'open', now, now + 3600, now))

    def test_keyset_pages_cover_equal_timestamps_without_evidence_or_duplicates(self):
        self.claim(); token, _ = self.mfa(); self.seed(137)
        ids, cursor = [], None
        while True:
            params = {'limit': '17', 'status': 'active'}
            if cursor:
                params['cursor'] = cursor
            status, result = self.mr('/v2/moderation/queue?' + urlencode(params), token=token)
            self.assertEqual(status, 200)
            self.assertLessEqual(len(result['reports']), 17)
            for row in result['reports']:
                self.assertNotIn('envelope', row); self.assertNotIn('reporter', row)
                ids.append(row['id'])
            cursor = result['nextCursor']
            if cursor is None:
                break
        self.assertEqual(len(ids), 137); self.assertEqual(len(set(ids)), 137)
        result = self.mr('/v2/moderation/queue?reason=spam&search=' + self.charlie_card['id'][:10], token=token)[1]
        self.assertEqual(len(result['reports']), 68)
        page = self.mr('/v2/moderation/queue?limit=1&status=active', token=token)[1]
        self.assertEqual(self.mr('/v2/moderation/queue?' + urlencode({'cursor': page['nextCursor'], 'status': 'all'}), token=token)[0], 400)

    def test_invalid_query_corpus_fails_closed(self):
        self.claim(); token, _ = self.mfa()
        for query in ('limit=0', 'limit=101', 'limit=-1', 'status[]=open', 'status=open&status=all', 'reason=secret',
                      'search=%25', 'cursor=invalid', 'assignment=owner', '&'.join('limit=1' for _ in range(13))):
            self.assertEqual(self.mr('/v2/moderation/queue?' + query, token=token)[0], 400, query)

    def test_assignment_race_role_revocation_and_foreign_review(self):
        self.claim(); case = self.submit(); owner, _ = self.mfa()
        for card in (self.bob_card, self.charlie_card):
            self.assertEqual(self.mr('/v2/moderation/roles', 'POST', {'identity': card['id'], 'role': 'reviewer'}, owner)[0], 200)
        reviewer_b, _ = self.mfa(self.b); reviewer_c, _ = self.mfa(self.c)
        revision = self.mr('/v2/moderation/queue', token=owner)[1]['reports'][0]['updated']
        def claim_case(args):
            account, token, identity = args
            return self.mr('/v2/moderation/assign', 'POST', {'report': case, 'assignee': identity, 'expectedUpdated': revision}, token, account)[0]
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            result = list(pool.map(claim_case, ((self.b, reviewer_b, self.bob_card['id']), (self.c, reviewer_c, self.charlie_card['id']))))
        self.assertEqual(sorted(result), [200, 409])
        row = self.mr('/v2/moderation/queue', token=owner)[1]['reports'][0]
        account, token = (self.c, reviewer_c) if row['assignee'] == self.bob_card['id'] else (self.b, reviewer_b)
        decision = dict(report=case, status='dismissed', action='none', expectedUpdated=row['updated'])
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, token, account)[0], 403)
        self.assertEqual(self.mr('/v2/moderation/roles', 'POST', {'identity': row['assignee'], 'role': 'none'}, owner)[0], 200)
        updated = self.mr('/v2/moderation/queue?assignment=unassigned', token=owner)[1]['reports'][0]
        self.assertIsNone(updated['assignee']); self.assertGreater(updated['updated'], row['updated'])

    def appeal(self, owner):
        case = self.submit()
        revision = self.mr('/v2/moderation/queue', token=owner)[1]['reports'][0]['updated']
        decision = dict(report=case, status='resolved', action='ban', seconds=3600, expectedUpdated=revision)
        self.assertEqual(self.mr('/v2/moderation/decision', 'POST', decision, owner)[0], 200)
        envelope = self.report()['envelope']; envelope['sender'] = self.charlie_card['id']
        import base64
        envelope['signature'] = test_relay.encode(self.charlie.sign(header_bytes(envelope) + b'\n' + base64.b64decode(envelope['ciphertext'])))
        self.assertEqual(self.request('/v2/appeals', 'POST', dict(report=case, consent=True, envelope=envelope), self.c)[0], 200)
        return self.mr('/v2/moderation/appeals?status=open', token=owner)[1]['appeals'][0]

    def test_owner_self_review_requires_ack_and_is_audited_and_idempotence_safe(self):
        self.claim(); owner, _ = self.mfa(); row = self.appeal(owner)
        body = dict(appeal=row['id'], outcome='overturned', expectedUpdated=row['updated'])
        self.assertEqual(self.mr('/v2/moderation/appeal-decision', 'POST', body, owner)[0], 403)
        body['acknowledgeSelfReview'] = True
        self.assertEqual(self.mr('/v2/moderation/appeal-decision', 'POST', body, owner)[0], 200)
        self.assertEqual(self.mr('/v2/moderation/appeal-decision', 'POST', body, owner)[0], 409)
        self.assertEqual(self.request('/v2/reports/notices', token=self.c)[1]['notices'], [])
        events = self.mr('/v2/moderation/audit', token=owner)[1]['events']
        self.assertIn('appeal_overturned_self_review', json.loads(events[0]['entry'])['action'])

    def test_independent_appeal_does_not_lift_newer_sanction_from_different_case(self):
        self.claim(); owner, _ = self.mfa(); row = self.appeal(owner)
        self.mr('/v2/moderation/roles', 'POST', {'identity': self.bob_card['id'], 'role': 'admin'}, owner)
        delegate, _ = self.mfa(self.b)
        with self.relay.db() as db:
            db.execute('UPDATE sanctions SET report=?,actor=?', (str(uuid.uuid4()), self.bob_card['id']))
        body = dict(appeal=row['id'], outcome='overturned', expectedUpdated=row['updated'])
        self.assertEqual(self.mr('/v2/moderation/appeal-decision', 'POST', body, delegate, self.b)[0], 200)
        self.assertEqual(len(self.request('/v2/reports/notices', token=self.c)[1]['notices']), 1)
        self.assertEqual(self.mr('/v2/moderation/appeal/' + row['id'], token=delegate, account=self.b)[0], 403)


if __name__ == '__main__':
    unittest.main()
