import base64
import hashlib
import json
import time
import unittest
from unittest.mock import patch
import test_relay as fixtures


class PrivacyTests(unittest.TestCase):
    setUp = fixtures.RelayTests.setUp
    tearDown = fixtures.RelayTests.tearDown
    request = fixtures.RelayTests.request
    login = fixtures.RelayTests.login

    def test_invite_is_one_use_and_keeps_no_secret(self):
        status, invite=self.request('/v1/invites','POST',{'seconds':600,'uses':1},self.a)
        self.assertEqual(status,200)
        with self.relay.db() as db:
            row=db.execute('SELECT digest FROM invites').fetchone()
            self.assertEqual(row[0],hashlib.sha256(invite['token'].encode()).hexdigest())
        status,result=self.request('/v1/invites/redeem','POST',{'token':invite['token']},self.b)
        self.assertEqual(status,200)
        self.assertEqual(result['card'],self.alice_card)
        self.assertEqual(self.request('/v1/invites/redeem','POST',{'token':invite['token']},self.b)[0],404)

    def test_invite_expiry_revocation_and_owner_isolation(self):
        _,invite=self.request('/v1/invites','POST',{'seconds':600},self.a)
        self.request('/v1/invites/'+invite['id'],'DELETE',token=self.b)
        self.assertEqual(len(self.request('/v1/invites',token=self.a)[1]['invites']),1)
        self.request('/v1/invites/'+invite['id'],'DELETE',token=self.a)
        self.assertEqual(self.request('/v1/invites/redeem','POST',{'token':invite['token']},self.b)[0],404)
        _,invite=self.request('/v1/invites','POST',{'seconds':600},self.a)
        with self.relay.db() as db:
            db.execute('UPDATE invites SET expires=?',(int(time.time())-1,))
        self.assertEqual(self.request('/v1/invites/redeem','POST',{'token':invite['token']},self.b)[0],404)

    def test_invitation_rejects_invalid_limits(self):
        for body in ({'seconds':True},{'seconds':1},{'uses':0},{'uses':101},{'seconds':700000}):
            self.assertEqual(self.request('/v1/invites','POST',body,self.a)[0],400)

    def test_code_rotation_removes_old_code(self):
        _,old=self.request('/v1/code','POST',{},self.a)
        _,new=self.request('/v1/code/rotate','POST',{},self.a)
        self.assertNotEqual(old['code'],new['code'])
        self.assertEqual(self.request('/v1/code/'+old['code'],token=self.b)[0],404)
        self.assertEqual(self.request('/v1/code/'+new['code'],token=self.b)[1],self.alice_card)

    def test_hidden_discovery_preserves_known_identity_and_invite(self):
        _,code=self.request('/v1/code','POST',{},self.a)
        self.request('/v1/username','POST',{'username':'private_ghost'},self.a)
        status,_=self.request('/v1/privacy','POST',{'discoverable':False,'trustedCalls':True,'inactivityDays':30},self.a)
        self.assertEqual(status,200)
        self.assertEqual(self.request('/v1/code/'+code['code'],token=self.b)[0],404)
        self.assertEqual(self.request('/v1/username/private_ghost',token=self.b)[0],404)
        self.assertEqual(self.request('/v1/identity/'+self.alice_card['id'],token=self.b)[0],200)
        _,invite=self.request('/v1/invites','POST',{},self.a)
        self.assertEqual(self.request('/v1/invites/redeem','POST',{'token':invite['token']},self.b)[0],200)

    def test_privacy_rejects_wrong_types(self):
        self.assertEqual(self.request('/v1/privacy','POST',{'discoverable':1,'trustedCalls':True,'inactivityDays':30},self.a)[0],400)
        self.assertEqual(self.request('/v1/privacy','POST',{'discoverable':True,'trustedCalls':True,'inactivityDays':31},self.a)[0],400)

    def test_trust_sync_replaces_owner_list_atomically(self):
        self.request('/v1/trust','POST',{'id':self.bob_card['id'],'trusted':True},self.a)
        self.request('/v1/trust','POST',{'id':self.alice_card['id'],'trusted':True},self.b)
        self.assertEqual(self.request('/v1/trust/sync','POST',{'ids':['invalid']},self.a)[0],400)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM trusted WHERE owner=?',(self.alice_card['id'],)).fetchone()[0],1)
        self.assertEqual(self.request('/v1/trust/sync','POST',{'ids':[]},self.a)[0],200)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM trusted WHERE owner=?',(self.alice_card['id'],)).fetchone()[0],0)
            self.assertEqual(db.execute('SELECT count(*) FROM trusted WHERE owner=?',(self.bob_card['id'],)).fetchone()[0],1)

    def test_revoke_other_sessions_preserves_current(self):
        old=self.a
        self.a=self.login(self.alice,self.alice_card)
        self.assertEqual(len(self.request('/v1/sessions',token=self.a)[1]['sessions']),2)
        self.assertEqual(self.request('/v1/sessions/revoke','POST',{},self.a)[0],200)
        self.assertEqual(self.request('/v1/inbox',token=old)[0],401)
        self.assertEqual(self.request('/v1/inbox',token=self.a)[0],200)
        self.assertEqual(len(self.request('/v1/sessions',token=self.b)[1]['sessions']),1)

    def test_push_token_moves_to_new_identity_and_can_be_disabled(self):
        token='a'*64
        body={'token':token,'kind':'voip','environment':'sandbox'}
        self.assertEqual(self.request('/v1/push','POST',body,self.a)[0],200)
        self.assertEqual(self.request('/v1/push','POST',body,self.b)[0],200)
        with self.relay.db() as db:
            rows=db.execute('SELECT identity FROM push_tokens WHERE token=?',(token,)).fetchall()
            self.assertEqual([r[0] for r in rows],[self.bob_card['id']])
        body['enabled']=False
        self.request('/v1/push','POST',body,self.b)
        with self.relay.db() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM push_tokens').fetchone()[0],0)

    def test_inactivity_erases_queues_and_identity(self):
        self.request('/v1/privacy','POST',{'discoverable':True,'trustedCalls':True,'inactivityDays':30},self.a)
        self.request('/v1/invites','POST',{},self.a)
        with self.relay.db() as db:
            db.execute('UPDATE privacy SET last_active=? WHERE identity=?',(int(time.time())-31*86400,self.alice_card['id']))
            self.relay.clean(db)
            for table,col in [('identities','id'),('privacy','identity'),('sessions','identity'),('invites','owner')]:
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table} WHERE {col}=?',(self.alice_card['id'],)).fetchone()[0],0)
        self.assertEqual(self.request('/v1/inbox',token=self.a)[0],401)

    def test_account_delete_clears_new_privacy_tables(self):
        self.request('/v1/invites','POST',{},self.a)
        self.request('/v1/trust','POST',{'id':self.bob_card['id'],'trusted':True},self.a)
        self.request('/v1/push','POST',{'token':'d'*64,'kind':'alert','environment':'sandbox'},self.a)
        self.assertEqual(self.request('/v1/account','DELETE',token=self.a)[0],200)
        with self.relay.db() as db:
            for table in ('privacy','invites','trusted','push_tokens'):
                # Bob still has a privacy row.
                where=' WHERE identity=?' if table in ('privacy','push_tokens') else ' WHERE owner=?'
                self.assertEqual(db.execute('SELECT count(*) FROM '+table+where,(self.alice_card['id'],)).fetchone()[0],0)

    def test_username_release_and_discovery_rate_limit(self):
        self.request('/v1/username','POST',{'username':'temporary_name'},self.a)
        self.request('/v1/username','DELETE',token=self.a)
        self.assertEqual(self.request('/v1/username/temporary_name',token=self.b)[0],404)
        # A test spanning a wall-clock minute starts a new production bucket.
        # Hold the clock steady while exercising the documented lookup quota.
        with patch('app.time.time', return_value=time.time()):
            for _ in range(30):
                self.request('/v1/code/AAAA',token=self.b)
            self.assertEqual(self.request('/v1/code/AAAA',token=self.b)[0],429)
