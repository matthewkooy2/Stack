"""Synthetic unit tests only. Never starts Docker, sudo, services or networking."""
import contextlib,hashlib,importlib,json,os,pathlib,signal,subprocess,sys,tempfile,unittest
from unittest.mock import patch,Mock
import browser_policy as policy
import browser_runtime as runtime
import install_stack_browser as installer
P=pathlib.Path

def evaluate(rows,address,port,proto='tcp',state='NEW',original=None):
    """Evaluate the actual emitted rule order, independent of policy.allowed."""
    import ipaddress
    for row in rows:
        def value(key):return row[row.index(key)+1] if key in row else None
        if value('--ctstate') and state not in value('--ctstate').split(','):continue
        if value('-p') and value('-p')!=proto:continue
        if value('-d') and ipaddress.ip_address(address) not in ipaddress.ip_network(value('-d')):continue
        if value('--dport') and int(value('--dport'))!=port:continue
        if value('--ctorigdst') and (not original or original!=(value('--ctorigdst'),int(value('--ctorigdstport')))):continue
        return value('-j')=='ACCEPT'
    raise AssertionError('No terminal rule')

class PolicyTests(unittest.TestCase):
    def test_actual_rules_block_all_private_ranges(self):
        rows=policy.rules(['172.21.32.1'])
        for cidr in policy.BLOCKED:
            import ipaddress
            address=str(ipaddress.ip_network(cidr)[1])
            with self.subTest(cidr=cidr):self.assertFalse(evaluate(rows,address,443))
    def test_gateway_api_database_loopback_and_tailnet_denied(self):
        for _,address,port in policy.negative_targets('172.30.254.1'):
            self.assertFalse(evaluate(policy.rules(['172.21.32.1']),address,port))
    def test_dns_exception_is_exact_ip_protocol_port(self):
        rows=policy.rules(['172.21.32.1'])
        for proto in ('tcp','udp'):self.assertTrue(evaluate(rows,'172.21.32.1',53,proto))
        self.assertFalse(evaluate(rows,'172.21.32.1',443))
        self.assertFalse(evaluate(rows,'172.21.32.2',53))
    def test_embedded_dns_original_tuple_only(self):
        rows=policy.rules(['172.21.32.1'])
        self.assertTrue(evaluate(rows,'127.0.0.11',45001,'udp',original=('127.0.0.11',53)))
        self.assertFalse(evaluate(rows,'127.0.0.11',45001,'udp',original=('127.0.0.11',443)))
        self.assertFalse(evaluate(rows,'127.0.0.11',45001,'udp'))
    def test_public_https_only_and_authenticated_control_replies(self):
        rows=policy.rules(['172.21.32.1'])
        self.assertTrue(evaluate(rows,'1.1.1.1',443))
        self.assertFalse(evaluate(rows,'1.1.1.1',80))
        self.assertFalse(evaluate(rows,'1.1.1.1',443,'udp'))
        self.assertTrue(evaluate(rows,'172.30.254.1',50001,state='ESTABLISHED'))
    def test_namespace_commands_never_touch_host_chains(self):
        calls=[]
        policy.install(999,['172.21.32.1'],lambda args,role:calls.append(args))
        self.assertEqual(calls[-1][-5:],['-I','OUTPUT','1','-j',policy.CHAIN])
        self.assertTrue(all('--net=/proc/999/ns/net' in row for row in calls))
        self.assertTrue(all('-F' not in row and 'DOCKER-USER' not in row for row in calls))
    def test_connection_failure_without_kernel_reject_is_not_proof(self):
        with patch.object(policy,'denied_packets',return_value=0):
            with self.assertRaises(AssertionError):policy.prove('fake',999,'172.30.254.1',lambda *a,**k:json.dumps({'uid':1000,'connected':False}))
    def test_unexpected_success_fails_even_with_reject_counter(self):
        with patch.object(policy,'denied_packets',side_effect=[0,1]):
            with self.assertRaises(AssertionError):policy.prove('fake',999,'172.30.254.1',lambda *a,**k:json.dumps({'uid':1000,'connected':True}))
    def test_public_tls_failure_fails_proof(self):
        counters=iter(range(100));count=0
        def response(args,**kw):
            target=json.loads(args[-1]);return json.dumps({'uid':1000,'connected':False})
        with patch.object(policy,'denied_packets',side_effect=lambda *a:next(counters)):
            with self.assertRaises(AssertionError):policy.prove('fake',999,'172.30.254.1',response)

class RuntimeTests(unittest.TestCase):
    def setUp(self):runtime.metadata={}
    def main_context(self,**overrides):
        network={'dnsServers':['172.21.32.1'],'networkName':'fake','gateway':'172.30.254.1','browserAddress':'172.30.254.2','probeAddress':'172.30.254.3'}
        stack=contextlib.ExitStack()
        stack.enter_context(patch.object(runtime.os,'geteuid',return_value=0))
        stack.enter_context(patch.object(runtime.os,'umask'))
        stack.enter_context(patch.object(runtime,'CONFIG',Mock(read_text=Mock(return_value=json.dumps(network)))))
        stack.enter_context(patch.object(runtime,'IMAGE',Mock(read_text=Mock(return_value='sha256:'+'a'*64))))
        stack.enter_context(patch.object(runtime,'record'))
        stack.enter_context(patch.object(runtime.signal,'signal'))
        stack.enter_context(patch.object(runtime.subprocess,'run',return_value=Mock(returncode=1)))
        stack.enter_context(patch.object(runtime,'inspect_container',return_value=999))
        stack.enter_context(patch.object(runtime,'controlled_environment',return_value={'STACK_BROWSER_TOKEN':'x'*64,'STACK_BROWSER_SESSION_KEY':'synthetic'}))
        return stack
    def test_policy_failure_cleans_owned_container_and_never_opens_gate(self):
        with self.main_context(),patch.object(runtime,'run',return_value='id') as run,patch.object(runtime.policy,'install',side_effect=RuntimeError('synthetic')),patch.object(runtime,'cleanup_owned') as clean:
            with self.assertRaises(RuntimeError):runtime.main(probe=True)
            clean.assert_called_once()
            self.assertFalse(any(k.get('role')=='chromium_launch_gate_open' for _,k in run.call_args_list))
    def test_proof_failure_cleans_container_and_never_opens_gate(self):
        with self.main_context(),patch.object(runtime,'run',return_value='id') as run,patch.object(runtime.policy,'install'),patch.object(runtime.policy,'prove',side_effect=AssertionError('synthetic')),patch.object(runtime,'cleanup_owned') as clean:
            with self.assertRaises(AssertionError):runtime.main()
            clean.assert_called_once()
            self.assertFalse(any(k.get('role')=='chromium_launch_gate_open' for _,k in run.call_args_list))
    def test_launch_timeout_still_attempts_owned_cleanup(self):
        with self.main_context(),patch.object(runtime,'run',side_effect=subprocess.TimeoutExpired('synthetic',1)),patch.object(runtime,'cleanup_owned') as clean:
            with self.assertRaises(subprocess.TimeoutExpired):runtime.main(probe=True)
            clean.assert_called_once()
    def test_signal_stop_propagates_through_finally_cleanup(self):
        def stop(*a,**kw):runtime.request_stop(signal.SIGTERM,None)
        with self.main_context(),patch.object(runtime,'run',return_value='id'),patch.object(runtime.policy,'install'),patch.object(runtime.policy,'prove',side_effect=stop),patch.object(runtime,'cleanup_owned') as clean:
            with self.assertRaises(runtime.StopRequested):runtime.main()
            clean.assert_called_once()
    def test_real_sigterm_enters_controller_cleanup(self):
        real_signal=signal.signal;old=signal.getsignal(signal.SIGTERM)
        try:
            real_signal(signal.SIGTERM,runtime.request_stop)
            def stop(*a,**kw):os.kill(os.getpid(),signal.SIGTERM)
            with self.main_context(),patch.object(runtime,'run',return_value='id'),patch.object(runtime.policy,'install'),patch.object(runtime.policy,'prove',side_effect=stop),patch.object(runtime,'cleanup_owned') as clean:
                with self.assertRaises(runtime.StopRequested):runtime.main()
                clean.assert_called_once()
        finally:real_signal(signal.SIGTERM,old)
    def test_stop_never_stops_an_unrelated_container(self):
        with patch.object(runtime.subprocess,'run',return_value=Mock(returncode=0,stdout='another-attempt\n',stderr='')) as run:
            runtime.cleanup_owned('fake','this-attempt')
            self.assertEqual(run.call_count,1)
            self.assertTrue(runtime.metadata['cleanup']['ownershipMismatch'])
    def test_failed_stop_is_reported_not_claimed_success(self):
        replies=[Mock(returncode=0,stdout='ours\n',stderr=''),Mock(returncode=1),Mock(returncode=0,stderr='')]
        with patch.object(runtime.subprocess,'run',side_effect=replies):runtime.cleanup_owned('fake','ours')
        self.assertEqual(runtime.metadata['cleanup']['stopExitCode'],1)
        self.assertFalse(runtime.metadata['cleanup']['containerAbsent'])
    def test_successful_stop_waits_for_auto_removal(self):
        replies=[Mock(returncode=0,stdout='ours\n',stderr=''),Mock(returncode=0),Mock(returncode=0),Mock(returncode=1,stderr='No such container')]
        with patch.object(runtime.subprocess,'run',side_effect=replies),patch.object(runtime.time,'sleep'):
            runtime.cleanup_owned('fake','ours')
        self.assertTrue(runtime.metadata['cleanup']['containerAbsent'])
    def test_no_private_env_values_in_docker_argv(self):
        p={'networkName':'fake','dnsServers':['172.21.32.1']}
        args=runtime.container_parameters('fake','172.30.254.2','sha256:'+'a'*64,p,attempt='test')
        self.assertIn('STACK_BROWSER_TOKEN',args)
        self.assertNotIn('--privileged',args)
        self.assertNotIn('--volume',args)
        self.assertIn('seccomp=/etc/stack/browser-seccomp.json',args)
        probe=runtime.container_parameters('fake','172.30.254.3','sha256:'+'a'*64,p,probe=True)
        self.assertNotIn('--env',probe)
        self.assertNotIn('--publish',probe)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        installer.REPORT={'status':'test'};installer.ENV_BACKUP={}
        installer.CONFIG_MUTATED=False;installer.BROWSER_STARTED=False
    def test_environment_changes_only_two_keys(self):
        old=b'# comment\nHOME=/preserved\nSTACK_BROWSER_URL=\nSTACK_BROWSER_TOKEN=\nOTHER=synthetic\n'
        new=installer.replace_browser_env(old,'synthetic-token')
        self.assertEqual(new,b'# comment\nHOME=/preserved\nSTACK_BROWSER_URL=http://127.0.0.1:8011\nSTACK_BROWSER_TOKEN=synthetic-token\nOTHER=synthetic\n')
    def test_duplicate_keys_fail_before_write(self):
        with self.assertRaises(AssertionError):installer.replace_browser_env(b'STACK_BROWSER_TOKEN=\nSTACK_BROWSER_TOKEN=\n','synthetic')
    def test_apt_removal_and_unrelated_install_upgrade_are_rejected(self):
        for text in ('Remv postgresql-16 [16.15]\n','Inst nginx (1 Ubuntu)\n','Inst iptables [1.8.9] (1.8.10 Ubuntu)\n'):
            self.assertFalse(installer.apt_plan_allowed(text,{'docker-ce'}))
        self.assertTrue(installer.apt_plan_allowed('Inst docker-ce (29 Docker)\nInst iptables (1 Ubuntu)\n',{'docker-ce'}))
    def test_apt_architecture_annotation_is_not_an_installed_version(self):
        actual_shape='Inst iptables (1.8.10-3ubuntu2 Ubuntu:24.04/noble [amd64])\nInst libip4tc2 (1.8.10-3ubuntu2 Ubuntu:24.04/noble [amd64])\n'
        self.assertTrue(installer.apt_plan_allowed(actual_shape,{'docker-ce'}))
        true_upgrade='Inst iptables [1.8.9-2] (1.8.10-3ubuntu2 Ubuntu:24.04/noble [amd64])\n'
        self.assertFalse(installer.apt_plan_allowed(true_upgrade,{'docker-ce'}))
        self.assertFalse(installer.apt_plan_allowed('Inst unrelated (1 Ubuntu:24.04/noble [amd64])\n',{'docker-ce'}))
    def test_actual_captured_apt_plan_contains_only_allowed_new_packages(self):
        path=P(__file__).parent.parent/'docker-package-plan-simulation-lines.txt'
        plan=path.read_text()
        packages=json.loads((P(__file__).parent/'docker-package-manifest.json').read_text())['packages']
        metadata=installer.apt_plan_metadata(plan,packages)
        self.assertTrue(metadata['allowed'])
        self.assertEqual(len(metadata['changes']),12)
        self.assertTrue(all(row['operation']=='install' and row['allowed'] for row in metadata['changes']))
        self.assertIn('[amd64]',plan)
    def test_only_recognized_preinstall_hold_can_cross_manifest_versions(self):
        old={'preparedBundleSha256':next(iter(installer.KNOWN_PREINSTALL_MANIFESTS)),
             'status':'held','phase':'signed_apt_update','errorType':'Held'}
        self.assertTrue(installer.known_preinstall_hold(old))
        for changes in ({'phase':'installing_pinned_docker_packages'},{'status':'failed'},{'preparedBundleSha256':'f'*64},
                        {'dockerPackagesVerified':True},{'attachmentCommitted':True},{'browserHealthy':True},
                        {'realContainerEgressProof':{'passed':True}},{'commandFailure':{'exitCode':1}}):
            self.assertFalse(installer.known_preinstall_hold({**old,**changes}))
    def test_preinstall_resume_rejects_new_runtime_state(self):
        with patch.object(installer.shutil,'which',return_value='/usr/bin/docker'):
            with self.assertRaises(AssertionError):installer.assert_preinstall_state()
    def test_signed_index_resume_does_not_write_repo_or_update_indexes(self):
        manifest=json.loads((P(__file__).parent/'docker-package-manifest.json').read_text())
        repo_body=b'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/stack-docker.asc\n'
        key=(P(__file__).parent/'docker-repository.asc').read_bytes()
        repo=Mock(exists=Mock(return_value=True),is_symlink=Mock(return_value=False),read_bytes=Mock(return_value=repo_body))
        keypath=Mock(exists=Mock(return_value=True),is_symlink=Mock(return_value=False),read_bytes=Mock(return_value=key))
        original_path=installer.P;roles=[]
        def path(value):
            if value=='/etc/apt/keyrings/stack-docker.asc':return keypath
            if value=='/etc/apt/sources.list.d/stack-docker.sources':return repo
            return original_path(value)
        def command(args,role,**kwargs):
            roles.append(role)
            if role=='signed_package_metadata':
                name=args[-1].split('=')[0];item=manifest['packages'][name]
                return 'Version: '+item['version']+'\nSHA256: '+item['sha256']+'\nFilename: '+item['filename']+'\n'
            if role=='package_installation_dry_run':return 'Inst docker-ce (29 Docker [amd64])\n'
            return ''
        with patch.object(installer,'RESUME_SIGNED_INDEXES',True),patch.object(installer,'P',side_effect=path),patch.object(installer,'checkpoint'),patch.object(installer,'save'),patch.object(installer,'command',side_effect=command),patch.object(installer,'run',return_value=Mock(returncode=1,stdout='')),patch.object(installer.shutil,'which',return_value=None),patch.object(installer,'verify_packages'),patch.object(installer,'active',return_value=True),patch.object(installer,'atomic') as write:
            installer.docker_install(manifest,recognized=True)
            write.assert_not_called()
        self.assertNotIn('signed_repository_update',roles)
        self.assertNotIn('public_repository_key_metadata',roles)
        self.assertIn('pinned_runtime_installation',roles)
        self.assertTrue(installer.REPORT['existingRepositoryAndSignedIndexesReused'])
    def test_unexpected_queue_holds_before_mutation(self):
        q={key:0 for key in installer.HOLD};q['claimableTicketStates']=1
        q.update(scheduledGoogleSyncPolicies=0,queuedNotifications=0,pushDevices=0)
        config=Mock(read_text=Mock(return_value=json.dumps({'local_cli_owner':'a'*32,'action_daily_limits':{}})))
        with patch.object(installer,'P',return_value=config),patch.object(installer.stack,'sql',side_effect=['[]',json.dumps(q)]),patch.object(installer,'active',return_value=False):
            with self.assertRaises(installer.Held):installer.queue_guard()
        self.assertEqual(installer.REPORT['blockers'],['claimableTicketStates'])
    def test_failed_real_probe_prevents_credentials_and_start(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as mocks:
            folder=P(tmp);(folder/'network-plan.json').write_text('{}')
            manifest={'architecture':'amd64','ubuntuCodename':'noble','packages':{name:{} for name in ('docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin')}}
            (folder/'docker-package-manifest.json').write_text(json.dumps(manifest))
            mocks.enter_context(patch.object(installer,'HERE',folder))
            mocks.enter_context(patch.object(installer,'STATE',folder/'state'))
            mocks.enter_context(patch.object(installer.os,'geteuid',return_value=0))
            mocks.enter_context(patch.object(installer.os,'umask'))
            mocks.enter_context(patch.object(installer.pwd,'getpwnam',return_value=Mock(pw_uid=999)))
            mocks.enter_context(patch.object(installer,'verify_bundle',return_value={}))
            mocks.enter_context(patch.object(installer,'config_guard',return_value='synthetic'))
            mocks.enter_context(patch.object(installer,'active',return_value=False))
            mocks.enter_context(patch.object(installer,'command',return_value='amd64'))
            mocks.enter_context(patch.object(installer.socket,'socket'))
            for name in ('checkpoint','save','queue_guard','check_network','docker_install','image_build','docker_network','public_install'):
                mocks.enter_context(patch.object(installer,name))
            mocks.enter_context(patch.object(installer,'probe_without_credentials',side_effect=AssertionError('synthetic')))
            credentials=mocks.enter_context(patch.object(installer,'browser_credentials'))
            start=mocks.enter_context(patch.object(installer,'start_browser'))
            with self.assertRaises(AssertionError):installer.main()
            credentials.assert_not_called();start.assert_not_called()
    def test_stack_restart_failure_restores_exact_env_bytes_and_owner(self):
        installer.CONFIG_MUTATED=True
        with tempfile.TemporaryDirectory() as tmp:
            path=P(tmp)/'worker.env';old=b'OTHER=synthetic\n';path.write_bytes(b'changed\n')
            info=Mock(st_mode=0o100600,st_uid=999,st_gid=989)
            installer.ENV_BACKUP[path]=(old,info)
            writes=[]
            def write(p,raw,mode,uid,gid):writes.append((mode,uid,gid));p.write_bytes(raw)
            with patch.object(installer,'atomic',side_effect=write),patch.object(installer,'run',return_value=Mock(returncode=0)),patch.object(installer,'active',return_value=True):result=installer.rollback()
            self.assertEqual(path.read_bytes(),old)
            self.assertEqual(writes,[(0o600,999,989)])
            self.assertTrue(result['stackEnvironmentRestored'] and result['stackServicesActive'])
    def test_failed_rollback_reports_failure(self):
        installer.CONFIG_MUTATED=True
        with patch.object(installer,'run',side_effect=RuntimeError('synthetic')):
            result=installer.rollback()
            self.assertEqual(result['stackRollbackErrorType'],'RuntimeError')
            self.assertNotIn('stackServicesActive',result)
    def test_no_browser_stop_for_untouched_existing_service(self):
        with patch.object(installer,'run') as run:
            installer.rollback();run.assert_not_called()
    def test_interrupted_installer_runs_rollback_and_returns_failure(self):
        with patch.object(installer,'main',side_effect=installer.InterruptedInstaller('synthetic')),patch.object(installer,'rollback',return_value={'tested':True}) as rollback,patch.object(installer,'save'),patch.object(installer.signal,'signal'),patch('builtins.print'):
            self.assertEqual(installer.execute(),1)
            rollback.assert_called_once()
            self.assertEqual(installer.REPORT['errorType'],'InterruptedInstaller')
    def test_health_uses_ready_and_invalid_token_boundary(self):
        import io,urllib.error
        response=io.StringIO('{"ready":true}')
        opener=Mock();opener.open.side_effect=[response,urllib.error.HTTPError('synthetic',403,'forbidden',{},None)]
        with patch.object(installer.urllib.request,'build_opener',return_value=opener):installer.health('synthetic')
        self.assertEqual(opener.open.call_count,2)
    def test_api_connection_readiness_is_retryable(self):
        proof={'actualUid':999,'checks':{'login':True,'api':False},'failureMetadata':{'api':{'errorType':'URLError'}}}
        with patch.object(installer,'command',return_value=json.dumps(proof)):
            with self.assertRaises(RuntimeError):installer.model_and_worker_probe()
        self.assertEqual(installer.REPORT['serviceIdentityAuthentication'],proof)
    def test_api_auth_failure_is_not_readiness(self):
        proof={'actualUid':999,'checks':{'login':True,'api':False},'failureMetadata':{}}
        with patch.object(installer,'command',return_value=json.dumps(proof)):
            with self.assertRaises(AssertionError):installer.model_and_worker_probe()

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result=unittest.TextTestRunner(verbosity=1).run(suite)
    report={'testsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),
            'passed':result.wasSuccessful(),'syntheticInputsOnly':True,'liveDockerOrNetworkChanges':False,
            'privilegedCommandsRun':False,'credentialsCreated':False}
    (P(__file__).parent/'offline-tests-result.json').write_text(json.dumps(report,indent=2)+'\n')
    sys.exit(0 if result.wasSuccessful() else 1)
