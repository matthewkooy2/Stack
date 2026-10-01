"""Use existing PG16 in a private throwaway socket, never the live Stack DB.
No TCP listeners, sudo, software installation, credentials or service changes.
"""
import ast,contextlib,json,os,pathlib,pwd,re,subprocess,sys,tempfile,time,unittest,uuid
import browser_preflight as guard
import install_stack_browser as installer
P=pathlib.Path
HERE=P(__file__).resolve().parent
PG=P('/usr/lib/postgresql/16/bin')
OWNER='11111111111111111111111111111111'
OTHER='22222222222222222222222222222222'
BIN_ENV={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'}
SOCKET=None

def sql(query):
    assert SOCKET and str(SOCKET).startswith('/tmp/stack-browser-guard-test-')
    q=subprocess.run([str(PG/'psql'),'-h',str(SOCKET),'-p','5432','-U',pwd.getpwuid(os.geteuid()).pw_name,'-d','postgres','-X','-w','-qAt','-v','ON_ERROR_STOP=1'],
        input=query,capture_output=True,text=True,timeout=15,env=BIN_ENV)
    if q.returncode:raise AssertionError('Synthetic SQL failure: '+q.stderr)
    return q.stdout.strip()

def literal(value):return "'"+json.dumps(value,separators=(',',':')).replace("'","''")+"'::jsonb"

def add(kind,fields,owner=OWNER):
    identity=str(uuid.uuid4())
    sql("INSERT INTO anchors VALUES ('"+identity+"','"+str(uuid.UUID(owner))+"','"+kind+"',"+literal({'archetype':fields})+");")
    return identity

def policy(**changes):
    value={'enabled':True,'actions':['model','browser_fill','send_email','submit_application','calendar_write'],
           'domains':['example.test'],'daily_limits':{'browser_fill':5,'send_email':5,'submit_application':5,'calendar_write':5},
           'expires_at':time.time()+86400,'followup_limit':0,'followup_days':7,'analyze_top_matches':False}
    value.update(changes);return value

def evaluate(quotas=None,certified=()):
    q=json.loads(sql(guard.source_queue_sql(installer.stack.QUEUE)))
    rows=json.loads(sql(guard.policy_sql(OWNER)))
    metadata=guard.effective_policy_metadata(rows,quotas or dict.fromkeys(guard.EXTERNAL,0),certified)
    return q,metadata,guard.blockers(q,metadata)

class SqlGuardTests(unittest.TestCase):
    def setUp(self):
        sql('TRUNCATE anchors,identity_users; INSERT INTO identity_users VALUES ('+literal({'root_id':OWNER})+');')
    def test_owner_selected_external_permissions_zero_operator_quota_allow_setup(self):
        add('AgentMemory',{'policy':policy(),'deleted':False})
        q,m,blocks=evaluate()
        self.assertEqual(q['enabledExternalActionPolicies'],1)
        self.assertEqual(blocks,[])
        self.assertFalse(m['anyExternalDispatchPotential'])
        self.assertTrue(m['activePolicyMetadata'][0]['boundToLocalModelOwner'])
        self.assertFalse(m['standingPermissionsModified'])
    def test_blocked_and_needs_input_histories_are_not_requeued(self):
        for kind,status in [('code','needs_input'),('prep','blocked'),('prep','blocked')]:
            add('AgentRun',{'kind':kind,'status':status,'lease':'','lease_until':0,'next_at':0})
        q,m,blocks=evaluate();self.assertEqual(blocks,[]);self.assertEqual(q['activeRuns'],0)
    def test_each_existing_agent_kind_queued_requires_scope_review(self):
        for kind in ('resume','prep','jobs','network','linkedin','profile','code','application','calendar','sync','live'):
            with self.subTest(kind=kind):
                sql('TRUNCATE anchors;');add('AgentRun',{'kind':kind,'status':'queued','lease':'','lease_until':0,'next_at':0})
                self.assertIn('activeRuns',evaluate()[2])
    def test_unknown_queued_kind_fails_closed(self):
        add('AgentRun',{'kind':'future_unknown_action','status':'queued','lease':'','lease_until':0,'next_at':0})
        q,m,blocks=evaluate();self.assertIn('activeRuns',blocks);self.assertEqual(q['runGroups'][0]['kind'],'other')
    def test_review_is_paused_and_external_quota_still_denies_dispatch(self):
        add('AgentRun',{'kind':'network','status':'review','lease':'','lease_until':0,'next_at':0})
        add('AgentMemory',{'policy':policy(),'deleted':False})
        q,m,blocks=evaluate();self.assertEqual(blocks,[]);self.assertFalse(m['anyExternalDispatchPotential'])
    def test_auto_model_requires_model_selection_and_analysis_flag(self):
        add('AgentMemory',{'policy':policy(actions=['send_email'],analyze_top_matches=True),'deleted':False})
        self.assertEqual(evaluate()[2],[])
        sql('TRUNCATE anchors;');add('AgentMemory',{'policy':policy(analyze_top_matches=True),'deleted':False})
        self.assertIn('enabledAutoModelPolicies',evaluate()[2])
    def test_expired_and_deleted_policy_do_not_activate_actions(self):
        add('AgentMemory',{'policy':policy(expires_at=time.time()-1),'deleted':False})
        add('AgentMemory',{'policy':policy(),'deleted':True})
        q,m,blocks=evaluate();self.assertEqual(blocks,[]);self.assertEqual(m['activePolicyMetadata'],[])
    def test_gmail_selection_alone_does_not_schedule_sync(self):
        add('AgentMemory',{'policy':policy(actions=['gmail_read']),'deleted':False})
        self.assertEqual(evaluate()[2],[])
        add('AgentConnection',{'provider':'google','state':'connected','scopes':[]})
        self.assertIn('scheduledGoogleSyncPolicies',evaluate()[2])
    def test_foreign_google_connection_does_not_schedule_this_owner(self):
        add('AgentMemory',{'policy':policy(actions=['gmail_read']),'deleted':False})
        add('AgentConnection',{'provider':'google','state':'connected','scopes':[]},owner=OTHER)
        self.assertEqual(evaluate()[2],[])
    def test_selected_future_contact_timer_is_held_without_private_content(self):
        add('AgentContact',{'next_at':time.time()+3600,'data':{'selected':True,'stopped':False},'followups':0})
        self.assertEqual(evaluate()[2],[])
        add('AgentMemory',{'policy':policy(followup_limit=1),'deleted':False})
        self.assertIn('scheduledFollowupTimers',evaluate()[2])
    def test_pending_push_is_held_only_with_destination_device(self):
        add('AgentNotification',{'state':'queued'})
        self.assertEqual(evaluate()[2],[])
        add('AgentPushDevice',{'key':'synthetic','sealed':'synthetic'})
        self.assertIn('pending_push_delivery',evaluate()[2])
    def test_ticket_and_lease_and_unresolved_intent_are_each_held(self):
        for kind,fields,key in [('AgentTicket',{'owner':OWNER,'run_id':OTHER,'state':'queued'},'claimableTicketStates'),
                               ('AgentRun',{'kind':'code','status':'running','lease':'synthetic','lease_until':time.time()+5,'next_at':0},'activeRunLeaseOrTimer'),
                               ('AgentAction',{'status':'intent'},'unresolvedActionIntents')]:
            sql('TRUNCATE anchors;');add(kind,fields);self.assertIn(key,evaluate()[2])
    def test_retained_paused_lease_is_metadata_only_and_never_requeued(self):
        add('AgentRun',{'kind':'code','status':'needs_input','lease':'synthetic','lease_until':time.time()+5,'next_at':0})
        q,m,blocks=evaluate();self.assertEqual(q['nonterminalLeaseOrTimer'],1);self.assertEqual(blocks,[])
        self.assertEqual(sql("SELECT props->'archetype'->>'status' FROM anchors WHERE arch_type='AgentRun';"),'needs_input')
    def test_policy_mapping_is_not_mistaken_for_true_permissions(self):
        add('AgentMemory',{'policy':policy(actions={'send_email':False}),'deleted':False})
        self.assertIn('active_policy_schema_invalid',evaluate()[2])
    def test_unknown_action_and_non_boolean_policy_fail_closed(self):
        for changes in ({'actions':['unknown_external']},{'enabled':'true'},{'daily_limits':{'send_email':False}},{'expires_at':'not-a-number'}):
            sql('TRUNCATE anchors;');add('AgentMemory',{'policy':policy(**changes),'deleted':False})
            self.assertIn('active_policy_schema_invalid',evaluate()[2])
    def test_active_owner_identity_is_required_without_inactive_history_investigation(self):
        add('AgentMemory',{'policy':policy(),'deleted':False},owner=OTHER)
        self.assertIn('active_policy_owner_missing_identity',evaluate()[2])
    def test_live_dispatch_upper_bound_obeys_user_operator_and_adapter_gates(self):
        add('AgentMemory',{'policy':policy(),'deleted':False})
        q,m,_=evaluate({'send_email':1,'submit_application':1})
        actions=m['activePolicyMetadata'][0]['externalActions']
        self.assertTrue(actions['send_email']['dispatchCouldBePermitted'])
        self.assertFalse(actions['submit_application']['dispatchCouldBePermitted'])
        self.assertTrue(evaluate({'submit_application':1},['greenhouse'])[1]['anyExternalDispatchPotential'])
        sql('TRUNCATE anchors;');add('AgentMemory',{'policy':policy(daily_limits={}),'deleted':False})
        self.assertFalse(evaluate({'send_email':1})[1]['anyExternalDispatchPotential'])
    def test_discovery_backlog_is_reported_but_not_activated_or_mutated(self):
        for _ in range(266):add('DiscoveryRequest',{'status':'scheduled','kind':'search'})
        q,m,blocks=evaluate();self.assertEqual(q['pendingDiscoveryRequests'],266);self.assertEqual(blocks,[])
        self.assertEqual(sql("SELECT count(*) FROM anchors WHERE arch_type='DiscoveryRequest';"),'266')
    def test_no_private_destinations_identifiers_or_policy_payload_in_report(self):
        add('AgentMemory',{'policy':policy(),'deleted':False})
        q,m,blocks=evaluate();raw=json.dumps(m)
        self.assertNotIn('example.test',raw);self.assertNotIn(OWNER,raw);self.assertNotIn('expires_at',raw)

def main():
    global SOCKET
    with tempfile.TemporaryDirectory(prefix='stack-browser-guard-test-') as tmp:
        root=P(tmp);SOCKET=root/'socket';SOCKET.mkdir(mode=0o700);data=root/'data'
        q=subprocess.run([str(PG/'initdb'),'-D',str(data),'--auth-local=trust','--auth-host=reject','--no-locale','--no-sync'],capture_output=True,text=True,env=BIN_ENV,timeout=20)
        assert q.returncode==0,'Existing PostgreSQL test initialization failed'
        q=subprocess.run([str(PG/'pg_ctl'),'-D',str(data),'-l',str(root/'postgres-test.log'),'-o',"-c listen_addresses='' -c unix_socket_directories="+str(SOCKET)+' -c max_connections=10 -c shared_buffers=16MB','-w','start'],capture_output=True,text=True,env=BIN_ENV,timeout=20)
        assert q.returncode==0,'Isolated PostgreSQL test start failed'
        try:
            sql('CREATE TABLE anchors (id uuid,root_id uuid,arch_type text,props jsonb); CREATE TABLE identity_users(doc jsonb);')
            result=unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(SqlGuardTests))
            report={'testsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'passed':result.wasSuccessful(),
                    'existingPostgres16Used':True,'syntheticActualSchemaShapes':True,'productionDatabaseAccessed':False,
                    'tcpListenersCreated':False,'privilegedCommandsRun':False,'standingPermissionsModified':False}
            (HERE/'offline-preflight-postgres-result.json').write_text(json.dumps(report,indent=2)+'\n')
            return 0 if result.wasSuccessful() else 1
        finally:
            q=subprocess.run([str(PG/'pg_ctl'),'-D',str(data),'-m','fast','-w','stop'],capture_output=True,text=True,env=BIN_ENV,timeout=20)
            assert q.returncode==0,'Throwaway PostgreSQL test cleanup failed'

if __name__=='__main__':sys.exit(main())
