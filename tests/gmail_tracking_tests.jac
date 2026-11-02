"""One-button Gmail setup against isolated persisted accounts; only Google transport is mocked."""
import json;
import os;
import tempfile;
import time;
import sys;
import from pathlib { Path }
import from unittest.mock { patch }
import from urllib.parse { urlsplit, parse_qs }
import from cryptography.fernet { Fernet }
import from jaclang.testing.testing { JacTestClient }
import from agents.google { SCOPES }

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    response=client.post('/function/'+name,json=args);
    assert response.ok,response.text;
    return response.data['result'];
}
def begin(client: any, capabilities: list[str], native: bool = True) -> str {
    pending=rpc(client,'agent_google_start_native' if native else 'agent_google_start',{'capabilities':capabilities});
    query=parse_qs(urlsplit(pending['url']).query);
    assert query['scope']==[' '.join(SCOPES[cap] for cap in capabilities)];
    return query['state'][0];
}
def email_feature(client: any) -> dict[str, any] {
    return [f for f in rpc(client,'bootstrap')['agents']['features'] if f['key']=='email'][0];
}
def google_runtime() -> any {
    # JacTestClient loads the app in its own package; patch that transport binding.
    modules=[module for (name,module) in sys.modules.items() if name.startswith('_jac_app_') and name.endswith('.core.automation')];
    assert len(modules)==1;
    return modules[0];
}

test "Gmail consent enables tracking without rules and disconnect stops leased reads" {
    with tempfile.TemporaryDirectory(prefix='stack-gmail-') as directory {
        config=Path(directory)/'agents.json';config.write_text('{}');
        with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(config),'STACK_AGENT_WORKER_TOKEN':'gmail-test-worker',
            'STACK_CONNECTION_KEY':Fernet.generate_key().decode(),'GOOGLE_CLIENT_ID':'fixture',
            'GOOGLE_REDIRECT_URI':'https://stack.example/oauth/google'}) {
            client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=directory);
            try {
                signed=client.register_user('gmail-tracking','Fixture-password-1');assert signed.ok;
                account=signed.data['token'];client.set_auth_token(account);
                rpc(client,'bootstrap');before=rpc(client,'agent_settings')['policy'];
                automation=google_runtime();
                state=begin(client,['read']);
                # Another account cannot finish this request or consume its one-time state.
                other=client.register_user('gmail-other','Fixture-password-1');assert other.ok;client.set_auth_token(other.data['token']);
                with patch.object(automation,'exchange') as exchange {
                    assert 'error' in rpc(client,'agent_google_finish',{'state':state,'code':'wrong-owner'});
                    exchange.assert_not_called();
                }
                client.set_auth_token(account);
                # Merely opening sign-in never enables tracking.
                assert email_feature(client)['state']=='setup';
                tokens={'access_token':'fixture-access','refresh_token':'fixture-refresh','scope':SCOPES['read'],'expires_at':time.time()+3600};
                with patch.object(automation,'exchange',return_value=tokens) as exchange {
                    saved=rpc(client,'agent_google_finish',{'state':state,'code':'fixture-code'});
                    assert 'error' not in saved,saved;
                    assert saved['connections'][0]['tracking'];assert saved['policy']==before;
                    assert 'error' in rpc(client,'agent_google_finish',{'state':state,'code':'fixture-code'});
                    assert exchange.call_count==1;
                }
                assert email_feature(client)['state']=='ready';
                # Tracking also survives an expired/disabled outbound policy saved by an older client.
                expired={**before,'enabled':False,'actions':['send_email'],'expires_at':time.time()-86400};
                assert 'error' not in rpc(client,'agent_save_policy',{'policy':expired});
                assert email_feature(client)['state']=='ready';
                client.clear_auth();
                assert rpc(client,'agent_schedule',{'token':'gmail-test-worker'})['scheduled']==1;
                claim=rpc(client,'agent_claim',{'token':'gmail-test-worker'});assert claim['step']=='sync';
                auth={'token':'gmail-test-worker',**{k:claim[k] for k in ['id','owner','lease']}};
                connection=rpc(client,'agent_worker_connection',auth);assert connection['tokens']['access_token']=='fixture-access';
                client.set_auth_token(account);
                assert rpc(client,'agent_settings')['policy']==expired;
                rpc(client,'agent_disconnect',{'id':saved['connections'][0]['id']});
                assert email_feature(client)['state']=='setup';
                client.clear_auth();
                assert 'error' in rpc(client,'agent_worker_connection',auth);
                assert rpc(client,'agent_schedule',{'token':'gmail-test-worker'})['scheduled']==0;
                client.set_auth_token(other.data['token']);assert not rpc(client,'agent_settings')['connections'];
            } finally { client.close(); }
        }
    }
}

test "partial consent and send-only consent cannot silently enable Gmail tracking" {
    with tempfile.TemporaryDirectory(prefix='stack-gmail-denied-') as directory {
        config=Path(directory)/'agents.json';config.write_text('{}');
        with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(config),'STACK_CONNECTION_KEY':Fernet.generate_key().decode(),
            'GOOGLE_CLIENT_ID':'fixture','GOOGLE_REDIRECT_URI':'https://stack.example/oauth/google'}) {
            client=JacTestClient.from_file(str(Path('main.jac').resolve()),base_path=directory);
            try {
                signed=client.register_user('gmail-denied','Fixture-password-1');assert signed.ok;client.set_auth_token(signed.data['token']);
                automation=google_runtime();
                state=begin(client,['read'],False);
                with patch.object(automation,'exchange',return_value={'scope':SCOPES['send']}) {
                    assert 'error' in rpc(client,'agent_google_finish',{'state':state,'code':'partial'});
                    assert not rpc(client,'agent_settings')['connections'];
                }
                # Incremental Google consent can include an old read grant; requesting send alone isn't a tracking opt-in.
                state=begin(client,['send']);
                tokens={'access_token':'fixture','refresh_token':'fixture','scope':SCOPES['read']+' '+SCOPES['send']};
                with patch.object(automation,'exchange',return_value=tokens) {
                    saved=rpc(client,'agent_google_finish',{'state':state,'code':'send-only'});
                    assert 'error' not in saved,saved;
                    assert not saved['connections'][0]['tracking'];
                    assert not saved['policy']['enabled'];assert not saved['policy']['actions'];
                }
                assert email_feature(client)['state']=='setup';
                # A later explicit read connection activates the existing connection, without creating a duplicate.
                state=begin(client,['read'],False);
                with patch.object(automation,'exchange',return_value=tokens) {
                    saved=rpc(client,'agent_google_finish',{'state':state,'code':'read'});
                    assert len(saved['connections'])==1 and saved['connections'][0]['tracking'];
                }
                assert email_feature(client)['state']=='ready';
            } finally { client.close(); }
        }
    }
}
