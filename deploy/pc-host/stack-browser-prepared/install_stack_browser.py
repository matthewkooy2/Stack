"""One attended installer. Metadata only; no live work when imported for tests."""
import base64,hashlib,ipaddress,json,os,pathlib,pwd,re,secrets,shutil,signal,socket,stat,subprocess,sys,tempfile,time,urllib.error,urllib.request
P=pathlib.Path
HERE=P(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import stack_worker_activation as stack
import browser_policy as policy
import browser_runtime as runtime
import browser_preflight as preflight
STATE=P('/var/lib/stack-browser-controller')
CONFIG=P('/etc/stack')
LIB=P('/usr/local/libexec/stack-browser')
UNIT=P('/etc/systemd/system/stack-browser.service')
JOURNAL=STATE/'installation-metadata.json'
RESULT=HERE.parent/'stack-browser-installation-result.json'
REPORT={'status':'preflight','credentialValuesEmitted':False,'historicalRecordsResetOrRequeued':False,
        'discoveryActivationRequested':False,'phoneAcceptance':'pending'}
ROLLBACK={}
ENV_BACKUP={}
BROWSER_STARTED=False
CONFIG_MUTATED=False
MANIFEST_ID=''
JOURNAL_ALLOWED=False
RESUME_SIGNED_INDEXES=False
IMAGE_BUNDLE_ID=''
KNOWN_PROBE_CHECKPOINT='b11c85c4d89a0b7fadb09278ddf780e04c61c16c972889eadb0ec2619cd15771'
KNOWN_PROBE_RUNTIME='478e5816b74ed737ffda50b50f623023aa26a51c2cfcc4be1e3fecb909151dc6'
KNOWN_FIRST_LAUNCH_CHECKPOINT='d583fca8879e7474cd9658baf23818bbc0befc64ef13864086c27f94f75ce732'
KNOWN_CACHE_LAUNCH_CHECKPOINT='bfbff5b38960a1f76e95311a4569d763c7b83a587341db47a2ab3317bc8355dc'
KNOWN_CACHE_RUNTIME='714b99f4cf23edcceab24409e2bb591bbfc887f70bf1f1f1393ad87816e6f10f'
KNOWN_API_READINESS_CHECKPOINT='bafabc0e982221cf50670231a895384379d6b704e3be8c88e61290db1904fe98'
KNOWN_PREINSTALL_MANIFESTS={'310a9e2bb70ba4dbacafd7e391420625a237bb229c5109ce52113ec1b04324c7'}
CORE=('stack-api.service','stack-worker.service')
HOLD=preflight.WORK_HOLDS
ALLOWED_DEPENDENCIES={'iptables','libip4tc2','libip6tc2','libnetfilter-conntrack3','libnfnetlink0','libnftnl11',
                     'libxtables12','libnftables1','nftables','pigz'}
PUBLIC_FILES=('browser_runtime.py','browser_policy.py','browser_preflight.py','stack-browser.service','browser-seccomp.json',
              'network-plan.json','preparation-metadata.json','docker-package-manifest.json','docker-repository.asc',
              'install_stack_browser.py','../stack_worker_activation.py',
              '../run_stack_browser_install.sh','../run_stack_browser_install.ps1')

class Held(Exception):pass
class InterruptedInstaller(Exception):pass

def interrupted(signum,frame):raise InterruptedInstaller('Attended installer interrupted')

def digest(raw):return hashlib.sha256(raw).hexdigest()

def atomic(path,raw,mode=0o600,uid=0,gid=0):
    path=P(path)
    assert not path.is_symlink() and not path.parent.is_symlink()
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
    try:
        os.fchmod(fd,mode);os.fchown(fd,uid,gid)
        with os.fdopen(fd,'wb') as out:out.write(raw)
        os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

def save():
    # The journal contains counts, stages, public hashes and exit statuses only.
    raw=(json.dumps(REPORT,indent=2)+'\n').encode()
    RESULT.write_bytes(raw)
    if JOURNAL_ALLOWED and STATE.exists():atomic(JOURNAL,raw)

def checkpoint(phase):
    REPORT['phase']=phase
    save()
    print(json.dumps({'phase':phase,'status':REPORT['status']}),flush=True)

def run(args,role,timeout=60,input=None,env=None,okay=()):
    safe_env={'PATH':'/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','LANG':'C.UTF-8',
              'HOME':'/root','DOCKER_HOST':'unix:///var/run/docker.sock','DEBIAN_FRONTEND':'noninteractive',
              'PYTHONDONTWRITEBYTECODE':'1'}
    if env:safe_env.update(env)
    try:q=subprocess.run(args,capture_output=True,text=True,input=input,timeout=timeout,env=safe_env,cwd='/tmp')
    except BaseException as exc:
        REPORT['commandFailure']={'role':role,'errorType':type(exc).__name__};raise
    if q.returncode not in (0,*okay):
        REPORT['commandFailure']={'role':role,'exitCode':q.returncode}
        raise RuntimeError('Command failed; private/raw output suppressed')
    return q

def command(args,role,**kwargs):return run(args,role,**kwargs).stdout.strip()

def props(unit):
    return dict(line.split('=',1) for line in command(['/usr/bin/systemctl','show',unit,'--property=User,Group,MainPID,ActiveState,SubState,NRestarts'], 'service_metadata').splitlines())

def active(unit):return run(['/usr/bin/systemctl','is-active','--quiet',unit],'service_active',okay=(3,4)).returncode==0

def queue_guard():
    c=json.loads(P('/opt/stack/storage/agents/config.json').read_text())
    owner=c.get('local_cli_owner','').replace('-','')
    rows=json.loads(stack.sql(preflight.policy_sql(owner)))
    effective=preflight.effective_policy_metadata(rows,c.get('action_daily_limits',{}),c.get('certified_adapters',[]))
    q=json.loads(stack.sql(preflight.source_queue_sql(stack.QUEUE)))
    blockers=preflight.blockers(q,effective)
    REPORT['queueMetadata']=q
    REPORT['effectivePolicyMetadata']=effective
    if blockers:
        REPORT['blockers']=blockers
        raise Held('Unexpected runnable work or external policies require review')
    if active('stack-discovery.service'):raise Held('Discovery unexpectedly active')
    return q

def read_env(path):
    path=P(path);s=path.stat()
    assert not path.is_symlink() and s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600
    raw=path.read_bytes()
    lines=raw.decode().splitlines()
    keys=[line.split('=',1)[0] for line in lines if '=' in line and not line.lstrip().startswith('#')]
    assert len(keys)==len(set(keys)), 'Duplicate env keys require review'
    return raw,dict(line.split('=',1) for line in lines if '=' in line and not line.lstrip().startswith('#')),s

def replace_browser_env(raw,token):
    values={'STACK_BROWSER_URL':'http://127.0.0.1:8011','STACK_BROWSER_TOKEN':token}
    lines=raw.decode().splitlines(keepends=True);seen=set();output=[]
    for line in lines:
        key=line.split('=',1)[0] if '=' in line and not line.lstrip().startswith('#') else ''
        if key in values:
            assert key not in seen
            seen.add(key);output.append(key+'='+values[key]+'\n')
        else:output.append(line)
    result=''.join(output)
    if result and not result.endswith('\n'):result+='\n'
    for key,value in values.items():
        if key not in seen:result+=key+'='+value+'\n'
    return result.encode()

def known_preinstall_hold(old):
    return (old.get('preparedBundleSha256') in KNOWN_PREINSTALL_MANIFESTS
            and old.get('status')=='held' and old.get('phase')=='signed_apt_update'
            and old.get('errorType')=='Held' and not old.get('commandFailure')
            and not old.get('dockerPackagesVerified') and not old.get('attachmentCommitted')
            and not old.get('browserHealthy') and not old.get('realContainerEgressProof'))

def assert_preinstall_state():
    assert not shutil.which('docker') and not active('docker.service') and not active('stack-browser.service')
    for path in (UNIT,CONFIG/'browser.env',CONFIG/'browser-image-id',LIB,P('/run/docker.sock')):
        assert not path.exists(),'Recorded preinstall state has changed; review before resuming'
    for package in ('docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin'):
        q=run(['/usr/bin/dpkg-query','-W','-f=${Status}',package],'preinstall_package_state',okay=(1,))
        assert q.returncode==1 or q.stdout.strip() in ('','unknown ok not-installed','deinstall ok config-files')

def verified_probe_checkpoint(old):
    assert old.get('preparedBundleSha256')==KNOWN_PROBE_CHECKPOINT
    assert old.get('phase')=='real_container_egress_tests_before_credentials'
    assert old.get('status')=='failed' and old.get('errorType')=='AssertionError'
    assert old.get('dockerPackagesVerified') and not old.get('attachmentCommitted') and not old.get('browserHealthy')
    assert not UNIT.exists() and not (CONFIG/'browser.env').exists() and not active('stack-browser.service')
    for name in ('api.env','worker.env'):
        _,values,_=read_env(CONFIG/name)
        assert not values.get('STACK_BROWSER_URL') and not values.get('STACK_BROWSER_TOKEN')
    assert digest((LIB/'browser_runtime.py').read_bytes())==KNOWN_PROBE_RUNTIME
    assert (LIB/'browser_policy.py').read_bytes()==(HERE/'browser_policy.py').read_bytes()
    verify_packages(json.loads((HERE/'docker-package-manifest.json').read_text()))
    image=(CONFIG/'browser-image-id').read_text().strip()
    assert image==old.get('browserImageId')
    label=command(['/usr/bin/docker','image','inspect','--format','{{index .Config.Labels "stack.preparedBundle"}}',image],'reviewed_probe_image')
    assert label==KNOWN_PROBE_CHECKPOINT
    assert run(['/usr/bin/docker','container','inspect','stack-browser-egress-probe'],'probe_cleanup_recheck',okay=(1,)).returncode==1
    proof=json.loads((STATE/'runtime-metadata.json').read_text())
    assert proof.get('realContainerProbesPassed') and proof.get('chromiumGateOpened') is False
    assert proof.get('cleanup',{}).get('stopExitCode')==0
    return True

def verified_first_launch_checkpoint(old):
    assert old.get('preparedBundleSha256')==KNOWN_FIRST_LAUNCH_CHECKPOINT
    assert old.get('status')=='failed' and old.get('phase')=='starting_gated_browser_service'
    assert old.get('commandFailure')=={'role':'browser_start_measurement_reset','exitCode':1}
    assert not old.get('attachmentCommitted') and not old.get('browserHealthy') and not active('stack-browser.service')
    assert UNIT.read_bytes()==(HERE/'stack-browser.service').read_bytes()
    assert all((LIB/name).read_bytes()==(HERE/name).read_bytes() for name in ('browser_runtime.py','browser_policy.py'))
    browser_credentials(allow_create=False)
    for name in ('api.env','worker.env'):
        _,values,_=read_env(CONFIG/name)
        assert not values.get('STACK_BROWSER_URL') and not values.get('STACK_BROWSER_TOKEN')
    verify_packages(json.loads((HERE/'docker-package-manifest.json').read_text()))
    assert (CONFIG/'browser-image-id').read_text().strip()==old.get('browserImageId')
    assert old.get('realContainerEgressProof',{}).get('cleanup',{}).get('containerAbsent') is True
    return True

def verified_cache_launch_checkpoint(old):
    assert old.get('preparedBundleSha256')==KNOWN_CACHE_LAUNCH_CHECKPOINT
    assert old.get('status')=='failed' and old.get('phase')=='starting_gated_browser_service'
    assert old.get('errorType')=='RuntimeError' and not old.get('commandFailure')
    assert old.get('rollback',{}).get('browserServiceStopped') and old.get('rollback',{}).get('browserContainerAbsent')
    assert not old.get('attachmentCommitted') and not old.get('browserHealthy') and not active('stack-browser.service')
    assert UNIT.read_bytes()==(HERE/'stack-browser.service').read_bytes()
    assert digest((LIB/'browser_runtime.py').read_bytes())==KNOWN_CACHE_RUNTIME
    assert (LIB/'browser_policy.py').read_bytes()==(HERE/'browser_policy.py').read_bytes()
    browser_credentials(allow_create=False)
    for name in ('api.env','worker.env'):
        _,values,_=read_env(CONFIG/name)
        assert not values.get('STACK_BROWSER_URL') and not values.get('STACK_BROWSER_TOKEN')
    verify_packages(json.loads((HERE/'docker-package-manifest.json').read_text()))
    assert (CONFIG/'browser-image-id').read_text().strip()==old.get('browserImageId')
    return True

def verified_api_readiness_checkpoint(old):
    assert old.get('preparedBundleSha256')==KNOWN_API_READINESS_CHECKPOINT
    assert old.get('status')=='failed' and old.get('phase')=='restarting_api_and_agent_worker'
    assert old.get('errorType')=='AssertionError' and not old.get('commandFailure')
    assert not old.get('attachmentCommitted') and old.get('browserHealthy')
    assert all(old.get('rollback',{}).get(k) for k in ('stackEnvironmentRestored','stackServicesActive','browserServiceStopped','browserContainerAbsent'))
    assert not active('stack-browser.service')
    assert UNIT.read_bytes()==(HERE/'stack-browser.service').read_bytes()
    assert all((LIB/name).read_bytes()==(HERE/name).read_bytes() for name in ('browser_runtime.py','browser_policy.py'))
    browser_credentials(allow_create=False)
    for name in ('api.env','worker.env'):
        _,values,_=read_env(CONFIG/name)
        assert not values.get('STACK_BROWSER_URL') and not values.get('STACK_BROWSER_TOKEN')
    verify_packages(json.loads((HERE/'docker-package-manifest.json').read_text()))
    assert (CONFIG/'browser-image-id').read_text().strip()==old.get('browserImageId')
    return True

def config_guard():
    path=P('/opt/stack/storage/agents/config.json')
    raw=path.read_bytes();c=json.loads(raw)
    assert c.get('provider')=='codex-cli' and 1<=int(c.get('local_cli_daily_limit',0))<=100
    assert c.get('certified_adapters')==[] and not c.get('sandbox_available')
    assert all(c.get('action_daily_limits',{}).get(key)==0 for key in ('browser_fill','submit_application','send_email','calendar_write'))
    owner=c.get('local_cli_owner','').replace('-','')
    assert re.fullmatch('[0-9a-f]{32}',owner)
    assert stack.sql("SELECT count(*) FROM identity_users WHERE replace(doc->>'root_id','-','')='"+owner+"';")=='1'
    for unit in (*CORE,'stack-gateway.service'):
        p=props(unit);assert p['ActiveState']=='active' and p['SubState']=='running'
        if unit in CORE:
            assert p['User']=='stack' and P('/proc/'+p['MainPID']).stat().st_uid==999
    for unit in ('stack-api.service','stack-gateway.service'):
        text=command(['/usr/bin/systemctl','cat',unit],'service_isolation_metadata')
        assert '/var/lib/stack-codex' in text and 'InaccessiblePaths=' in text
    for name in ('api.env','worker.env'):
        _,v,_=read_env(CONFIG/name)
        assert not any(v.get(k) for k in ('STACK_SANDBOX_URL','STACK_SANDBOX_TOKEN','OPENAI_API_KEY','MODEL_API_KEY'))
    return digest(raw)

def verify_bundle():
    global MANIFEST_ID,JOURNAL_ALLOWED,RESUME_SIGNED_INDEXES,IMAGE_BUNDLE_ID
    manifest=json.loads((HERE/'installer-manifest.json').read_text())
    expected=set(PUBLIC_FILES)|{'context/'+r['path'] for r in json.loads((HERE/'preparation-metadata.json').read_text())['files']}
    assert set(manifest['sha256'])==expected
    for name,h in manifest['sha256'].items():
        p=HERE/name;assert not p.is_symlink() and digest(p.read_bytes())==h
    MANIFEST_ID=digest((HERE/'installer-manifest.json').read_bytes())
    IMAGE_BUNDLE_ID=MANIFEST_ID
    REPORT['preparedBundleSha256']=MANIFEST_ID
    if STATE.exists():
        s=STATE.stat()
        assert not STATE.is_symlink() and s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o700
    if JOURNAL.exists():
        s=JOURNAL.stat()
        assert not JOURNAL.is_symlink() and s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600
        old=json.loads(JOURNAL.read_text())
        if old.get('preparedBundleSha256')!=MANIFEST_ID:
            if old.get('preparedBundleSha256')==KNOWN_API_READINESS_CHECKPOINT:
                assert verified_api_readiness_checkpoint(old)
                IMAGE_BUNDLE_ID=old['browserImageSourceBundleSha256']
                REPORT['resumedReviewedApiReadinessCheckpoint']=True
            elif old.get('preparedBundleSha256')==KNOWN_CACHE_LAUNCH_CHECKPOINT:
                assert verified_cache_launch_checkpoint(old)
                IMAGE_BUNDLE_ID=old['browserImageSourceBundleSha256']
                REPORT['resumedReviewedCacheLaunchCheckpoint']=True
            elif old.get('preparedBundleSha256')==KNOWN_FIRST_LAUNCH_CHECKPOINT:
                assert verified_first_launch_checkpoint(old)
                IMAGE_BUNDLE_ID=old['browserImageSourceBundleSha256']
                REPORT['resumedReviewedFirstLaunchCheckpoint']=True
            elif old.get('preparedBundleSha256')==KNOWN_PROBE_CHECKPOINT:
                assert verified_probe_checkpoint(old)
                IMAGE_BUNDLE_ID=KNOWN_PROBE_CHECKPOINT
                REPORT['resumedReviewedProbeCheckpoint']=True
            else:
                assert known_preinstall_hold(old),'Existing installation journal differs; inspect before changing'
                assert_preinstall_state()
            assert time.time()-s.st_mtime<86400,'Preinstall signed-index checkpoint is stale; review before resuming'
            RESUME_SIGNED_INDEXES=True
            REPORT['resumedFromKnownPreinstallManifest']=old['preparedBundleSha256']
            REPORT['signedIndexCheckpointEpoch']=int(s.st_mtime)
        elif old.get('signedRepositoryIndexesValidated') and time.time()-float(old.get('signedIndexCheckpointEpoch',0))<86400:
            RESUME_SIGNED_INDEXES=True
            IMAGE_BUNDLE_ID=old.get('browserImageSourceBundleSha256',MANIFEST_ID)
        REPORT.update(old)
        REPORT['preparedBundleSha256']=MANIFEST_ID
        REPORT['browserImageSourceBundleSha256']=IMAGE_BUNDLE_ID
        REPORT['previousAttemptOutcome']={k:old.get(k) for k in ('status','phase','errorType','commandFailure','blockers','rollback')}
        for key in ('errorType','commandFailure','blockers','rollback'):REPORT.pop(key,None)
        REPORT['status']='preflight'
        JOURNAL_ALLOWED=True
        return old
    assert not UNIT.exists() and not (CONFIG/'browser.env').exists(), 'Unrecognized browser installation exists'
    JOURNAL_ALLOWED=True
    return {}

def check_network(plan,existing=False):
    subnet=ipaddress.ip_network(plan['subnet'])
    assert plan['networkName']=='stack-browser-egress' and plan['bridgeName']=='br-stackbr'
    assert str(subnet)=='172.30.254.0/29' and plan['ipv6Enabled'] is False
    assert [str(subnet[i]) for i in (1,2,3)]==[plan[k] for k in ('gateway','browserAddress','probeAddress')]
    dns=[line.split()[1] for line in P('/etc/resolv.conf').read_text().splitlines() if line.startswith('nameserver ')]
    assert policy.validate_dns(dns)==plan['dnsServers'],'Current WSL resolver changed; reprepare metadata'
    # Refresh harmless Windows metadata before each network check, including
    # after the image build. This never changes Windows firewall/VPN/routes.
    script="$p=@(Get-NetRoute -AddressFamily IPv4 | Select-Object -ExpandProperty DestinationPrefix -Unique); $b=@(Get-NetTCPConnection -State Listen -LocalPort 8011 -ErrorAction SilentlyContinue).Count -gt 0; @{ipv4Prefixes=$p;port8011Free=(-not $b)} | ConvertTo-Json -Compress"
    windows=json.loads(command(['/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe','-NoProfile','-NonInteractive','-Command',script],'current_windows_route_metadata'))
    assert windows['port8011Free'] is True
    for prefix in windows['ipv4Prefixes']:
        n=ipaddress.ip_network(prefix,strict=False)
        if n.prefixlen:assert not subnet.overlaps(n)
    routes=json.loads(command(['/usr/sbin/ip','-j','-4','route','show','table','all'],'current_route_metadata'))
    for row in routes:
        dst=row.get('dst','default')
        if dst=='default':continue
        n=ipaddress.ip_network(dst,strict=False)
        if existing and row.get('dev')==plan['bridgeName']:continue
        assert not subnet.overlaps(n),'Selected bridge subnet now overlaps an existing route'

def verify_packages(manifest):
    for name,item in manifest['packages'].items():
        q=run(['/usr/bin/dpkg-query','-W','-f=${Status}\t${Version}',name],'package_metadata',okay=(1,))
        assert q.returncode==0 and q.stdout.strip()=='install ok installed\t'+item['version']

def apt_plan_allowed(text,packages):
    for line in text.splitlines():
        if line.startswith('Remv '):return False
        if not line.startswith('Inst '):continue
        name=line.split()[1].split(':')[0]
        # Do not silently upgrade an unrelated installed dependency.
        # Installed versions occur directly after the package name. The
        # architecture annotation at the END of APT's candidate description
        # (e.g. [amd64]) also uses brackets and is not an upgrade marker.
        upgrade=re.match(r'^Inst\s+\S+\s+\[[^\]]+\]\s+\(',line)
        if name not in packages and (name not in ALLOWED_DEPENDENCIES or upgrade):return False
    return True

def apt_plan_metadata(text,packages):
    changes=[]
    for line in text.splitlines():
        if not line.startswith(('Inst ','Remv ')):continue
        name=line.split()[1].split(':')[0]
        upgrade=bool(re.match(r'^Inst\s+\S+\s+\[[^\]]+\]\s+\(',line))
        operation='remove' if line.startswith('Remv ') else 'upgrade' if upgrade else 'install'
        allowed=operation!='remove' and (name in packages or (name in ALLOWED_DEPENDENCIES and not upgrade))
        changes.append({'package':name,'operation':operation,'allowed':allowed})
    return {'allowed':apt_plan_allowed(text,packages),'changes':changes}

def docker_install(manifest,recognized):
    checkpoint('docker_package_preflight')
    conflicts=('docker.io','docker-compose','docker-compose-v2','podman-docker','containerd','runc')
    for name in conflicts:
        q=run(['/usr/bin/dpkg-query','-W','-f=${Status}',name],'conflicting_package_metadata',okay=(1,))
        if q.returncode==0 and q.stdout.strip()=='install ok installed':raise Held('Conflicting runtime requires review')
    complete=False
    if shutil.which('docker'):
        assert recognized,'Unrecognized existing Docker runtime; inspect first'
        for name,item in manifest['packages'].items():
            q=run(['/usr/bin/dpkg-query','-W','-f=${Status}\t${Version}',name],'existing_pinned_package_metadata',okay=(1,))
            if q.returncode==0 and q.stdout.startswith('install ok installed\t'):
                assert q.stdout.strip().split('\t')[1]==item['version'],'Existing runtime version differs'
        try:verify_packages(manifest);complete=True
        except AssertionError:pass
    if not complete:
        key=HERE/'docker-repository.asc'
        assert digest(key.read_bytes())==manifest['keySha256']
        keypath=P('/etc/apt/keyrings/stack-docker.asc');repo=P('/etc/apt/sources.list.d/stack-docker.sources')
        body=('Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/stack-docker.asc\n').encode()
        if RESUME_SIGNED_INDEXES:
            assert keypath.exists() and repo.exists()
            assert not keypath.is_symlink() and not repo.is_symlink()
            assert keypath.read_bytes()==key.read_bytes() and repo.read_bytes()==body
            checkpoint('resuming_recorded_package_plan')
            REPORT['existingRepositoryAndSignedIndexesReused']=True
        else:
            fp=command(['/usr/bin/gpg','--batch','--no-options','--with-colons','--show-keys',str(key)],'public_repository_key_metadata',env={'GNUPGHOME':str(STATE/'gnupg')})
            fingerprints=[r.split(':')[9] for r in fp.splitlines() if r.startswith('fpr:')]
            assert fingerprints[0]=='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
            keypath.parent.mkdir(mode=0o755,exist_ok=True)
            for path,raw in ((keypath,key.read_bytes()),(repo,body)):
                if path.exists():assert path.read_bytes()==raw and not path.is_symlink()
                else:atomic(path,raw,0o644)
            checkpoint('signed_apt_update')
            command(['/usr/bin/apt-get','update'],'signed_repository_update',timeout=600)
        versions=[name+'='+item['version'] for name,item in manifest['packages'].items()]
        for name,item in manifest['packages'].items():
            metadata=command(['/usr/bin/apt-cache','show',name+'='+item['version']],'signed_package_metadata')
            records=[dict(line.split(': ',1) for line in block.splitlines() if ': ' in line) for block in metadata.split('\n\n')]
            assert any(x.get('Version')==item['version'] and x.get('SHA256')==item['sha256'] and x.get('Filename')==item['filename'] for x in records)
        REPORT['signedRepositoryIndexesValidated']=True
        REPORT.setdefault('signedIndexCheckpointEpoch',int(time.time()))
        checkpoint('docker_package_plan')
        dry=command(['/usr/bin/apt-get','--simulate','--no-install-recommends','install',*versions],'package_installation_dry_run',timeout=60)
        REPORT['packagePlan']=apt_plan_metadata(dry,manifest['packages'])
        save()
        if not apt_plan_allowed(dry,manifest['packages']):
            REPORT['blockers']=['package_plan_outside_pinned_runtime_or_new_known_dependencies']
            raise Held('Package plan exceeds approved runtime scope')
        checkpoint('installing_pinned_docker_packages')
        command(['/usr/bin/apt-get','--yes','--no-install-recommends','--no-remove','install',*versions],'pinned_runtime_installation',timeout=900)
        verify_packages(manifest)
    command(['/usr/bin/systemctl','enable','--now','docker.service'],'docker_daemon_enable',timeout=90)
    assert active('docker.service')
    REPORT['dockerPackagesVerified']=True

def docker_network(plan):
    q=run(['/usr/bin/docker','network','inspect',plan['networkName']],'browser_network_metadata',okay=(1,))
    if q.returncode:
        check_network(plan)
        command(['/usr/bin/docker','network','create','--driver','bridge','--subnet',plan['subnet'],'--gateway',plan['gateway'],
                 '--opt','com.docker.network.bridge.name='+plan['bridgeName'],'--label','stack.role=browser-isolation',plan['networkName']], 'dedicated_browser_network_create')
    data=json.loads(command(['/usr/bin/docker','network','inspect',plan['networkName']],'browser_network_verification'))[0]
    assert data['Driver']=='bridge' and not data['EnableIPv6'] and data['Labels'].get('stack.role')=='browser-isolation'
    assert data['Options'].get('com.docker.network.bridge.name')==plan['bridgeName']
    assert len(data['IPAM']['Config'])==1 and data['IPAM']['Config'][0]['Subnet']==plan['subnet'] and data['IPAM']['Config'][0]['Gateway']==plan['gateway']
    assert not data.get('Containers'),'An existing browser network has attached containers; inspect first'
    check_network(plan,existing=True)

def image_build():
    imagepath=CONFIG/'browser-image-id'
    if imagepath.exists():
        image=imagepath.read_text().strip();assert re.fullmatch(r'sha256:[0-9a-f]{64}',image)
        assert command(['/usr/bin/docker','image','inspect','--format','{{.Id}}',image],'existing_browser_image_metadata')==image
        label=command(['/usr/bin/docker','image','inspect','--format','{{index .Config.Labels "stack.preparedBundle"}}',image],'existing_browser_image_bundle')
        assert label==(IMAGE_BUNDLE_ID or MANIFEST_ID)
        return image
    q=run(['/usr/bin/docker','image','inspect','stack-browser-pc:prepared'],'existing_browser_image_tag',okay=(1,))
    if q.returncode==0:
        data=json.loads(q.stdout)[0]
        assert data['Config'].get('Labels',{}).get('stack.preparedBundle')==MANIFEST_ID,'Unrelated image uses the prepared tag'
        image=data['Id'];assert re.fullmatch(r'sha256:[0-9a-f]{64}',image)
        atomic(imagepath,(image+'\n').encode())
        return image
    checkpoint('building_curated_browser_image')
    assert shutil.disk_usage('/var/lib').free>2*1024**3
    context=STATE/'build-context'
    assert not context.is_symlink()
    context.mkdir(mode=0o700,exist_ok=True)
    files=json.loads((HERE/'preparation-metadata.json').read_text())['files']
    expected={r['path'] for r in files}
    present={str(p.relative_to(context)) for p in context.rglob('*') if p.is_file()}
    assert present<=expected,'Unexpected files in isolated build context'
    for row in files:
        raw=(HERE/'context'/row['path']).read_bytes();assert digest(raw)==row['sha256']
        atomic(context/row['path'],raw,0o644)
    command(['/usr/bin/docker','pull','python:3.12.11-slim-bookworm'],'official_python_base_pull',timeout=600)
    base=json.loads(command(['/usr/bin/docker','image','inspect','--format','{{json .RepoDigests}}','python:3.12.11-slim-bookworm'],'immutable_base_image_metadata'))
    pin=next(x for x in base if x.startswith('python@sha256:'))
    dockerfile=context/'deploy/browser.Dockerfile'
    body=dockerfile.read_text().replace('FROM python:3.12.11-slim-bookworm\n','FROM '+pin+'\n',1)
    assert body.startswith('FROM '+pin+'\n')
    atomic(dockerfile,body.encode(),0o644)
    command(['/usr/bin/docker','build','--pull=false','--label','stack.role=isolated-browser','--label','stack.preparedBundle='+MANIFEST_ID,
             '--tag','stack-browser-pc:prepared','--file',str(dockerfile),str(context)],'curated_browser_image_build',timeout=1800)
    image=command(['/usr/bin/docker','image','inspect','--format','{{.Id}}','stack-browser-pc:prepared'],'built_browser_image_metadata')
    assert re.fullmatch(r'sha256:[0-9a-f]{64}',image)
    REPORT['immutableBaseImage']=pin
    REPORT['browserImageId']=image
    atomic(imagepath,(image+'\n').encode())
    return image

def public_install(plan):
    LIB.mkdir(mode=0o755,parents=True,exist_ok=True)
    for name in ('browser_runtime.py','browser_policy.py'):
        raw=(HERE/name).read_bytes();dest=LIB/name
        if dest.exists():
            if name=='browser_runtime.py' and dest.read_bytes()!=raw and (REPORT.get('resumedReviewedProbeCheckpoint') or REPORT.get('resumedReviewedCacheLaunchCheckpoint')):
                assert digest(dest.read_bytes()) in (KNOWN_PROBE_RUNTIME,KNOWN_CACHE_RUNTIME)
                atomic(dest,raw,0o644)
            else:assert dest.read_bytes()==raw,'Installed controller differs'
        else:atomic(dest,raw,0o644)
    for dest,raw in ((CONFIG/'browser-seccomp.json',(HERE/'browser-seccomp.json').read_bytes()),
                     (CONFIG/'browser-network.json',(json.dumps(plan,indent=2)+'\n').encode())):
        if dest.exists():assert dest.read_bytes()==raw
        else:atomic(dest,raw)
    lock=P('/run/xtables.lock')
    assert not lock.is_symlink()
    if not lock.exists():atomic(lock,b'',0o600)

def probe_without_credentials():
    checkpoint('real_container_egress_tests_before_credentials')
    command(['/usr/bin/python3',str(LIB/'browser_runtime.py'),'--probe-only'],'real_container_egress_proof',timeout=120)
    data=json.loads((STATE/'runtime-metadata.json').read_text())
    assert data.get('realContainerProbesPassed') and data.get('chromiumGateOpened') is False
    assert data.get('cleanup',{}).get('containerAbsent') is True
    REPORT['realContainerEgressProof']=data

def browser_credentials(allow_create=True):
    path=CONFIG/'browser.env'
    if not path.exists():
        assert allow_create,'Committed browser credentials are missing; inspect before changing'
        token=secrets.token_urlsafe(48)
        key=base64.urlsafe_b64encode(os.urandom(32)).decode()
        raw=('STACK_BROWSER_TOKEN='+token+'\nSTACK_BROWSER_SESSION_KEY='+key+'\nSTACK_BROWSER_STORAGE=/tmp/stack-browser-state\nSTACK_BROWSER_RESOURCE_HOSTS=\n').encode()
        atomic(path,raw)
    _,values,_=read_env(path)
    assert set(values)=={'STACK_BROWSER_TOKEN','STACK_BROWSER_SESSION_KEY','STACK_BROWSER_STORAGE','STACK_BROWSER_RESOURCE_HOSTS'}
    assert re.fullmatch('[A-Za-z0-9_-]{64}',values['STACK_BROWSER_TOKEN'])
    assert len(base64.urlsafe_b64decode(values['STACK_BROWSER_SESSION_KEY']))==32
    assert values['STACK_BROWSER_STORAGE']=='/tmp/stack-browser-state' and values['STACK_BROWSER_RESOURCE_HOSTS']==''
    return values['STACK_BROWSER_TOKEN']

def health(token):
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req=urllib.request.Request('http://127.0.0.1:8011/health',headers={'Authorization':'Bearer '+token})
    with opener.open(req,timeout=4) as response:data=json.load(response)
    assert data.get('ready') is True
    try:
        opener.open(urllib.request.Request('http://127.0.0.1:8011/health',headers={'Authorization':'Bearer invalid-browser-preflight-token'}),timeout=4)
    except urllib.error.HTTPError as exc:assert exc.code==403
    else:raise AssertionError('Invalid browser token accepted')

def start_browser(token):
    global BROWSER_STARTED
    checkpoint('starting_gated_browser_service')
    raw=(HERE/'stack-browser.service').read_bytes()
    if UNIT.exists():assert UNIT.read_bytes()==raw and not UNIT.is_symlink()
    else:atomic(UNIT,raw,0o644)
    command(['/usr/bin/systemd-analyze','verify',str(UNIT)],'browser_unit_verification')
    command(['/usr/bin/systemctl','daemon-reload'],'browser_unit_reload')
    # Never-started inactive units can be garbage-collected by systemd; their
    # reset-failed request reports "not loaded". Only failed units need reset.
    if props('stack-browser.service')['ActiveState']=='failed':
        command(['/usr/bin/systemctl','reset-failed','stack-browser.service'],'browser_start_measurement_reset')
    BROWSER_STARTED=True
    command(['/usr/bin/systemctl','enable','--now','stack-browser.service'],'browser_service_start',timeout=90)
    deadline=time.monotonic()+120
    while True:
        try:health(token);break
        except (OSError,urllib.error.URLError,ValueError):
            if time.monotonic()>=deadline:raise RuntimeError('Browser health deadline exceeded')
            if props('stack-browser.service')['NRestarts']!='0':raise RuntimeError('Browser service restarted during launch')
            time.sleep(2)
    p=props('stack-browser.service');assert p['ActiveState']=='active' and p['SubState']=='running' and p['NRestarts']=='0'
    proof=json.loads((STATE/'runtime-metadata.json').read_text())
    assert proof.get('realContainerProbesPassed') and proof.get('chromiumGateOpened')
    runtime.inspect_container(runtime.NAME)
    ports=json.loads(command(['/usr/bin/docker','inspect','--format','{{json .NetworkSettings.Ports}}',runtime.NAME],'browser_listener_metadata'))
    assert ports.get('8011/tcp')==[{'HostIp':'127.0.0.1','HostPort':'8011'}]
    # No browser command line, session, DOM, or user data is inspected.
    sandbox=command(['/usr/bin/docker','exec','--user','pwuser',runtime.NAME,'/usr/local/bin/python3','-c',
        "import pathlib,json; cs=[p.read_bytes().split(b'\\0') for p in pathlib.Path('/proc').glob('[0-9]*/cmdline') if p.is_file()]; bs=[a for a in cs if a and b'headless_shell' in a[0] and b'--type=renderer' not in a and b'--type=zygote' not in a and b'--type=gpu-process' not in a and b'--type=utility' not in a]; print(json.dumps({'browserFound':bool(bs),'sandboxDisableFlagAbsent':bool(bs) and all(b'--no-sandbox' not in a for a in bs)}))"], 'chromium_sandbox_flag_metadata')
    assert all(json.loads(sandbox).values())
    REPORT['browserHealthy']=True
    REPORT['invalidBrowserTokenRejected']=True
    REPORT['browserIsolationReverified']=True
    REPORT['browserService']=p

def model_and_worker_probe():
    env={'PATH':'/usr/local/bin:/usr/bin:/bin','HOME':'/var/lib/stack-codex','CODEX_HOME':'/var/lib/stack-codex','LANG':'C.UTF-8'}
    code=stack.SERVICE_CHECK.replace('if CHECK_DISCOVERY:','if False:')
    proof=json.loads(command(stack.service_check_command(code,env),'actual_stack_uid_authentication',timeout=80))
    REPORT['serviceIdentityAuthentication']=proof
    # systemd Type=simple reports running while Jac is compiling the API.
    # Retry connection readiness failures, preserving hard auth failures.
    if any(item.get('errorType') in ('URLError','TimeoutError') for item in proof.get('failureMetadata',{}).values()):
        raise RuntimeError('API is still starting')
    assert proof['actualUid']==999 and all(proof['checks'].values())

def attach_stack(token,config_hash):
    global CONFIG_MUTATED
    checkpoint('final_queue_and_config_guard')
    queue_guard();assert config_guard()==config_hash
    for name in ('api.env','worker.env'):
        path=CONFIG/name;raw,values,s=read_env(path)
        assert not values.get('STACK_BROWSER_URL') and not values.get('STACK_BROWSER_TOKEN'), 'Existing browser attachment differs'
        ENV_BACKUP[path]=(raw,s)
    # Stop only the agent poller before changing its capability environment.
    CONFIG_MUTATED=True
    command(['/usr/bin/systemctl','stop','stack-worker.service'],'agent_worker_quiesce',timeout=60)
    try:
        queue_guard()
        for path,(raw,s) in ENV_BACKUP.items():atomic(path,replace_browser_env(raw,token),stat.S_IMODE(s.st_mode),s.st_uid,s.st_gid)
        checkpoint('restarting_api_and_agent_worker')
        command(['/usr/bin/systemctl','restart',*CORE],'affected_stack_services_restart',timeout=120)
        deadline=time.monotonic()+180
        while True:
            try:model_and_worker_probe();break
            except RuntimeError:
                if time.monotonic()>=deadline:raise
                time.sleep(2)
        assert config_guard()==config_hash
        for path,(old,s) in ENV_BACKUP.items():
            now,values,_=read_env(path)
            assert now==replace_browser_env(old,token)
        assert not active('stack-discovery.service') and active('stack-gateway.service')
        queue_guard()
        REPORT['existingOwnerLimitAndExternalQuotasUnchanged']=True
        REPORT['onlyBrowserEnvironmentKeysChanged']=True
    except BaseException:raise

def rollback():
    results={}
    if CONFIG_MUTATED:
        try:
            for path,(raw,s) in ENV_BACKUP.items():atomic(path,raw,stat.S_IMODE(s.st_mode),s.st_uid,s.st_gid)
            q=run(['/usr/bin/systemctl','restart',*CORE],'rollback_stack_services',timeout=120,okay=(1,))
            results['stackEnvironmentRestored']=all(path.read_bytes()==raw for path,(raw,_) in ENV_BACKUP.items())
            if results['stackEnvironmentRestored']:REPORT['attachmentCommitted']=False
            results['stackRestartExitCode']=q.returncode
            results['stackServicesActive']=all(active(unit) for unit in CORE)
        except BaseException as exc:results['stackRollbackErrorType']=type(exc).__name__
    if BROWSER_STARTED:
        try:
            q=run(['/usr/bin/systemctl','disable','--now','stack-browser.service'],'rollback_browser_stop',timeout=90,okay=(1,))
            results['browserStopExitCode']=q.returncode
            results['browserServiceStopped']=not active('stack-browser.service')
            q=run(['/usr/bin/docker','container','inspect',runtime.NAME],'rollback_browser_container_metadata',okay=(1,))
            results['browserContainerAbsent']=q.returncode==1 and 'No such' in q.stderr
        except BaseException as exc:results['browserRollbackErrorType']=type(exc).__name__
    results['runtimeUninstallOrNetworkRemovalAttempted']=False
    return results

def main():
    assert os.geteuid()==0
    os.umask(0o077)
    recognized=verify_bundle()
    checkpoint('protected_stack_preflight')
    assert pwd.getpwnam('stack').pw_uid==999
    osrelease=dict(line.split('=',1) for line in P('/etc/os-release').read_text().splitlines() if '=' in line)
    assert osrelease['ID']=='ubuntu' and osrelease['VERSION_ID'].strip('"')=='24.04'
    assert command(['/usr/bin/dpkg','--print-architecture'],'architecture_metadata')=='amd64'
    config_hash=config_guard();queue_guard()
    plan=json.loads((HERE/'network-plan.json').read_text())
    if recognized.get('attachmentCommitted'):
        token=browser_credentials(allow_create=False)
        assert active('stack-browser.service')
        health(token);runtime.inspect_container(runtime.NAME);model_and_worker_probe()
        for name in ('api.env','worker.env'):
            _,values,_=read_env(CONFIG/name)
            assert values.get('STACK_BROWSER_URL')=='http://127.0.0.1:8011' and values.get('STACK_BROWSER_TOKEN')==token
        REPORT.update(recognized)
        REPORT.update(status='browser_ready_phone_acceptance_pending',alreadyInstalledVerified=True,liveChangesMade=False)
        save();return
    if active('stack-browser.service'):raise Held('Browser already active; inspect before a retry')
    with socket.socket() as sock:sock.bind(('127.0.0.1',8011))
    check_network(plan,existing=bool(recognized))
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
    (STATE/'gnupg').mkdir(mode=0o700,exist_ok=True)
    STATE.chmod(0o700);save()
    manifest=json.loads((HERE/'docker-package-manifest.json').read_text())
    assert manifest['architecture']=='amd64' and manifest['ubuntuCodename']=='noble'
    assert set(manifest['packages'])=={'docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin'}
    docker_install(manifest,bool(recognized))
    image_build();docker_network(plan);public_install(plan)
    probe_without_credentials()
    checkpoint('creating_browser_only_credentials_after_network_proof')
    token=browser_credentials()
    start_browser(token)
    attach_stack(token,config_hash)
    REPORT.update(status='browser_ready_phone_acceptance_pending',attachmentCommitted=True,discoveryRemainedOff=True,
                  browserCredentialsUnrelatedToModelLogin=True,macFilesChanged=False)
    for key in ('commandFailure','blockers','errorType'):REPORT.pop(key,None)
    save();print(json.dumps({'status':REPORT['status'],'phoneAcceptance':'pending'}),flush=True)

def execute():
    try:main();return 0
    except BaseException as exc:
        for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,signal.SIG_IGN)
        REPORT.update(status='held' if isinstance(exc,Held) else 'failed',errorType=type(exc).__name__,rawDetailsSuppressed=True)
        REPORT['rollback']=rollback()
        save();print(json.dumps({'status':REPORT['status'],'phase':REPORT.get('phase'),'errorType':REPORT['errorType'],'rollback':REPORT['rollback']}),flush=True)
        return 1

if __name__=='__main__':
    for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,interrupted)
    sys.exit(execute())
