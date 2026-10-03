"""Pinned nonprivileged PC provisioning, invoked by the dedicated audio lane.

No system installers, service edits, credentials, or network/security grants.
All downloads and compilation are bounded; other agent lanes remain independent.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.request


def setup(check=False, progress=None, deadline=600):
    if not sys.platform.startswith('linux'):
        raise RuntimeError('Model downloads and inference run only on the Linux PC backend.')
    if os.geteuid()==0:raise RuntimeError('Transcription setup must run as the existing Stack service user, not root.')
    manifest=json.loads(Path(__file__).with_name('transcription_model.json').read_text())
    directory=Path('.jac/transcription').resolve();binary=directory/'bin/whisper-cli';model=directory/'models/ggml-base.en.bin'
    if check:
        from agents.transcription_worker import runtime
        runtime();return {'ready':True,'engine':'whisper.cpp','language':'en'}
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    began=time.monotonic();stage='checking';message='Checking local transcription setup.'
    def beat(new_stage=None, new_message=None, **extra):
        nonlocal stage,message
        if new_stage:stage=new_stage
        if new_message:message=new_message
        if time.monotonic()-began>deadline:raise RuntimeError('Local transcription setup timed out. Recordings are saved; retry setup.')
        if progress:progress(stage,message,**extra)
    missing=[name for name in ('git','cmake','cc','c++') if not shutil.which(name)]
    beat('toolchain','Checking existing PC build tools.',missing_tools=missing)
    if missing:raise RuntimeError('PC setup is missing '+', '.join(missing)+'. No system installer or privilege change was attempted.')
    if shutil.disk_usage(directory).free<1024**3:raise RuntimeError('PC transcription setup needs at least 1 GB free disk space. Recordings are saved.')
    env={k:os.environ[k] for k in ('PATH','LANG','LC_ALL','HTTPS_PROXY','HTTP_PROXY','NO_PROXY') if k in os.environ}
    env.update(TMPDIR=str(directory),XDG_CACHE_HOME=str(directory/'cache'),OMP_NUM_THREADS='2',
               GIT_TERMINAL_PROMPT='0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
    def run(args,cwd=None,capture=False):
        if args[0]=='git':args=['git','-c','core.hooksPath=/dev/null','-c','credential.helper=',*args[1:]]
        output=directory/'setup-command.log'
        with output.open('wb') as log:
            child=subprocess.Popen(args,cwd=cwd,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
            try:
                while child.poll() is None:beat();time.sleep(.2)
                if child.returncode:raise RuntimeError('Local transcription setup command failed: '+Path(args[0]).name+'. Recordings are saved; retry after correcting PC setup.')
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=3)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
        return output.read_text().strip() if capture else None
    # Limit progress writes/API calls while retaining setup's absolute deadline.
    original=progress;last_beat=0
    def throttled(stage,message,**extra):
        nonlocal last_beat
        now=time.monotonic()
        if original and (now-last_beat>=5 or extra or stage!=throttled.stage):
            original(stage,message,**extra);last_beat=now;throttled.stage=stage
    throttled.stage='';progress=throttled
    source=directory/'source'
    beat('source','Fetching the pinned official Whisper source.')
    if not source.exists():
        run(['git','init',str(source)]);run(['git','remote','add','origin','https://github.com/ggml-org/whisper.cpp.git'],source)
    if not (source/'.git').is_dir():raise RuntimeError('Existing transcription source is not the expected repository; it was preserved.')
    remote=run(['git','remote','get-url','origin'],source,True)
    if remote!='https://github.com/ggml-org/whisper.cpp.git':raise RuntimeError('Existing transcription source has a different origin; it was preserved.')
    if run(['git','status','--porcelain'],source,True):raise RuntimeError('Existing Whisper source has local changes; they were preserved.')
    try:existing=run(['git','rev-parse','--verify','HEAD'],source,True)
    except RuntimeError:existing=None
    if existing and existing!=manifest['source_commit']:raise RuntimeError('Existing Whisper source is at a different revision; it was preserved.')
    # Fetching the exact commit also recovers an interrupted initial checkout.
    run(['git','fetch','--depth','1','origin',manifest['source_commit']],source)
    run(['git','checkout','--detach',manifest['source_commit']],source)
    actual=run(['git','rev-parse','HEAD'],source,True)
    if actual!=manifest['source_commit']:raise RuntimeError('Whisper source failed pinned revision verification.')
    beat('building','Building the local CPU transcription engine (one build job).')
    build=source/'build'
    run(['cmake','-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF',
         '-DGGML_BACKEND_DL=OFF','-DGGML_CUDA=OFF','-DGGML_METAL=OFF','-DGGML_VULKAN=OFF',
         '-DGGML_BLAS=OFF','-DGGML_OPENMP=OFF','-DWHISPER_BUILD_TESTS=OFF','-DWHISPER_BUILD_EXAMPLES=ON'])
    run(['cmake','--build',str(build),'--target','whisper-cli','--parallel','1'])
    binary.parent.mkdir(parents=True,exist_ok=True)
    temporary=binary.with_suffix('.new');shutil.copy2(build/'bin/whisper-cli',temporary);temporary.chmod(0o700);os.replace(temporary,binary)
    beat('model','Downloading and verifying the pinned English model.',missing_tools=[])
    model.parent.mkdir(parents=True,exist_ok=True)
    def valid(path):
        if not path.is_file() or path.stat().st_size!=manifest['bytes']:return False
        with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()==manifest['sha256']
    if not model.exists():
        temporary=model.with_suffix('.download')
        try:
            with urllib.request.urlopen(manifest['url'],timeout=15) as response,temporary.open('wb') as output:
                count=0
                while chunk:=response.read(1024*1024):
                    beat();count+=len(chunk)
                    if count>manifest['bytes']:raise RuntimeError('Model download exceeded its pinned size.')
                    output.write(chunk)
            if not valid(temporary):raise RuntimeError('Model download failed size/SHA-256 verification.')
            temporary.chmod(0o600);os.replace(temporary,model)
        finally:temporary.unlink(missing_ok=True)
    if not valid(model):raise RuntimeError('Existing model failed verification and was preserved.')
    report={'source_commit':actual,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
            'model_sha256':manifest['sha256'],'threads':2,'concurrency':1,'language':'en'}
    temporary=directory/'runtime.new';temporary.write_text(json.dumps(report));temporary.chmod(0o600);os.replace(temporary,directory/'runtime.json')
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    try:print(json.dumps(setup(args.check),indent=2))
    except Exception as error:print(str(error),file=sys.stderr);sys.exit(1)
