"""Real Jac SSO endpoints and real isolated identity/graph storage; Google transport is mocked."""
import json;
import os;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch, AsyncMock, MagicMock }
import from urllib.parse { urlsplit, parse_qs }
import from jaclang.testing.testing { JacTestClient }
import from jaclang.scale.sso.google { GoogleSSOProvider }
import from jaclang.scale.sso.provider { SSOUserInfo }
import from jaclang.scale.sso.oauth_session { challenge_of }
import jaclang.scale.sso.sso_auth as auth;
import jaclang.scale.server.sso_ext as ext;

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post('/function/'+name,json=args);
    assert response.ok;
    return response.data['result'];
}

def begin(client: any, mode: str = 'web') -> dict[str, any] {
    response=client.post('/sso/google/begin',json={'challenge':challenge_of('v'*64),'mode':mode});
    assert response.ok,response.text;
    result=response.data;assert result['ok'];
    query=parse_qs(urlsplit(result['url']).query);
    assert query['scope']==['openid email profile'];
    assert query['redirect_uri']==['https://stack.example/sso/google/callback'];
    assert query['code_challenge_method']==['S256'];
    assert 'access_type' not in query and 'include_granted_scopes' not in query;
    return result;
}

def finish(client: any, state: str, verifier: str = 'v'*64, code: str = 'fixture-code') -> dict[str, any] {
    response=client.post('/sso/google/finish',json={'state':state,'verifier':verifier,'code':code});
    assert response.ok;return response.data;
}

test "Google registration repeat login explicit linking denial and account isolation" {
    with tempfile.TemporaryDirectory(prefix='stack-signin-') as directory {
        config=MagicMock();config.get_sso_config.return_value={'host':'https://stack.example','client_auth_callback_url':'https://stack.example/auth/google','google':{'client_id':'fixture-id','client_secret':'fixture-secret'}};
        agent_config=Path(directory)/'agents.json';agent_config.write_text('{}');
        exchange: any = AsyncMock(return_value={'access_token':'fixture-access'});
        info: any = AsyncMock(return_value=SSOUserInfo(email='one@example.test',external_id='google-one',display_name='One'));
        with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(agent_config)}), patch.object(auth,'get_scale_config',return_value=config), patch.object(ext,'get_scale_config',return_value=config), patch.object(GoogleSSOProvider,'_exchange_code',new=exchange), patch.object(GoogleSSOProvider,'fetch_user',new=info) {
            client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=directory);
            try {
                pending=begin(client);
                assert not finish(client,pending['state'],'wrong'*13)['ok'];exchange.assert_not_awaited();
                signed=finish(client,pending['state']);assert signed['ok'];a=signed['token'];
                assert not finish(client,pending['state'])['ok'];assert exchange.await_count==1;
                client.set_auth_token(a);first=rpc(client,'bootstrap');owner=first['user_id'];
                rpc(client,'save_profile',{'name':'Google isolation marker','role':'Engineer','location':'United States','mode':'Any','notifications':False});
                client.clear_auth();again=finish(client,begin(client)['state']);assert again['ok'];client.set_auth_token(again['token']);
                assert rpc(client,'bootstrap')['user_id']==owner;
                assert rpc(client,'bootstrap')['profile']['name']=='Google isolation marker';
                # Explicitly link a password account with data, without guessing an email or merging roots.
                registered=client.register_user('existing-stack','Fixture-password-1');assert registered.ok;b=registered.data['token'];client.set_auth_token(b);
                original=rpc(client,'bootstrap')['user_id'];
                rpc(client,'save_profile',{'name':'Existing preserved marker','role':'Designer','location':'United States','mode':'Any','notifications':False});
                info.return_value=SSOUserInfo(email='two@example.test',external_id='google-two');
                linked=finish(client,begin(client)['state']);assert linked['ok'];
                client.set_auth_token(linked['token']);assert rpc(client,'bootstrap')['user_id']==original;
                assert rpc(client,'bootstrap')['profile']['name']=='Existing preserved marker';
                client.clear_auth();repeat=finish(client,begin(client)['state']);assert repeat['ok'];client.set_auth_token(repeat['token']);
                assert rpc(client,'bootstrap')['user_id']==original;
                assert client.login('existing-stack','Fixture-password-1').ok;
                # A Google identity already attached to A cannot be attached to B.
                client.set_auth_token(b);info.return_value=SSOUserInfo(email='one@example.test',external_id='google-one');
                assert not finish(client,begin(client)['state'])['ok'];
                client.set_auth_token(a);assert rpc(client,'bootstrap')['profile']['name']=='Google isolation marker';
                # Email equality must not merge an unlinked Google identity into a password account.
                client.clear_auth();info.return_value=SSOUserInfo(email='existing-stack@example.test',external_id='google-unlinked');
                isolated=finish(client,begin(client)['state']);assert isolated['ok'];client.set_auth_token(isolated['token']);
                assert rpc(client,'bootstrap')['user_id']!=original;
                assert rpc(client,'bootstrap')['profile']['name']!='Existing preserved marker';
                # Cancellation/failure cannot create or link an account, and consumes state.
                client.clear_auth();cancelled=begin(client);exchange.side_effect=RuntimeError('fixture denial');
                assert not finish(client,cancelled['state'],code='')['ok'];assert not finish(client,cancelled['state'])['ok'];
                assert not finish(client,'forged-state')['ok'];
                exchange.side_effect=None;
                info.return_value=SSOUserInfo(email='one@example.test',external_id='google-one');
                # Native callback returns text; only the initiating poll capability retrieves the JWT, once.
                native=begin(client,'native');
                response=client.get('/sso/google/callback',params={'state':native['state'],'code':'fixture-native-code'});
                assert response.status_code==200 and 'Sign-in completed.' in response.text;
                assert 'token' not in response.text;
                other=client.post('/sso/google/poll',json={'poll':'x'*43});assert other.ok and not other.data['token'];
                result=client.post('/sso/google/poll',json={'poll':native['poll']});assert result.ok and result.data['ok'];
                client.set_auth_token(result.data['token']);assert rpc(client,'bootstrap')['user_id']==owner;
                replay=client.post('/sso/google/poll',json={'poll':native['poll']});assert replay.ok and not replay.data['token'];
                # New Google identities still require invitation admission when configured.
                agent_config.write_text(json.dumps({'invite_only':True}));client.clear_auth();
                info.return_value=SSOUserInfo(email='invite@example.test',external_id='google-invite');
                invited=finish(client,begin(client)['state']);assert invited['ok'];client.set_auth_token(invited['token']);
                assert not rpc(client,'agent_admission')['admitted'];
                assert 'error' in rpc(client,'agent_accept_invite',{'invite':'not-a-valid-invite'});
                assert not rpc(client,'agent_admission')['admitted'];
            } finally { client.close(); }
        }
    }
}
