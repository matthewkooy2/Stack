"""Offline manifest, syntax checks and public-key verification. No sudo/network."""
import hashlib,json,os,pathlib,subprocess,tempfile
import install_stack_browser as installer
P=pathlib.Path
here=P(__file__).resolve().parent
files=list(installer.PUBLIC_FILES)+['context/'+row['path'] for row in json.loads((here/'preparation-metadata.json').read_text())['files']]
manifest={'sha256':{name:hashlib.sha256((here/name).read_bytes()).hexdigest() for name in sorted(files)},'preparedOnly':True}
(here/'installer-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
checks={}
loaded=json.loads((here/'installer-manifest.json').read_text())
assert set(loaded['sha256'])==set(files)
for name,h in loaded['sha256'].items():assert hashlib.sha256((here/name).read_bytes()).hexdigest()==h
checks['writtenManifestVerifiedAgainstFiles']=True
source_metadata=json.loads((here/'preparation-metadata.json').read_text())
for row in source_metadata['files']:
    assert hashlib.sha256((here/'context'/row['path']).read_bytes()).hexdigest()==row['sha256']
assert hashlib.sha256((here/'browser-seccomp.json').read_bytes()).hexdigest()==source_metadata['seccompSha256']
checks['curatedContextAndSeccompMatchSourceFingerprints']=True
for name in ('browser_runtime.py','browser_policy.py','browser_preflight.py','install_stack_browser.py','test_browser_install_offline.py'):
    compile((here/name).read_text(),name,'exec')
checks['pythonSyntaxValid']=True
q=subprocess.run(['/bin/bash','-n',str(here.parent/'run_stack_browser_install.sh')],capture_output=True,text=True)
assert q.returncode==0
checks['attendedShellSyntaxValid']=True
with tempfile.TemporaryDirectory(prefix='stack-browser-offline-') as tmp:
    folder=P(tmp);(folder/'gnupg').mkdir(mode=0o700)
    q=subprocess.run(['/usr/bin/gpg','--batch','--no-options','--with-colons','--show-keys',str(here/'docker-repository.asc')],capture_output=True,text=True,env={**os.environ,'GNUPGHOME':str(folder/'gnupg')})
    assert q.returncode==0
    fingerprints=[line.split(':')[9] for line in q.stdout.splitlines() if line.startswith('fpr:')]
    assert fingerprints[0]=='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
    checks['officialDockerPublicKeyFingerprintVerified']=True
    (folder/'stack-browser.service').write_bytes((here/'stack-browser.service').read_bytes())
    # Only a transient dependency stub; no units are installed or started.
    (folder/'docker.service').write_text('[Unit]\nDescription=Offline syntax dependency\n[Service]\nExecStart=/usr/bin/true\n')
    q=subprocess.run(['/usr/bin/systemd-analyze','verify',str(folder/'stack-browser.service'),str(folder/'docker.service')],capture_output=True,text=True,env={**os.environ,'SYSTEMD_UNIT_PATH':str(folder)+':/usr/lib/systemd/system'})
    checks['browserUnitSyntaxValid']=q.returncode==0
    checks['browserUnitVerifierExitCode']=q.returncode
    assert q.returncode==0, 'Unit syntax check failed; inspect sanitized exit status'
checks.update(noLiveInstallation=True,noLiveNetworkChanges=True,noCredentialsCreated=True,manifestFileCount=len(files))
(here/'offline-preparation-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
print(json.dumps(checks))
