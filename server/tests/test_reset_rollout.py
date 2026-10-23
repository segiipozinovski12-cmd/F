import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import Relay
import reset_rollout


class RequestedResetTests(unittest.TestCase):
    def test_only_the_exact_authorized_deployment_can_reach_the_database(self):
        valid = {**reset_rollout.TARGET, 'VO1D_REQUESTED_RESET': reset_rollout.ROLLOUT}
        invalid = [{**valid, field: 'wrong-target'} for field in valid]
        invalid.append({**valid, 'VO1D_DISABLE_REQUESTED_RESET': '1'})
        for env in invalid:
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), \
                    patch.object(reset_rollout, 'reset_database') as operation:
                self.assertFalse(reset_rollout.apply_requested_reset())
                operation.assert_not_called()

    def test_reset_revokes_sessions_removes_blobs_and_cannot_repeat_after_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path, blobs = root / 'relay.sqlite3', root / 'blobs'
            relay = Relay(path)
            with relay.db() as db:
                db.execute('INSERT INTO identities VALUES (?,?)', ('old-account', '{}'))
                db.execute('INSERT INTO sessions VALUES (?,?,?)', ('old-session', 'old-account', 9999999999))
                db.execute('INSERT INTO usernames VALUES (?,?,?)', ('old_user', 'old-account', 1))
            blobs.mkdir()
            (blobs / 'old-ciphertext').write_bytes(b'old-data')
            # Windows has no chown; Linux CI and the live Docker entrypoint use it.
            with patch('maintenance.os.chown', create=True) as ownership:
                self.assertTrue(reset_rollout.reset_database(path, blobs, root))
                self.assertTrue(ownership.called)
            with closing(sqlite3.connect(path)) as db, db:
                for table in ('identities', 'sessions', 'usernames', 'permanent_admin'):
                    self.assertEqual(db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 0)
                self.assertEqual(db.execute("SELECT value FROM relay_meta WHERE key='minimum_enrollment_version'").fetchone()[0], '2')
                epoch = db.execute("SELECT value FROM relay_meta WHERE key='account_epoch'").fetchone()[0]
                db.execute('INSERT INTO identities VALUES (?,?)', ('new-account', '{}'))
            self.assertEqual(list(blobs.iterdir()), [])
            self.assertEqual(list(root.glob('reset-backup-*')), [])
            with patch.object(reset_rollout, 'reset') as operation:
                self.assertFalse(reset_rollout.reset_database(path, blobs, root))
                operation.assert_not_called()
            with closing(sqlite3.connect(path)) as db, db:
                self.assertEqual(db.execute('SELECT id FROM identities').fetchone()[0], 'new-account')
                self.assertEqual(db.execute("SELECT value FROM relay_meta WHERE key='account_epoch'").fetchone()[0], epoch)

    def test_new_volume_gets_a_persistent_reset_receipt_and_enrollment_epoch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch('maintenance.os.chown', create=True):
                self.assertTrue(reset_rollout.reset_database(root / 'relay.sqlite3', root / 'blobs', root))
            with closing(sqlite3.connect(root / 'relay.sqlite3')) as db, db:
                self.assertEqual(db.execute("SELECT value FROM relay_meta WHERE key='completed_reset_rollout'").fetchone()[0], reset_rollout.ROLLOUT)
                self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')


if __name__ == '__main__':
    unittest.main()
