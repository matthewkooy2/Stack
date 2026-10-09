"""Offline Apple boundary checks with ephemeral RSA keys and synthetic identities."""
import copy
import json
import time
import unittest
from unittest.mock import patch
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from agents import apple_auth as apple
REAL_CONFIGURATION = apple.configuration


class Store:
    def __init__(self):
        self.records = {}

    def create_token(self, user_id, purpose, ttl, value):
        state = 's' * 43
        self.records[state] = dict(user_id=user_id, identity_value=value)
        return state

    def peek_token(self, state, purpose):
        return self.records.get(state)

    def consume_token(self, state, purpose):
        return self.records.pop(state, None)


class DB:
    def __init__(self):
        self.values = {}
        self.fail_grant = False
        self.manager = None

    def rows(self, sql, args):
        if 'sso_lookups' in sql:
            return [(s,) for s,u in self.manager.links.items() if u == args['u']]
        if sql.startswith('UPDATE identity_users'):
            self.manager.users[args['u']]['identities'] = json.loads(args['i'])
            return [(args['u'],)]
        key = args['k']
        if sql.startswith('SELECT'):
            return [(self.values[key],)] if key in self.values else []
        if sql.startswith('DELETE'):
            if 'v' not in args or self.values.get(key) == args['v']:
                self.values.pop(key, None)
            return []
        if key.startswith('stack-apple-lock:'):
            if key in self.values:
                return []
        elif self.fail_grant:
            raise RuntimeError('fixture write failure')
        self.values[key] = args['v']
        return [(key,)]


class Manager:
    def __init__(self):
        self.users = {'old': dict(user_id='old', root_id='old-root', status='active', role='user',
                                 profile={'kept': 'existing'}, username='existing')}
        self.links = {}
        self.tokens = []

    def authenticate(self, username, password):
        return self.users['old'] if username == 'existing' and password == 'correct' else None

    def get_root_id(self, user_id):
        return self.users.get(user_id, {}).get('root_id')

    def get_user_by_sso(self, platform, subject):
        return self.users.get(self.links.get(subject))

    def create_user(self, username, password):
        uid = 'new' + str(len(self.users))
        self.users[uid] = dict(user_id=uid, root_id=uid+'-root', username=username, profile={})
        return self.users[uid]

    def get_user(self, uid):
        return copy.deepcopy(self.users.get(uid))

    def link_sso_account(self, uid, platform, subject):
        if subject in self.links and self.links[subject] != uid:
            return {'error': 'conflict'}
        self.links[subject] = uid
        self.users[uid].setdefault('identities', []).append(
            dict(type='sso',provider=platform,external_id=subject))
        return {}

    def get_sso_accounts(self, uid):
        return [{'platform':x['provider'],'external_id':x['external_id']}
                for x in self.users.get(uid,{}).get('identities',[]) if x['type'] == 'sso']

    def delete_user(self, uid):
        self.users.pop(uid, None)
        self.links = {s: u for s, u in self.links.items() if u != uid}

    def update_user_fields(self, uid, values):
        self.users[uid].update({k:v for k,v in values.items() if k != 'identities'})
        return True

    def create_jwt_token(self, uid):
        self.tokens.append(uid)
        return 'stack-jwt-fixture'

    def get_username(self, uid):
        return self.users[uid]['username']


class AppleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.manager, self.store, self.db = Manager(), Store(), DB()
        self.db.manager = self.manager
        self.cfg = dict(STACK_APPLE_CLIENT_ID='com.fixture.stack', STACK_APPLE_TEAM_ID='fixture-team',
                        STACK_APPLE_KEY_ID='fixture-key', STACK_APPLE_KEY_FILE='unused',
                        STACK_CONNECTION_KEY=Fernet.generate_key().decode())
        self.patches = [patch.object(apple, 'configuration', return_value=self.cfg),
                        patch.object(apple, 'runtime', return_value=(self.manager, self.store, self.db)),
                        patch.object(apple, 'signing_key', return_value=self.key.public_key()),
                        patch.object(apple, 'client_secret', return_value='fixture-secret')]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def jwt(self, changes=None, header=None):
        claims = dict(iss=apple.ISSUER, aud=self.cfg['STACK_APPLE_CLIENT_ID'], sub='fixture-subject',
                      exp=int(time.time())+300, iat=int(time.time()), nonce=self.nonce)
        claims.update(changes or {})
        a = apple.b64(json.dumps(header or {'alg': 'RS256', 'kid': 'fixture-key'}).encode())
        b = apple.b64(json.dumps(claims).encode())
        sig = self.key.sign((a+'.'+b).encode(), padding.PKCS1v15(), hashes.SHA256())
        return a+'.'+b+'.'+apple.b64(sig)

    def begin(self, action='login', owner='', username='', password=''):
        result = apple.begin(action, owner, username, password)
        if result['ok']:
            self.state, self.nonce = result['state'], result['nonce']
        return result

    def finish(self, changes=None, action='login', owner='', name=''):
        token = self.jwt(changes)
        with patch.object(apple, 'provider', return_value={'id_token': token, 'refresh_token': 'private-fixture-grant'}):
            return apple.finish(self.state, token, 'fixture-code', name, action, owner)

    def test_new_and_returning_identity_keep_root_and_optional_name(self):
        self.begin()
        first = self.finish({'email': 'hidden@privaterelay.appleid.com', 'email_verified': 'true',
                             'is_private_email': 'true'}, name='Initial Name')
        self.assertTrue(first['ok'])
        uid = self.manager.tokens[-1]
        root = self.manager.get_root_id(uid)
        self.begin()
        self.assertTrue(self.finish()['ok'])
        self.assertEqual(self.manager.tokens, [uid, uid])
        self.assertEqual(self.manager.get_root_id(uid), root)
        self.assertEqual(self.manager.users[uid]['profile']['apple']['name'], 'Initial Name')
        self.assertTrue(self.manager.users[uid]['profile']['apple']['private_email'])
        self.assertNotIn('private-fixture-grant', json.dumps(first))
        self.assertNotIn('private-fixture-grant', next(v for k,v in self.db.values.items() if 'grant:' in k))

    def test_email_never_selects_existing_stack_user(self):
        self.manager.users['old']['profile']['email'] = 'existing@fixture.invalid'
        self.begin()
        self.assertTrue(self.finish({'email':'existing@fixture.invalid', 'email_verified':True})['ok'])
        self.assertNotEqual(self.manager.tokens[-1], 'old')

    def test_replay_is_rejected(self):
        self.begin()
        self.assertTrue(self.finish()['ok'])
        self.assertFalse(self.finish()['ok'])
        self.assertEqual(len(self.manager.tokens), 1)

    def test_wrong_claims_and_signature_cannot_issue_session(self):
        self.begin()
        for changes in ({'iss':'https://evil.invalid'}, {'aud':'other.app'}, {'nonce':'wrong'},
                        {'exp':time.time()-1}, {'iat':time.time()+100}, {'iat':True}, {'sub':''},
                        {'nbf':time.time()+100}, {'exp':float('nan')}, {'iat':float('inf')}):
            with self.subTest(changes=changes), self.assertRaises(apple.AppleError):
                apple.verify(self.jwt(changes), self.cfg['STACK_APPLE_CLIENT_ID'], self.nonce)
        token = self.jwt()
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with patch.object(apple, 'signing_key', return_value=other.public_key()), self.assertRaises(apple.AppleError):
            apple.verify(token, self.cfg['STACK_APPLE_CLIENT_ID'], self.nonce)
        self.assertEqual(self.manager.tokens, [])

    def test_algorithm_confusion_and_duplicate_claims_rejected(self):
        self.begin()
        for alg in ('none','HS256','ES256'):
            with self.assertRaises(apple.AppleError):
                apple.verify(self.jwt(header={'alg':alg,'kid':'fixture-key'}), self.cfg['STACK_APPLE_CLIENT_ID'], self.nonce)
        with self.assertRaises(apple.AppleError):
            apple.object_pairs([('sub','one'),('sub','two')])

    def test_exchange_subject_must_match_native_identity(self):
        self.begin()
        with patch.object(apple, 'provider', return_value={'id_token':self.jwt({'sub':'different'}), 'refresh_token':'grant'}):
            result = apple.finish(self.state, self.jwt(), 'code')
        self.assertFalse(result['ok'])
        self.assertEqual(self.manager.tokens, [])

    def test_missing_refresh_grant_and_failed_storage_never_issue_jwt(self):
        self.begin()
        with patch.object(apple, 'provider', return_value={'id_token':self.jwt()}):
            self.assertFalse(apple.finish(self.state, self.jwt(), 'code')['ok'])
        self.begin()
        self.db.fail_grant = True
        self.assertFalse(self.finish()['ok'])
        self.assertEqual(self.manager.tokens, [])
        self.assertEqual(set(self.manager.users), {'old'})

    def test_existing_account_grant_failure_does_not_link_apple(self):
        self.begin('link','old-root','existing','correct')
        self.db.fail_grant = True
        self.assertFalse(self.finish(action='link',owner='old-root')['ok'])
        self.assertEqual(self.manager.links, {})
        self.assertEqual(self.manager.tokens, [])

    def test_account_cannot_link_two_apple_subjects(self):
        self.manager.link_sso_account('old','apple','prior-subject')
        self.begin('link','old-root','existing','correct')
        self.assertEqual(self.finish(action='link',owner='old-root')['code'], 'APPLE_CONFLICT')
        self.assertEqual(self.manager.links, {'prior-subject':'old'})

    def test_deletion_holds_same_account_lock_as_signin(self):
        with apple.deletion_guard('old'):
            self.begin('link','old-root','existing','correct')
            self.assertEqual(self.finish(action='link',owner='old-root')['code'], 'APPLE_CONFLICT')
        self.assertEqual(self.manager.tokens, [])

    def test_fresh_apple_proof_can_revoke_after_lost_or_unreadable_grant(self):
        self.manager.link_sso_account('old','apple','fixture-subject')
        for saved in (None, 'unreadable'):
            self.db.values.clear()
            if saved:
                self.db.values['stack-apple-grant:old'] = saved
            with patch.object(apple,'provider',return_value={}) as provider:
                with apple.deletion_guard('old','fresh-verified-grant'):
                    pass
            self.assertEqual(provider.call_args.args[1]['token'], 'fresh-verified-grant')

    def test_partial_lookup_is_repaired_before_returning_login(self):
        self.manager.links['fixture-subject'] = 'old'
        self.begin()
        self.assertTrue(self.finish()['ok'])
        self.assertEqual(self.manager.get_sso_accounts('old'),
                         [{'platform':'apple','external_id':'fixture-subject'}])

    def test_partial_link_still_revokes_saved_grant_on_deletion(self):
        self.begin('link','old-root','existing','correct')
        def partial(uid, platform, subject):
            self.manager.links[subject] = uid
            raise RuntimeError('fixture document update failed')
        with patch.object(self.manager,'link_sso_account',side_effect=partial):
            self.assertFalse(self.finish(action='link',owner='old-root')['ok'])
        self.assertEqual(self.manager.get_sso_accounts('old'), [])
        self.assertIn('stack-apple-grant:old', self.db.values)
        with patch.object(apple,'provider',return_value={}) as provider:
            with apple.deletion_guard('old'):
                pass
        self.assertEqual(provider.call_args.args[0], '/auth/revoke')

    def test_link_requires_password_and_same_root_and_preserves_profile(self):
        self.assertFalse(self.begin('link','old-root','existing','wrong')['ok'])
        self.assertFalse(self.begin('link','other-root','existing','correct')['ok'])
        self.assertTrue(self.begin('link','old-root','existing','correct')['ok'])
        self.assertFalse(self.finish(action='login')['ok'])
        self.assertTrue(self.finish(action='link',owner='old-root')['ok'])
        self.assertEqual(self.manager.tokens, ['old'])
        self.assertEqual(self.manager.users['old']['profile']['kept'], 'existing')

    def test_link_cannot_move_identity_between_accounts(self):
        self.begin()
        self.finish()
        self.begin('link','old-root','existing','correct')
        result = self.finish(action='link',owner='old-root')
        self.assertEqual(result['code'], 'APPLE_CONFLICT')
        self.assertNotEqual(self.manager.links['fixture-subject'], 'old')

    def test_inactive_identity_cannot_sign_in(self):
        self.manager.links['fixture-subject'] = 'old'
        self.manager.users['old']['status'] = 'disabled'
        self.begin()
        self.assertFalse(self.finish()['ok'])
        self.assertEqual(self.manager.tokens, [])

    def test_deletion_requires_fresh_matching_identity_and_revokes_grant(self):
        self.begin('link','old-root','existing','correct')
        self.finish(action='link',owner='old-root')
        self.begin('delete','old-root')
        token = self.jwt()
        calls = []
        def provider(path, form):
            calls.append(path)
            return {'id_token':token,'refresh_token':'fresh-grant'} if path == '/auth/token' else {}
        with patch.object(apple,'provider',side_effect=provider):
            proof = apple.deletion_proof(self.state,token,'code','old-root')
            self.assertEqual(proof['user_id'], 'old')
            with apple.deletion_guard(proof['user_id'],proof['refresh']):
                pass
        self.assertEqual(calls, ['/auth/token','/auth/revoke','/auth/revoke'])
        self.assertIn('stack-apple-grant:old', self.db.values)
        apple.forget_grant('old')
        self.assertNotIn('stack-apple-grant:old', self.db.values)

    def test_revocation_failure_blocks_deletion_proof(self):
        self.begin('link','old-root','existing','correct')
        self.finish(action='link',owner='old-root')
        self.begin('delete','old-root')
        token = self.jwt()
        def provider(path, form):
            if path == '/auth/revoke':
                raise apple.AppleError('APPLE_UNAVAILABLE','safe fixture failure')
            return {'id_token':token,'refresh_token':'fresh-grant'}
        with patch.object(apple,'provider',side_effect=provider), self.assertRaises(apple.AppleError):
            proof = apple.deletion_proof(self.state,token,'code','old-root')
            with apple.deletion_guard(proof['user_id'],proof['refresh']):
                self.fail('revocation failure entered cleanup')
        self.assertIn('old', self.manager.users)

    def test_deletion_proof_cannot_delete_another_root(self):
        self.manager.links['fixture-subject'] = 'old'
        self.begin('delete','other-root')
        token = self.jwt()
        with patch.object(apple,'provider',return_value={'id_token':token,'refresh_token':'grant'}), self.assertRaises(apple.AppleError):
            apple.deletion_proof(self.state,token,'code','other-root')

    def test_disabled_by_default(self):
        with patch.dict('os.environ', {}, clear=True), patch.object(apple,'configuration',REAL_CONFIGURATION):
            result = apple.begin()
        self.assertEqual(result['code'], 'APPLE_DISABLED')

    def test_identity_lock_rejects_concurrent_subject_operation(self):
        with apple.identity_lock(self.db,'subject'), self.assertRaises(apple.AppleError):
            with apple.identity_lock(self.db,'subject'):
                self.fail('second operation acquired same subject')


if __name__ == '__main__':
    unittest.main()
