"""Trusted host controller. Container-only firewall; launch gate; no auth logs."""
import ipaddress,json,os,pathlib,re,signal,subprocess,sys,time,uuid
import browser_policy as policy
P=pathlib.Path
CONFIG=P('/etc/stack/browser-network.json')
IMAGE=P('/etc/stack/browser-image-id')
STATE=P('/var/lib/stack-browser-controller')
NAME='stack-browser-pc'
step='initializing'
metadata={}

class StopRequested(Exception):pass

def request_stop(signum,frame):
    raise StopRequested('Service stop requested')

def record():
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
    path=STATE/'runtime-metadata.json'
    path.write_text(json.dumps(metadata,indent=2)+'\n');path.chmod(0o600)

def run(args,role,timeout=60,env=None):
    global step
    step=role
    try:result=subprocess.run(args,capture_output=True,text=True,timeout=timeout,env=env)
    except subprocess.TimeoutExpired:
        metadata['commandFailure']={'step':role,'errorType':'TimeoutExpired'}
        raise
    if result.returncode:
        metadata['commandFailure']={'step':role,'exitCode':result.returncode}
        raise RuntimeError('A container operation failed; raw output suppressed')
    return result.stdout.strip()

def container_parameters(name,address,image,network,probe=False,attempt=None):
    args=['/usr/bin/docker','run','--detach','--rm','--init','--name',name,
          '--label','stack.role='+('egress-probe' if probe else 'isolated-browser'),
          '--network',network['networkName'],'--ip',address,
          '--dns',network['dnsServers'][0],
          '--read-only','--tmpfs','/tmp:rw,exec,nosuid,size=512m,mode=1777','--shm-size','512m',
          '--memory','2g','--cpus','2','--pids-limit','256',
          '--cap-drop','ALL','--cap-add','SYS_CHROOT',
          '--security-opt','no-new-privileges',
          '--security-opt','seccomp=/etc/stack/browser-seccomp.json',
          '--sysctl','net.ipv6.conf.all.disable_ipv6=1',
          '--sysctl','net.ipv6.conf.default.disable_ipv6=1']
    if attempt:args+=['--label','stack.controllerAttempt='+attempt]
    for dns in network['dnsServers'][1:]:args+=['--dns',dns]
    if not probe:
        args+=['--publish','127.0.0.1:8011:8011']
        for key in ('STACK_BROWSER_TOKEN','STACK_BROWSER_SESSION_KEY','STACK_BROWSER_STORAGE','STACK_BROWSER_RESOURCE_HOSTS'):
            args+=['--env',key]
    # The image remains unchanged. No browser/process with networking starts
    # until the trusted controller has set policy and proved denials.
    # The native runtime cache is >512 MiB. Keep its immutable payload in the
    # image and copy only application files and writable compiler metadata.
    args+=['--entrypoint','/bin/sh',image,'-c',
           'set -eu; while [ ! -f /tmp/stack-browser-egress-ready ]; do sleep 0.2; done; '
           'cp -a /app /tmp/stack-browser; mkdir -p /tmp/jac-cache; '
           'ln -s /opt/jac-cache/rt /tmp/jac-cache/rt; '
           'cp -a /opt/jac-cache/jir /tmp/jac-cache/jir; '
           'cd /tmp/stack-browser; exec /usr/local/bin/jac run --no-serve deploy/browser-service.jac']
    return args

def inspect_container(name):
    state=json.loads(run(['/usr/bin/docker','inspect','--format','{{json .State}}',name],role='container_pid_metadata'))
    host=json.loads(run(['/usr/bin/docker','inspect','--format','{{json .HostConfig}}',name],role='container_isolation_metadata'))
    user=run(['/usr/bin/docker','inspect','--format','{{.Config.User}}',name],role='container_user_metadata')
    assert state['Running'] and int(state['Pid'])>1
    assert user=='pwuser'
    assert host['ReadonlyRootfs'] and not host['Privileged'] and not host.get('Binds')
    assert host['Memory']==2*1024**3 and host['NanoCpus']==2*10**9
    caps=lambda xs:[value.removeprefix('CAP_') for value in (xs or [])]
    assert host['PidsLimit']==256 and caps(host['CapDrop'])==['ALL'] and caps(host['CapAdd'])==['SYS_CHROOT']
    security=host.get('SecurityOpt') or []
    assert any(value in ('no-new-privileges','no-new-privileges=true') for value in security)
    assert any(value.startswith('seccomp=') and 'unconfined' not in value for value in security)
    assert host.get('PidMode','') not in ('host',) and host.get('IpcMode','')!='host'
    assert host['Sysctls']['net.ipv6.conf.all.disable_ipv6']=='1'
    assert host['Sysctls']['net.ipv6.conf.default.disable_ipv6']=='1'
    mounts=json.loads(run(['/usr/bin/docker','inspect','--format','{{json .Mounts}}',name],role='container_mount_metadata'))
    assert not any(m.get('Type') in ('bind','volume') for m in mounts)
    return int(state['Pid'])

def controlled_environment():
    env={'PATH':'/usr/local/bin:/usr/bin:/bin','LANG':'C.UTF-8',
         'HOME':str(STATE),'DOCKER_HOST':'unix:///var/run/docker.sock'}
    for key in ('STACK_BROWSER_TOKEN','STACK_BROWSER_SESSION_KEY','STACK_BROWSER_STORAGE','STACK_BROWSER_RESOURCE_HOSTS'):
        if key in os.environ:env[key]=os.environ[key]
    return env

def cleanup_owned(name,attempt):
    # A timed-out docker run may already have created the gated container.
    # Never stop an unrelated same-name container, even after an interrupted run.
    try:
        q=subprocess.run(['/usr/bin/docker','inspect','--format','{{index .Config.Labels "stack.controllerAttempt"}}',name],capture_output=True,text=True,timeout=15)
        if q.returncode:
            metadata['cleanup']={'containerAbsent':q.returncode==1 and 'No such' in q.stderr,'stopAttempted':False}
            return
        if q.stdout.strip()!=attempt:
            metadata['cleanup']={'ownershipMismatch':True,'stopAttempted':False};return
        q=subprocess.run(['/usr/bin/docker','stop','--time','5',name],capture_output=True,text=True,timeout=20)
        absent=subprocess.run(['/usr/bin/docker','container','inspect',name],capture_output=True,text=True,timeout=15)
        # Docker stop can return while --rm teardown is still in progress.
        # Wait for absence after a successful stop; never remove by name.
        deadline=time.monotonic()+15
        while q.returncode==0 and absent.returncode==0 and time.monotonic()<deadline:
            time.sleep(0.2)
            absent=subprocess.run(['/usr/bin/docker','container','inspect',name],capture_output=True,text=True,timeout=15)
        metadata['cleanup']={'stopAttempted':True,'stopExitCode':q.returncode,
                             'containerAbsent':absent.returncode==1 and 'No such' in absent.stderr}
    except BaseException as exc:
        metadata['cleanup']={'errorType':type(exc).__name__,'verified':False}

def main(probe=False):
    global metadata
    assert os.geteuid()==0
    os.umask(0o077)
    network=json.loads(CONFIG.read_text())
    policy.validate_dns(network['dnsServers'])
    image=IMAGE.read_text().strip()
    assert re.fullmatch(r'sha256:[0-9a-f]{64}',image)
    name='stack-browser-egress-probe' if probe else NAME
    metadata={'state':'gated','probeOnly':probe,'hostFirewallChainsChanged':False,
              'credentialsPrinted':False,'privateHostMounts':False}
    existing=subprocess.run(['/usr/bin/docker','container','inspect',name],capture_output=True)
    assert existing.returncode!=0,'A same-name container already exists; inspect before continuing'
    env=controlled_environment()
    if not probe:
        assert len(env.get('STACK_BROWSER_TOKEN',''))>=32
        assert env.get('STACK_BROWSER_SESSION_KEY')
    attempt=uuid.uuid4().hex
    try:
        run(container_parameters(name,network['probeAddress'] if probe else network['browserAddress'],image,network,probe,attempt),role='gated_container_start',env=env)
        pid=inspect_container(name)
        policy.install(pid,network['dnsServers'],run)
        proof=policy.prove(name,pid,network['gateway'],run)
        metadata.update(proof,nonRootContainer=True,readOnlyRoot=True,chromiumGateOpened=False)
        if probe:
            metadata['state']='real_egress_probe_passed';record();return
        run(['/usr/bin/docker','exec','--user','root',name,'/bin/sh','-c','touch /tmp/stack-browser-egress-ready'],role='chromium_launch_gate_open')
        metadata.update(state='chromium_launching',chromiumGateOpened=True)
        record()
        # Health verification is performed by the installer using the private
        # browser token. This service owns the container lifetime thereafter.
        wait=subprocess.run(['/usr/bin/docker','wait',name],capture_output=True,text=True)
        metadata.update(state='container_exited',containerExitCode=int(wait.stdout.strip()) if wait.returncode==0 and wait.stdout.strip().isdigit() else None)
        record()
        raise RuntimeError('Browser container exited; no sandbox fallback attempted')
    finally:
        # Ignore further termination signals while cleaning up only our container.
        for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,signal.SIG_IGN)
        cleanup_owned(name,attempt)
        record()

if __name__=='__main__':
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,request_stop)
    try:main('--probe-only' in sys.argv)
    except BaseException as error:
        metadata.update(state='stopped',step=step,errorType=type(error).__name__,rawDetailsSuppressed=True)
        record();print(json.dumps(metadata),flush=True);sys.exit(0 if isinstance(error,StopRequested) else 1)
