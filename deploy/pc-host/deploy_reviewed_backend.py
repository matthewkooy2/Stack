from pathlib import Path
import datetime, hashlib, json, os, shutil, stat, subprocess, tarfile, time, urllib.request, urllib.error, urllib.parse

OUTPUT=Path('/mnt/c/Users/Ryan/Documents/Codex/2026-10-01/task-2/outputs/deployment-result.json')
LIVE=Path('/opt/stack'); CANDIDATE=Path('/tmp/stack-integration-20261001/candidate')
MANIFEST=json.loads((OUTPUT.parent/'pc-deploy-manifest.json').read_text())
RECON=json.loads((OUTPUT.parent/'source-reconciliation.json').read_text())
FILES=MANIFEST['intended_live_backend_files']; ITEMS={i['path']:i for i in MANIFEST['source_paths']}
SERVICES=['stack-gateway.service','stack-worker.service','stack-api.service']
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
BACKUP=Path('/var/backups/stack')/('integration-'+stamp)
result={'status':'preparing','started_at_utc':stamp,'backup_path':str(BACKUP),'source_files':FILES,'service_interruption_authorized':True,'secrets_emitted':False}
paused=False;installed=False;metadata={};protected={};before_services={};db_environment={}

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
def persist(phase):
    result['phase']=phase;OUTPUT.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'phase':phase,'status':result['status']}),flush=True)
def command(args, env=None, timeout=45, name='command'):
    p=subprocess.run(args,capture_output=True,env=env,timeout=timeout)
    if BACKUP.exists():
        f=BACKUP/(name+'.log');f.write_bytes(p.stdout+b'\n'+p.stderr);f.chmod(0o600)
    if p.returncode:raise RuntimeError(name+' failed')
    return p.stdout
def service(name):
    raw=subprocess.run(['systemctl','show',name,'--no-pager','-p','ActiveState','-p','SubState','-p','MainPID','-p','NRestarts'],capture_output=True,text=True,check=True).stdout
    return dict(l.split('=',1) for l in raw.splitlines() if '=' in l)
def http(url,body=None):
    request=urllib.request.Request(url,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
    try:
        response=urllib.request.urlopen(request,timeout=8)
    except urllib.error.HTTPError as e:response=e
    with response:
        data=response.read(65536)
        try:data=json.loads(data)
        except ValueError:data=None
        return response.status,data
def wait_api(seconds=240):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            status,data=http('http://127.0.0.1:8000/function/health',{})
            if status==200 and data and data.get('data',{}).get('result',{}).get('status')=='ok':return True
        except (OSError,ValueError):pass
        if service('stack-api.service')['ActiveState']=='failed':return False
        time.sleep(2)
    return False
def verify_baseline():
    for rel in FILES:
        assert digest(LIVE/rel)==ITEMS[rel]['live_sha256'],'Intervening source change: '+rel
        assert digest(CANDIDATE/rel)==ITEMS[rel]['combined_sha256'],'Candidate changed: '+rel
    for rel in ['web/transport.js','tests/native.cjs','scripts/jac']:
        assert digest(LIVE/rel)==RECON['live_source_hashes'][rel],'Protected source changed: '+rel
def snapshot_protected():
    paths=list(Path('/etc/stack').glob('*.env'))+list(Path('/etc/systemd/system').glob('stack*.service'))
    paths+=list(Path('/usr/local/libexec/stack-browser').glob('*.py'))
    paths+=[Path('/etc/stack/browser-seccomp.json'),Path('/etc/stack/browser-network.json'),Path('/etc/stack/browser-image-id'),LIVE/'web/transport.js',LIVE/'tests/native.cjs',LIVE/'scripts/jac']
    return {str(p):digest(p) for p in paths if p.is_file()}

try:
    verify_baseline()
    protected=snapshot_protected()
    before_services={s:service(s) for s in SERVICES+['stack-browser.service','docker.service']}
    assert all(x['ActiveState']=='active' for x in before_services.values()),'Existing required service inactive'
    pid=before_services['stack-api.service']['MainPID']
    api_env=dict(x.split('=',1) for x in Path('/proc/'+pid+'/environ').read_text().split('\x00') if '=' in x)
    uri=urllib.parse.urlsplit(api_env.get('JAC_DB_URL',''))
    assert uri.scheme in ('postgres','postgresql') and uri.hostname and uri.path.strip('/'),'No supported existing database connection'
    db_environment=os.environ.copy()
    db_environment.update({'PGHOST':uri.hostname,'PGPORT':str(uri.port or 5432),'PGDATABASE':urllib.parse.unquote(uri.path.lstrip('/')),'PGUSER':urllib.parse.unquote(uri.username or ''),'PGPASSFILE':'/etc/stack/db.pgpass','PGCONNECT_TIMEOUT':'10'})
    if uri.password:db_environment['PGPASSWORD']=urllib.parse.unquote(uri.password)
    assert shutil.which('pg_dump') and shutil.which('pg_restore'),'Database backup tools missing'
    assert Path('/etc/stack/db.pgpass').is_file(),'Existing database credential file missing'
    BACKUP.mkdir(parents=True,mode=0o700);BACKUP.chmod(0o700)
    for rel in FILES:
        p=LIVE/rel
        if p.exists():
            st=p.stat();metadata[rel]={'uid':st.st_uid,'gid':st.st_gid,'mode':stat.S_IMODE(st.st_mode)}
            q=BACKUP/'source'/rel;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
        else:metadata[rel]=None
    (BACKUP/'metadata.json').write_text(json.dumps(metadata,indent=2));(BACKUP/'metadata.json').chmod(0o600)
    with tarfile.open(BACKUP/'private-config.tar.gz','w:gz') as archive:
        archive.add('/etc/stack',arcname='etc/stack')
        for s in SERVICES+['stack-browser.service']:archive.add('/etc/systemd/system/'+s,arcname='etc/systemd/system/'+s)
    (BACKUP/'private-config.tar.gz').chmod(0o600)
    verify_baseline();persist('source_backup_complete')
    paused=True
    for s in SERVICES:command(['systemctl','stop',s],timeout=60,name='stop-'+s)
    persist('application_services_paused')
    dump=BACKUP/'database.dump'
    command(['pg_dump','--no-password','--format=custom','--file='+str(dump)],env=db_environment,timeout=120,name='database-backup')
    assert dump.stat().st_size>100,'Empty database backup'
    command(['pg_restore','--list',str(dump)],timeout=30,name='database-backup-list')
    dump.chmod(0o600)
    storage=BACKUP/'storage';shutil.copytree(LIVE/'storage',storage,copy_function=shutil.copy2)
    storage_count=0
    for p in (LIVE/'storage').rglob('*'):
        if p.is_file():assert digest(p)==digest(storage/p.relative_to(LIVE/'storage'));storage_count+=1
    result['database_backup_verified']=True;result['database_backup_bytes']=dump.stat().st_size;result['storage_backup_verified']=True;result['storage_files_backed_up']=storage_count
    verify_baseline();persist('data_backups_verified')
    installed=True
    group=LIVE.stat().st_gid
    for rel in FILES:
        dest=LIVE/rel;temp=dest.with_name(dest.name+'.integration-new')
        assert not temp.exists(),'Unexpected staging file'
        shutil.copyfile(CANDIDATE/rel,temp)
        info=metadata[rel] or {'uid':0,'gid':group,'mode':0o640}
        os.chown(temp,info['uid'],info['gid']);temp.chmod(info['mode']);os.replace(temp,dest)
        assert digest(dest)==ITEMS[rel]['combined_sha256'],'Installed hash mismatch'
    persist('seven_application_files_installed')
    command(['systemctl','start','stack-api.service'],timeout=60,name='start-api')
    assert wait_api(),'API readiness failed'
    result['api_health']='HTTP 200 status ok';persist('api_ready')
    command(['systemctl','start','stack-worker.service'],timeout=60,name='start-worker')
    assert service('stack-worker.service')['ActiveState']=='active','Worker inactive'
    command(['systemctl','start','stack-gateway.service'],timeout=60,name='start-gateway')
    for _ in range(30):
        try:
            if http('http://127.0.0.1:8080/')[0]==200:break
        except OSError:pass
        time.sleep(1)
    else:raise AssertionError('Gateway readiness failed')
    probes={}
    for endpoint,args in [('resume_processing_claim',{'token':'invalid-deployment-smoke-token'}),('resume_processing_stage',{'token':'invalid-deployment-smoke-token','id':'missing','owner':'missing','lease':'missing','parse_ms':0}),('resume_processing_finish',{'token':'invalid-deployment-smoke-token','id':'missing','owner':'missing','lease':'missing','result':{}})]:
        status,data=http('http://127.0.0.1:8000/function/'+endpoint,args)
        assert status==200 and data.get('data',{}).get('result',{}).get('error')=='Worker authorization required.','Worker-route smoke failed: '+endpoint
        assert http('http://127.0.0.1:8080/function/'+endpoint,args)[0]==404,'Private route exposed: '+endpoint
        probes[endpoint]={'api_registered_and_invalid_token_rejected':True,'gateway_http':404}
    for endpoint in ['retry_resume_processing','resume_transfer_complete']:
        status,_=http('http://127.0.0.1:8080/function/'+endpoint,{})
        assert status in (401,403),'Async user-route smoke failed: '+endpoint
        probes[endpoint]={'gateway_registered_and_unauthenticated_rejected':True,'gateway_http':status}
    result['async_route_smoke']=probes
    result['services_after']={s:service(s) for s in SERVICES+['stack-browser.service','docker.service']}
    assert all(x['ActiveState']=='active' for x in result['services_after'].values()),'Service not active'
    assert result['services_after']['stack-browser.service']['MainPID']==before_services['stack-browser.service']['MainPID'],'Browser restarted unexpectedly'
    assert result['services_after']['docker.service']['MainPID']==before_services['docker.service']['MainPID'],'Docker restarted unexpectedly'
    result['protected_files_unchanged']=snapshot_protected()==protected
    assert result['protected_files_unchanged'],'Protected file changed unexpectedly'
    result['browser_pid_unchanged']=True;result['docker_pid_unchanged']=True;result['installed_source_hashes_verified']=True
    result['worker_thread_count']=len(list(Path('/proc/'+result['services_after']['stack-worker.service']['MainPID']+'/task').iterdir()))
    result['status']='deployed';result['completed_at_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();persist('deployment_and_local_smoke_passed')
except Exception as error:
    result['failure_phase']=result.get('phase','preparing');result['failure_type']=type(error).__name__;result['status']='failed'
    if paused:
        try:
            for s in SERVICES:command(['systemctl','stop',s],timeout=60,name='rollback-stop-'+s)
            if installed:
                for rel,info in metadata.items():
                    dest=LIVE/rel
                    if info is None:dest.unlink(missing_ok=True)
                    else:
                        shutil.copy2(BACKUP/'source'/rel,dest);os.chown(dest,info['uid'],info['gid']);dest.chmod(info['mode'])
            command(['systemctl','start','stack-api.service'],timeout=60,name='rollback-start-api')
            api_ready=wait_api()
            command(['systemctl','start','stack-worker.service'],timeout=60,name='rollback-start-worker')
            command(['systemctl','start','stack-gateway.service'],timeout=60,name='rollback-start-gateway')
            result['rollback']={'source_restored':installed,'api_ready':api_ready,'services_active':all(service(s)['ActiveState']=='active' for s in SERVICES),'database_restored':False,'storage_restored':False}
        except Exception as rollback_error:result['rollback']={'failed':True,'failure_type':type(rollback_error).__name__}
    persist('failed_or_rolled_back')
    raise SystemExit(1)
