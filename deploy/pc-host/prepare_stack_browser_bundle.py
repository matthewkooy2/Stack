"""Prepare public source only; no installation, credentials or live changes."""
import hashlib, json, pathlib, shutil
SOURCE=pathlib.Path('/home/mkooy/src/Stack-integrate-agent-features-def5e9d-20260930')
OUTPUT=pathlib.Path(__file__).resolve().parent/'stack-browser-prepared'
FILES=('deploy/browser.Dockerfile','deploy/browser.jac.toml','deploy/browser-entrypoint',
       'deploy/browser-service.jac','deploy/install-browser.jac','agents/browser_service.jac',
       'agents/browser.jac','agents/linkedin.jac','agents/contracts.jac','discovery/transport.py')
manifest=[]
for name in FILES:
    source=SOURCE/name
    dest=OUTPUT/'context'/name
    dest.parent.mkdir(parents=True,exist_ok=True)
    if dest.exists(): assert dest.read_bytes()==source.read_bytes()
    else: shutil.copyfile(source,dest)
    manifest.append({'path':name,'sha256':hashlib.sha256(source.read_bytes()).hexdigest()})
seccomp=SOURCE/'deploy/browser-seccomp.json'
dest=OUTPUT/'browser-seccomp.json'
if dest.exists(): assert dest.read_bytes()==seccomp.read_bytes()
else: shutil.copyfile(seccomp,dest)
result={'prepared':True,'files':manifest,'seccompSha256':hashlib.sha256(seccomp.read_bytes()).hexdigest(),
        'privateFilesCopied':False,'imagesBuilt':False,'dependenciesInstalled':False,
        'credentialsCreated':False,'networkChanged':False,'servicesChanged':False}
(OUTPUT/'preparation-metadata.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('files','seccompSha256')}))
