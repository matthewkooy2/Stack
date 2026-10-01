"""Attended, guarded worker activation. No secrets or private job content emitted."""
import hashlib, json, os, pathlib, pwd, re, stat, subprocess, sys, time
P = pathlib.Path
HERE = P(__file__).resolve().parent
ROOT = P('/opt/stack')
UNITS = ('stack-worker.service', 'stack-discovery.service')
RESULT_NAME = 'stack-worker-activation-result.json'
report = {'status': 'preflight', 'modelTestMade': False, 'phoneAcceptance': 'pending',
          'historicalRecordsResetOrRequeued': False, 'credentialValuesEmitted': False}
started = False

def save():
    (HERE / RESULT_NAME).write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2), flush=True)

def run(args, **kwargs):
    role=kwargs.pop('role',None)
    if role is None:
        role='database_metadata' if '/usr/bin/psql' in args else pathlib.Path(args[0]).name
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=kwargs.pop('timeout', 40), **kwargs)
    except subprocess.TimeoutExpired:
        report['commandFailure']={'role':role,'errorType':'TimeoutExpired'}
        raise
    if p.returncode:
        # Never save argv (the helper code can use tokens), SQL, or raw stderr.
        kinds=re.findall(r'(?m)^(FileNotFoundError|PermissionError|HTTPError|URLError|TimeoutError|AssertionError|KeyError|ValueError|JSONDecodeError|RuntimeError):',p.stderr or '')
        report['commandFailure']={'role':role,'exitCode':p.returncode,'nestedExceptionTypes':sorted(set(kinds))}
        raise RuntimeError('Command failed; sanitized stage evidence retained')
    return p.stdout.strip()

def sql(query):
    env = {'PATH': '/usr/bin:/bin', 'PGOPTIONS': '-c default_transaction_read_only=on'}
    return run(['/usr/sbin/runuser','-u','postgres','--','/usr/bin/psql','-X','-w','-qAt',
                '-v','ON_ERROR_STOP=1','-d','stack'], input=query, env=env, cwd='/tmp')

QUEUE = r"""
WITH a AS (SELECT id,root_id,arch_type,props->'archetype' f FROM anchors),
r AS (SELECT * FROM a WHERE arch_type='AgentRun'),
t AS (SELECT * FROM a WHERE arch_type='AgentTicket'),
m AS (SELECT * FROM a WHERE arch_type='AgentMemory'),
active AS (SELECT * FROM m WHERE f->'policy'->>'enabled'='true'
 AND coalesce((f->'policy'->>'expires_at')::numeric,0)>=extract(epoch FROM now())
 AND coalesce(f->>'deleted','false')<>'true')
SELECT json_build_object(
 'identities',(SELECT count(*) FROM identity_users),
 'runGroups',(SELECT coalesce(json_agg(g),'[]'::json) FROM
   (SELECT CASE WHEN f->>'kind' IN ('code','prep','jobs','resume','application','network','profile','sync','calendar','linkedin','live') THEN f->>'kind' ELSE 'other' END kind,
   CASE WHEN f->>'status' IN ('queued','running','needs_input','review','blocked','uncertain','completed','cancelled','failed','waiting') THEN f->>'status' ELSE 'other' END status,count(*) count
   FROM r GROUP BY 1,2 ORDER BY 1,2) g),
 'claimableTicketStates',(SELECT count(*) FROM t WHERE f->>'state' IN ('queued','running')),
 'activeRuns',(SELECT count(*) FROM r WHERE f->>'status' NOT IN ('completed','cancelled','failed','needs_input','blocked','uncertain','review')),
 'nonterminalLeaseOrTimer',(SELECT count(*) FROM r WHERE f->>'status' NOT IN ('completed','cancelled','failed') AND
   (coalesce(f->>'lease','')<>'' OR coalesce((f->>'lease_until')::numeric,0)>0 OR coalesce((f->>'next_at')::numeric,0)>0)),
 'activeRunOwnersMissingIdentity',(SELECT count(*) FROM r WHERE f->>'status' IN ('queued','running','waiting') AND NOT EXISTS
   (SELECT 1 FROM identity_users u WHERE replace(u.doc->>'root_id','-','')=replace(r.root_id::text,'-',''))),
 'ticketReferenceMismatch',(SELECT count(*) FROM t WHERE f->>'state' IN ('queued','running') AND NOT EXISTS
   (SELECT 1 FROM r WHERE replace(r.id::text,'-','')=replace(t.f->>'run_id','-','') AND replace(r.root_id::text,'-','')=replace(t.f->>'owner','-',''))),
 'unresolvedActionIntents',(SELECT count(*) FROM a WHERE arch_type='AgentAction' AND f->>'status'='intent'),
 'enabledAutoModelPolicies',(SELECT count(*) FROM active WHERE f->'policy'->>'analyze_top_matches'='true'),
 'enabledGoogleReadPolicies',(SELECT count(*) FROM active WHERE f->'policy'->'actions' ? 'gmail_read'),
 'enabledExternalActionPolicies',(SELECT count(*) FROM active WHERE f->'policy'->'actions' ?| array['send_email','calendar_write','browser_fill','submit_application']),
 'scheduledContactTimers',(SELECT count(*) FROM a WHERE arch_type='AgentContact' AND coalesce((f->>'next_at')::numeric,0)>0 AND f->'data'->>'selected'='true' AND coalesce(f->'data'->>'stopped','false')<>'true'),
 'connectedExternalAccounts',(SELECT count(*) FROM a WHERE arch_type='AgentConnection' AND f->>'state'='connected'),
 'pushDevices',(SELECT count(*) FROM a WHERE arch_type='AgentPushDevice'),
 'queuedNotifications',(SELECT count(*) FROM a WHERE arch_type='AgentNotification' AND f->>'state'='queued'),
 'pendingDiscoveryRequests',(SELECT count(*) FROM a WHERE arch_type='DiscoveryRequest' AND f->>'status' IN ('queued','scheduled','collecting')),
 'discoverySourceGroups',(SELECT coalesce(json_agg(g),'[]'::json) FROM
   (SELECT CASE WHEN f->>'status' IN ('pending','ready','collecting','review','disabled','unavailable','quota','error') THEN f->>'status' ELSE 'other' END status,count(*) count
   FROM a WHERE arch_type='JobSource' GROUP BY 1 ORDER BY 1) g),
 'activeDiscoveryLeases',(SELECT count(*) FROM a WHERE arch_type='JobSource' AND (coalesce(f->>'lease','')<>'' OR coalesce((f->>'lease_until')::numeric,0)>0)),
 'browserDiscoverySources',(SELECT count(*) FROM a WHERE arch_type='JobSource' AND f->>'status' NOT IN ('review','disabled') AND f->'config'->>'renderer'='playwright'),
 'unapprovedActiveDiscoverySources',(SELECT count(*) FROM a WHERE arch_type='JobSource' AND f->>'status' NOT IN ('review','disabled') AND coalesce(f->'config'->>'approved','false')<>'true'),
 'catalogListings',(SELECT count(*) FROM a WHERE arch_type='CatalogJob'),
 'completedModelLogs',(SELECT count(*) FROM a WHERE arch_type='AgentModelLog' AND f->'data'->>'status' IN ('accepted','completed'))
);
"""

def environment_metadata(path, empty_keys):
    # Values remain local; emit only whether optional capabilities are absent.
    lines = path.read_text().splitlines()
    values = dict(line.split('=',1) for line in lines if '=' in line and not line.startswith('#'))
    assert values.get('STACK_WORKER_API') == 'http://127.0.0.1:8000'
    return all(not values.get(key,'').strip() for key in empty_keys)

SERVICE_CHECK = r'''
import json, os, pathlib, subprocess, urllib.request, urllib.error
assert os.geteuid()==999
p=pathlib.Path
checks={}
failures={}
commands={}
def check(name,fn):
    try: checks[name]=bool(fn())
    except Exception as exc:
        checks[name]=False
        failures[name]={'errorType':type(exc).__name__}
        if isinstance(exc,urllib.error.HTTPError): failures[name]['httpStatus']=exc.code
def login():
    q=subprocess.run(['/usr/local/bin/codex','login','status'],capture_output=True,text=True,timeout=20)
    commands['codexLoginStatus']={'exitCode':q.returncode}
    return q.returncode==0 and 'Logged in using ChatGPT' in q.stdout+q.stderr
def compatible():
    q=subprocess.run(['/usr/local/bin/codex','exec','--help'],capture_output=True,text=True,timeout=20)
    commands['codexExecHelp']={'exitCode':q.returncode}
    return q.returncode==0 and all(f in q.stdout for f in ('--ignore-user-config','--ephemeral','--output-schema','--output-last-message','--sandbox','--disable'))
check('chatgptLoginValid',login)
check('codexExecCompatible',compatible)
check('serviceEnvironmentMatches',lambda:os.environ.get('HOME')=='/var/lib/stack-codex' and os.environ.get('CODEX_HOME')=='/var/lib/stack-codex' and os.environ.get('PATH')=='/usr/local/bin:/usr/bin:/bin')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def call(name,args):
    req=urllib.request.Request('http://127.0.0.1:8000/function/'+name,data=json.dumps(args).encode(),headers={'Content-Type':'application/json'})
    with opener.open(req,timeout=20) as resp: return json.load(resp)['data']['result']
def auth_probe(valid):
    auth={'token':p('/opt/stack/storage/agents/worker-token').read_text().strip() if valid else 'invalid-preflight-token',
          'owner':'','id':'','lease':'','event':'preflight_read_only','data':{}}
    # Unsupported event is rejected immediately AFTER token validation and BEFORE
    # owner selection, lease lookup, tracing, or any graph write.
    result=call('agent_trace',auth)
    return result.get('error')==('Unsupported trace event.' if valid else 'Worker authorization required.')
check('agentTokenAcceptedWithoutMutation',lambda:auth_probe(True))
check('invalidTokenRejected',lambda:auth_probe(False))
if CHECK_DISCOVERY:
    check('discoveryTokenAcceptedWithoutSource',lambda:call('discovery_manage',{'token':p('/opt/stack/storage/discovery/worker-token').read_text().strip(),'id':'','action':'preflight-read-only'}).get('error')=='Source not found.')
print(json.dumps({'actualUid':os.geteuid(),'checks':checks,'failureMetadata':failures,'commandMetadata':commands}))
'''

def unit_body(unit):
    body=(ROOT/'deploy'/unit).read_text()
    body=body.replace('User=stack\n','User=stack\nGroup=stack\n')
    body=body.replace('Environment=STACK_JAC_BIN=/usr/local/bin/jac\n','Environment=STACK_JAC_BIN=/usr/local/bin/jac\nEnvironment=PYTHONDONTWRITEBYTECODE=1\nEnvironment=JAC_SCHEMA_REPAIR=detect\n')
    if unit=='stack-discovery.service':
        body=body.replace('ReadWritePaths=/opt/stack/.jac','Environment=HOME=/var/lib/stack\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin\nInaccessiblePaths=/var/lib/stack-codex\nReadWritePaths=/opt/stack/.jac')
    return body

def service_check_command(code,env):
    # runuser/PAM resets HOME. Set the exact worker environment AFTER changing UID.
    return ['/usr/sbin/runuser','-u','stack','--','/usr/bin/env','-i',
            *[key+'='+value for key,value in env.items()],'/usr/bin/python3','-c',code]

def main(agent_only=False):
    global started
    assert os.geteuid()==0
    os.umask(0o077)
    report['phase']='preflight'
    account=pwd.getpwnam('stack')
    assert (account.pw_uid,account.pw_gid,account.pw_shell)==(999,989,'/usr/sbin/nologin')
    for unit in UNITS:
        assert subprocess.run(['/usr/bin/systemctl','is-active','--quiet',unit],capture_output=True).returncode!=0
        path=P('/etc/systemd/system')/unit
        assert not path.is_symlink()
        if path.exists(): assert path.read_text()==unit_body(unit), 'Existing unit differs from prepared unit'
    for unit in ('stack-api.service','stack-gateway.service'):
        assert run(['/usr/bin/systemctl','is-active',unit])=='active'
    if agent_only:
        assert UNITS == ('stack-worker.service',)
        assert subprocess.run(['/usr/bin/systemctl','is-active','--quiet','stack-discovery.service'],capture_output=True).returncode!=0
        report['discoveryActivationRequested']=False
    instructions=ROOT/'AGENTS.md'
    assert instructions.read_text()==P('/home/mkooy/src/Stack-integrate-agent-features-def5e9d-20260930/AGENTS.md').read_text()
    assert not (ROOT/'.agents').exists(), 'Additional live project instructions need review'
    configpath=ROOT/'storage/agents/config.json'
    config_digest=hashlib.sha256(configpath.read_bytes()).hexdigest()
    c=json.loads(configpath.read_text())
    policy_ok=(c.get('provider')=='codex-cli' and bool(c.get('local_cli_owner'))
               and 1<=int(c.get('local_cli_daily_limit',0))<=100 and c.get('certified_adapters')==[]
               and not c.get('sandbox_available') and all(c.get('action_daily_limits',{}).get(k)==0
               for k in ('browser_fill','submit_application','send_email','calendar_write')))
    bound_owner=c.get('local_cli_owner','').replace('-','')
    assert len(bound_owner)==32 and all(ch in '0123456789abcdef' for ch in bound_owner)
    identity_bound=sql("SELECT count(*) FROM identity_users WHERE replace(doc->>'root_id','-','')='"+bound_owner+"';")=='1'
    optional_off=environment_metadata(P('/etc/stack/worker.env'),('OPENAI_API_KEY','MODEL_API_KEY','STACK_BROWSER_URL','STACK_BROWSER_TOKEN','STACK_SANDBOX_URL','STACK_SANDBOX_TOKEN','EXPO_ACCESS_TOKEN','GOOGLE_GMAIL_TOPIC','GOOGLE_GMAIL_SUBSCRIPTION','GOOGLE_APPLICATION_CREDENTIALS'))
    paid_discovery_off=environment_metadata(P('/etc/stack/discovery.env'),('ADZUNA_APP_ID','ADZUNA_APP_KEY','THEIRSTACK_API_KEY','USAJOBS_API_KEY','USAJOBS_EMAIL','GITHUB_TOKEN'))
    configs=[]
    for path in (ROOT/'discovery/sources.json',ROOT/'discovery/employers.json'):
        configs.extend(json.loads(path.read_text()))
    public_sources_ok=all(x.get('renderer')!='playwright' and x.get('adapter') in ('greenhouse','ashby','lever','smartrecruiters','github','github_search','career','html','rss','adzuna','usajobs','theirstack') for x in configs if x.get('approved'))
    queue=json.loads(sql(QUEUE))
    report.update(queueBefore=queue,ownerBindingMatchesSingleIdentity=identity_bound,
                  providerAndExistingLimitValid=policy_ok,optionalCapabilitiesDisabled=optional_off,
                  paidDiscoveryCredentialsAbsent=paid_discovery_off,publicDiscoveryConfigurationSafe=public_sources_ok)
    hold_keys=('claimableTicketStates','activeRuns','nonterminalLeaseOrTimer','activeRunOwnersMissingIdentity','ticketReferenceMismatch','unresolvedActionIntents','enabledAutoModelPolicies','enabledGoogleReadPolicies','enabledExternalActionPolicies','scheduledContactTimers')
    if not agent_only:
        hold_keys+=('pendingDiscoveryRequests','activeDiscoveryLeases','browserDiscoverySources','unapprovedActiveDiscoverySources')
    blockers=[k for k in hold_keys if queue[k]]
    if not all((policy_ok,identity_bound,optional_off)): blockers.append('agent_configuration_safety_check')
    if not agent_only and not all((paid_discovery_off,public_sources_ok)): blockers.append('discovery_configuration_safety_check')
    if blockers:
        report.update(status='held_before_activation',blockers=blockers)
        save();return
    env={'PATH':'/usr/local/bin:/usr/bin:/bin','HOME':'/var/lib/stack-codex','CODEX_HOME':'/var/lib/stack-codex','LANG':'C.UTF-8'}
    check_code=SERVICE_CHECK.replace('if CHECK_DISCOVERY:', 'if '+str(not agent_only)+':')
    report['status']='verifying_service_uid_authentication'
    report['phase']='service_uid_authentication'
    proof=json.loads(run(service_check_command(check_code,env),env=env,cwd='/opt/stack',timeout=80,role='service_uid_authentication_probe'))
    report['serviceIdentityAuthentication']=proof
    save()
    required={'chatgptLoginValid','codexExecCompatible','serviceEnvironmentMatches','agentTokenAcceptedWithoutMutation','invalidTokenRejected'}
    if not agent_only: required.add('discoveryTokenAcceptedWithoutSource')
    assert proof['actualUid']==999 and set(proof['checks'])==required
    assert all(proof['checks'][key] is True for key in required)
    report['phase']='private_file_metadata'
    for path in (P('/var/lib/stack-codex'),P('/var/lib/stack-codex/auth.json'),configpath):
        metadata=path.stat()
        assert not path.is_symlink() and metadata.st_uid==999
        assert stat.S_IMODE(metadata.st_mode)==(0o700 if path.is_dir() else 0o600)
    # Recheck immediately before installing/starting; new phone work stops here.
    report['phase']='final_queue_recheck'
    assert json.loads(sql(QUEUE))==queue, 'Queue metadata changed; review before activation'
    assert hashlib.sha256(configpath.read_bytes()).hexdigest()==config_digest
    before_runs=sql("SELECT md5(coalesce(string_agg(h,'' ORDER BY h),'')) FROM (SELECT md5(row_to_json(a)::text) h FROM anchors a WHERE arch_type='AgentRun') x;")
    report['phase']='unit_installation'
    for unit in UNITS:
        body=unit_body(unit)
        dest=P('/etc/systemd/system')/unit
        if not dest.exists():
            with dest.open('x') as f: f.write(body)
            dest.chmod(0o644)
        else: assert dest.read_text()==body
    report['phase']='systemd_unit_verification'
    run(['/usr/bin/systemd-analyze','verify',*[str(P('/etc/systemd/system')/u) for u in UNITS]])
    report['phase']='systemd_reload_and_start'
    run(['/usr/bin/systemctl','daemon-reload'])
    started=True
    start_at=str(int(time.time()))
    run(['/usr/bin/systemctl','enable','--now',*UNITS])
    # The attended password step has finished; background verification is bounded.
    time.sleep(25)
    report['phase']='worker_health_and_persistence'
    states={}
    for unit in UNITS:
        props=dict(x.split('=',1) for x in run(['/usr/bin/systemctl','show',unit,'--property=User,Group,MainPID,ActiveState,SubState,NRestarts']).splitlines())
        assert props['User']=='stack' and props['ActiveState']=='active' and props['SubState']=='running' and props['NRestarts']=='0'
        assert P('/proc/'+props['MainPID']).stat().st_uid==999
        assert run(['/usr/bin/systemctl','is-enabled',unit])=='enabled'
        log=run(['/usr/bin/journalctl','-u',unit,'--since','@'+start_at,'--no-pager','-o','cat'])
        # Raw logs can contain catalog IDs and are never displayed or saved.
        assert 'waiting for API' not in log and 'waiting for the local API' not in log
        assert 'Traceback (most recent call last)' not in log
        states[unit]=props
    assert hashlib.sha256(configpath.read_bytes()).hexdigest()==config_digest
    after_runs=sql("SELECT md5(coalesce(string_agg(h,'' ORDER BY h),'')) FROM (SELECT md5(row_to_json(a)::text) h FROM anchors a WHERE arch_type='AgentRun') x;")
    assert after_runs==before_runs, 'Run rows changed during startup; inspect aggregate evidence'
    if agent_only:
        assert subprocess.run(['/usr/bin/systemctl','is-active','--quiet','stack-discovery.service'],capture_output=True).returncode!=0
        report['discoveryRemainedOff']=True
    report.update(status='workers_started_phone_acceptance_pending',services=states,queueAfter=json.loads(sql(QUEUE)),
                  existingProviderBindingLimitAndConfigUnchanged=True,historicalRunRowsUnchanged=True)
    save()

def execute(agent_only=False):
    try:
        main(agent_only=agent_only)
        return 0
    except BaseException as e:
        rollback_success=False
        if started:
            rollback=subprocess.run(['/usr/bin/systemctl','disable','--now',*UNITS],capture_output=True)
            report['rollbackExitCode']=rollback.returncode
            rollback_success=rollback.returncode==0
        report.update(status='stopped',errorType=type(e).__name__,rollbackAttempted=started,
                      workersStoppedAfterFailure=rollback_success,privateErrorDetailsSuppressed=True)
        save()
        return 1

if __name__=='__main__':
    sys.exit(execute())
