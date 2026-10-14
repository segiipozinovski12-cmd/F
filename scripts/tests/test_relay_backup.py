import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'server/tests'))
import test_relay
from app import Relay
spec=importlib.util.spec_from_file_location('relay_backup',ROOT/'scripts/relay_backup.py'); backup=importlib.util.module_from_spec(spec); spec.loader.exec_module(backup)

class RelayBackupTests(unittest.TestCase):
    request=test_relay.RelayTests.request
    login=test_relay.RelayTests.login

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.path=Path(self.temp.name)/'relay.sqlite3'; self.relay=Relay(self.path)
        self.private,self.card=test_relay.identity(); self.token=self.login(self.private,self.card)
        self.assertEqual(self.request('/v1/username','POST',{'username':'vo1d'},self.token)[0],200)

    def tearDown(self): self.temp.cleanup()

    def test_consistent_snapshot_restores_permanent_owner_but_not_sessions(self):
        snapshot=Path(self.temp.name)/'backup.sqlite3'; restored=Path(self.temp.name)/'restored.sqlite3'
        result=backup.snapshot(self.path,snapshot); self.assertTrue(result['hasPermanentAdministrator']); self.assertEqual(len(result['sha256']),64)
        with self.relay.db() as db: db.execute('DELETE FROM sessions')
        result=backup.snapshot(snapshot,restored,restore=True); self.assertTrue(result['restored'])
        self.relay=Relay(restored)
        self.assertEqual(self.request('/v1/inbox',token=self.token)[0],401)
        current=self.login(self.private,self.card)
        self.assertEqual(self.request('/v2/moderation/access',token=current)[1]['role'],'owner')
        other,card=test_relay.identity(); token=self.login(other,card)
        self.assertEqual(self.request('/v1/username','POST',{'username':'vo1d'},token)[0],409)

    def test_existing_destination_corruption_and_changed_owner_fail_closed(self):
        destination=Path(self.temp.name)/'existing'; destination.write_bytes(b'keep')
        with self.assertRaises(ValueError): backup.snapshot(self.path,destination)
        self.assertEqual(destination.read_bytes(),b'keep')
        with self.relay.db() as db: db.execute('UPDATE permanent_admin SET owner=?',('f'*64,))
        with self.assertRaises(ValueError): backup.snapshot(self.path,Path(self.temp.name)/'invalid.sqlite3')
        self.assertFalse((Path(self.temp.name)/'invalid.sqlite3').exists())

    def test_restore_disables_bot_workers_and_recovery_codes(self):
        with self.relay.db() as db:
            db.execute('INSERT INTO bots(identity,owner,username,name,token_digest,enabled,created) VALUES (?,?,?,?,?,1,0)',('a'*64,self.card['id'],'example_bot','Bot','digest'))
            db.execute('INSERT INTO moderator_recovery VALUES (?,?,0)',(self.card['id'],'digest'))
        destination=Path(self.temp.name)/'restored.sqlite3'; backup.snapshot(self.path,destination,restore=True)
        self.relay=Relay(destination)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT enabled FROM bots').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT count(*) FROM moderator_recovery').fetchone()[0],0)
