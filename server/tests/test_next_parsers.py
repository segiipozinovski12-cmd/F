import copy
import json
import random
import unittest
import test_moderation


class NextParserTests(unittest.TestCase):
    # Use the same signed fixture and authenticated request helpers without
    # re-running the parent test cases in this parser corpus.
    setUp = test_moderation.ModerationTests.setUp
    tearDown = test_moderation.ModerationTests.tearDown
    request = test_moderation.ModerationTests.request
    login = test_moderation.ModerationTests.login
    claim = test_moderation.ModerationTests.claim
    report = test_moderation.ModerationTests.report
    def test_bounded_report_mutation_corpus_never_returns_500_or_inserts_invalid_rows(self):
        self.claim()
        corpus = [None, [], {}, True, 0, -1, 1.5, 'x', '\u202e', 'A' * 1000]
        baseline = self.report()
        requests = []
        for field in ('subject', 'reason', 'source', 'consent', 'envelope'):
            for value in corpus:
                candidate = copy.deepcopy(baseline); candidate[field] = value
                if field == 'consent' and value is True: continue
                requests.append(candidate)
        for field in baseline['envelope']:
            for value in corpus:
                candidate = copy.deepcopy(baseline); candidate['envelope'][field] = value
                requests.append(candidate)
        random.Random(6101).shuffle(requests)
        for candidate in requests:
            # Each case has a separate bounded rate window in this deterministic
            # parser test; production rate limiting is covered independently.
            with self.relay.db() as db: db.execute('DELETE FROM rates')
            status, result = self.request('/v2/reports', 'POST', candidate, self.b)
            self.assertIn(status, (400,403,413), (status, result, candidate))
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM reports').fetchone()[0], 0)


if __name__ == '__main__': unittest.main()
