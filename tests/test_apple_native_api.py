"""Native Apple RPCs against real disposable Jac identity and graph storage."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Apple verification requires disposable embedded data; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from agents import apple_auth as apple

ROOT = Path(__file__).resolve().parents[1]


class NativeAppleAPI(unittest.TestCase):
    def test_native_identity_link_admission_persistence_and_deletion(self):
        scratch = ROOT/'.jac/apple-api-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            config = Path(directory)/'config.json'
            config.write_text(json.dumps({'invite_only': False}))
            cfg = dict(STACK_APPLE_CLIENT_ID='com.fixture.stack', STACK_APPLE_TEAM_ID='fixture-team',
                       STACK_APPLE_KEY_ID='fixture-key', STACK_APPLE_KEY_FILE='unused',
                       STACK_CONNECTION_KEY=Fernet.generate_key().decode())
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            with patch.dict(os.environ, {'STACK_AGENT_CONFIG':str(config),
                'STACK_TRANSCRIPTION_STORAGE':str(Path(directory)/'audio')}), \
                 patch.object(apple,'configuration',return_value=cfg), \
                 patch.object(apple,'signing_key',return_value=key.public_key()), \
                 patch.object(apple,'client_secret',return_value='fixture-client-secret'):
                client = JacTestClient.from_file(str(ROOT/'main.jac'),base_path=directory)
                self.addCleanup(client.close)
                def rpc(name, args=None):
                    response = client.post('/function/'+name,json=args or {})
                    self.assertTrue(response.ok, response.text)
                    return response.data['result']
                def proof(challenge, subject='fixture-apple-subject'):
                    header = apple.b64(json.dumps({'alg':'RS256','kid':'fixture-key'}).encode())
                    payload = apple.b64(json.dumps(dict(iss=apple.ISSUER,aud=cfg['STACK_APPLE_CLIENT_ID'],
                        sub=subject,nonce=challenge['nonce'],iat=int(time.time()),exp=int(time.time())+300,
                        email='fixture@privaterelay.appleid.com',email_verified='true',is_private_email='true')).encode())
                    signature = key.sign((header+'.'+payload).encode(),padding.PKCS1v15(),hashes.SHA256())
                    token = header+'.'+payload+'.'+apple.b64(signature)
                    return dict(state=challenge['state'],identity_token=token,authorization_code='fixture-code')
                def finish(name, args):
                    with patch.object(client._server.module.apple_auth,'provider',return_value={
                        'id_token':args['identity_token'],'refresh_token':'fixture-private-refresh'}):
                        return rpc(name,args)
                # Private endpoints retain runtime authentication.
                for name in ('auth_apple_link_begin','auth_apple_delete_begin','account_delete_apple'):
                    response = client.post('/function/'+name,json={})
                    self.assertFalse(response.ok)
                # Prepared applications isolate Python helpers in their own
                # namespace. Bind transport/crypto fixtures to the RPC's module.
                service = client._server.module.apple_auth
                for attribute, value in [('configuration',cfg),('signing_key',key.public_key()),
                                         ('client_secret','fixture-client-secret')]:
                    fixture = patch.object(service,attribute,return_value=value)
                    fixture.start()
                    self.addCleanup(fixture.stop)
                registered = client.register_user('fixture-apple-existing','Fixture-password-123')
                self.assertTrue(registered.ok)
                client.set_auth_token(registered.data['token'])
                original = rpc('bootstrap')['user_id']
                rpc('save_profile',{'name':'Preserved Apple marker','role':'Engineer','location':'United States','mode':'Any','notifications':False})
                challenge = rpc('auth_apple_link_begin',{'username':'fixture-apple-existing','password':'Fixture-password-123'})
                self.assertTrue(challenge['ok'],challenge)
                args = proof(challenge)
                linked = finish('auth_apple_link_finish',args)
                self.assertTrue(linked['ok'],linked)
                client.set_auth_token(linked['token'])
                self.assertEqual(rpc('bootstrap')['user_id'],original)
                self.assertEqual(rpc('bootstrap')['profile']['name'],'Preserved Apple marker')
                # Reproduce a pinned-runtime lookup/document split, then repair
                # it with the real PostgreSQL schema before issuing a session.
                manager, _, db = service.runtime()
                uid = manager.validate_jwt_token(linked['token'])
                db.rows("""UPDATE identity_users SET doc=jsonb_set(doc,'{identities}',
                    (SELECT jsonb_agg(x) FROM jsonb_array_elements(doc->'identities') x
                     WHERE COALESCE(x->>'provider','') <> 'apple'),true) WHERE user_id=:u""", {'u':uid})
                self.assertEqual(manager.get_sso_accounts(uid), [])
                client.clear_auth()
                self.assertFalse(finish('auth_apple_finish',args)['ok'])
                # Returning login, then reload the actual identity/database state.
                result = finish('auth_apple_finish',proof(rpc('auth_apple_begin')))
                self.assertTrue(result['ok'],result)
                self.assertTrue(any(x['platform']=='apple' for x in manager.get_sso_accounts(uid)))
                client.reload()
                client.set_auth_token(result['token'])
                self.assertEqual(rpc('bootstrap')['user_id'],original)
                # Fresh proof cannot delete another account's root.
                other = client.register_user('fixture-apple-other','Fixture-password-456')
                client.set_auth_token(other.data['token'])
                challenge = rpc('auth_apple_delete_begin')
                self.assertIn('error',finish('account_delete_apple',proof(challenge)))
                client.set_auth_token(result['token'])
                # Admission is retained for product access, not owner deletion.
                config.write_text(json.dumps({'invite_only':True}))
                self.assertFalse(rpc('agent_admission')['admitted'])
                challenge = rpc('auth_apple_delete_begin')
                args = proof(challenge)
                calls = []
                def provider(path, form):
                    calls.append(path)
                    return {'id_token':args['identity_token'],'refresh_token':'fresh-fixture-refresh'} if path == '/auth/token' else {}
                with patch.object(client._server.module.apple_auth,'provider',side_effect=provider), \
                     patch.object(client._server.module.browser_worker,'browser_call',return_value={}):
                    self.assertTrue(rpc('account_delete_apple',args)['deleted'])
                self.assertEqual(calls,['/auth/token','/auth/revoke','/auth/revoke'])
                self.assertFalse(client.login('fixture-apple-existing','Fixture-password-123').ok)
                self.assertFalse(client.post('/function/agent_admission',json={}).ok)


if __name__ == '__main__':
    unittest.main()
