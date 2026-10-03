"""One CPU transcription at a time, after Stop. No inference or model downloads on Mac.

Reuse Interview Lab's base.en model and PCM validation, with a private CLI child
instead of its synchronous whisper-server HTTP request. No audio leaves the PC.
"""
import base64
import hashlib
import fcntl
from contextlib import contextmanager
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from agents.transcription_store import wav_info

_verified_model = None


def call(name, args):
    base = os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000').rstrip('/')
    request = urllib.request.Request(base + '/function/' + name,
                                    data=json.dumps(args).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=5) as response:
        data = json.load(response)['data']['result']
    if data.get('error'):
        raise ValueError(data['error'])
    return data


def runtime():
    global _verified_model
    if sys.platform == 'darwin':
        raise ValueError('Local transcription runs on the PC. No model is loaded on this Mac.')
    binary = Path(os.environ.get('STACK_TRANSCRIPTION_CLI', '.jac/transcription/bin/whisper-cli')).resolve()
    model = Path(os.environ.get('STACK_TRANSCRIPTION_MODEL', '.jac/transcription/models/ggml-base.en.bin')).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK) or not model.is_file():
        raise ValueError('Local transcription needs PC model setup. Your audio is saved; retry after setup.')
    manifest = json.loads(Path(__file__).with_name('transcription_model.json').read_text())
    binding_path=Path('.jac/transcription/runtime.json')
    try:binding=json.loads(binding_path.read_text())
    except (OSError,ValueError):raise ValueError('Local transcription runtime needs pinned PC setup. Recordings are saved.') from None
    manifest_commit=manifest['source_commit']
    if binding.get('source_commit')!=manifest_commit:raise ValueError('Local transcription runtime revision failed verification. Recordings are saved.')
    binary_stat=binary.stat()
    binary_key=(str(binary),binary_stat.st_size,binary_stat.st_mtime_ns,binding_path.stat().st_mtime_ns)
    stat = model.stat()
    key = (str(model), stat.st_size, stat.st_mtime_ns,binary_key)
    if key != _verified_model:
        if stat.st_size != manifest['bytes']:
            raise ValueError('The local transcription model failed verification. Your recording is saved.')
        with model.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if digest != manifest['sha256']:
            raise ValueError('The local transcription model failed verification. Your recording is saved.')
        with binary.open('rb') as source:
            if hashlib.file_digest(source,'sha256').hexdigest()!=binding.get('binary_sha256'):
                raise ValueError('Local transcription runtime failed integrity verification. Recordings are saved.')
        _verified_model = key
    return str(binary), str(model)


def stop_child(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=3)


def run_cli(binary, model, raw, update, scratch=None, deadline=900):
    work = Path(scratch or '.jac/transcription-work').resolve()
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='audio-', dir=work) as directory:
        directory = Path(directory)
        audio = directory / 'answer.wav'
        audio.write_bytes(raw)
        audio.chmod(0o600)
        output = directory / 'transcript'
        env = {key: os.environ[key] for key in ('PATH', 'SystemRoot', 'WINDIR') if key in os.environ}
        env.update(TMPDIR=str(directory), TMP=str(directory), TEMP=str(directory), OMP_NUM_THREADS='2', OPENBLAS_NUM_THREADS='1')
        began = time.monotonic()
        child = subprocess.Popen([binary, '-m', model, '-f', str(audio), '-t', '2', '-p', '1', '-ng',
                                  '-l', 'en', '-bs', '1', '-bo', '1', '-pp', '-oj', '-of', str(output)],
                                 cwd=directory, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        state = {'stage': 'loading', 'percent': None, 'load_ms': 0, 'transcribing_at': None}
        lock = threading.Lock()
        def diagnostics():
            # Drain bounded lines without saving transcript fragments or diagnostic paths.
            while line := child.stderr.readline(4096):
                with lock:
                    if b': processing ' in line and state['transcribing_at'] is None:
                        state.update(stage='transcribing', load_ms=(time.monotonic()-began)*1000,
                                     transcribing_at=time.monotonic())
                    if b'progress' in line:
                        match = re.search(rb'(\d{1,3})%', line)
                        if match:
                            state['percent'] = min(99, int(match[1]))
        reader = threading.Thread(target=diagnostics, daemon=True)
        reader.start()
        next_beat = 0
        try:
            while child.poll() is None:
                now = time.monotonic()
                if now-began > deadline:
                    raise ValueError('Transcription timed out. Your audio is saved; retry without recording again.')
                if now >= next_beat:
                    with lock:
                        snapshot = dict(state)
                    update(snapshot['stage'], snapshot['percent'], {'load_ms': snapshot['load_ms'],
                           'transcribe_ms': (now-snapshot['transcribing_at'])*1000 if snapshot['transcribing_at'] else 0})
                    next_beat = now + 2
                time.sleep(0.1)
            reader.join(timeout=2)
            if child.returncode:
                raise ValueError('The local transcription engine failed. Your audio is saved; retry after checking PC setup.')
            result_path = output.with_suffix('.json')
            if not result_path.is_file() or result_path.stat().st_size > 1024*1024:
                raise ValueError('The transcription engine did not return a valid result. Your audio is saved.')
            result = json.loads(result_path.read_text())
            segments = result.get('transcription', [])
            if not isinstance(segments, list) or len(segments) > 5000 or any(not isinstance(row, dict) or not isinstance(row.get('text'), str) for row in segments):
                raise ValueError('Invalid local transcription result. Your audio is saved.')
            text = ' '.join(row['text'].strip() for row in segments).strip()
            if not text or text.lower() in ('[blank_audio]', '[silence]', '(silence)', '[music]'):
                raise ValueError('No speech was transcribed. Your recording is saved; check it before retrying.')
            if len(text) > 30000:
                raise ValueError('The returned transcript is too long. Your recording is saved.')
            with lock:
                snapshot = dict(state)
            return {'text': text, 'load_ms': snapshot['load_ms'],
                    'transcribe_ms': (time.monotonic()-(snapshot['transcribing_at'] or began))*1000}
        finally:
            stop_child(child)
            reader.join(timeout=2)
            child.stderr.close()


def process(work, token, runner=run_cli):
    auth = {'token': token, **{key: work[key] for key in ('id', 'owner', 'lease')}}
    timings = {'decode_ms': 0, 'load_ms': 0, 'transcribe_ms': 0}
    def update(stage, percent=None, values=None):
        timings.update(values or {})
        # Rejected lease, cancellation, or unavailable API stops only this child.
        call('transcription_processing_progress', {**auth, 'stage': stage, 'percent': percent, 'timings': timings})
        from agents.transcription_readiness import publish
        publish({'status':'ready','stage':'ready','probe_passed':True,'missing_tools':[]})
    began = time.monotonic()
    try:
        update('decoding')
        raw = base64.b64decode(work['content'], validate=True)
        wav_info(raw)
        timings['decode_ms'] = (time.monotonic()-began)*1000
        update('loading')
        binary, model = runtime()
        return {**timings, **runner(binary, model, raw, update)}
    except ValueError as error:
        return {**timings, 'error': str(error)[:500]}
    except Exception:
        return {**timings, 'error': 'Local transcription was interrupted. Your audio is saved; retry when the PC is available.'}


@contextmanager
def lane_lock():
    directory=Path('.jac/transcription');directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (directory/'lane.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:yield False;return
        try:yield True
        finally:fcntl.flock(lock,fcntl.LOCK_UN)


def run_once(token):
    with lane_lock() as acquired:
        if not acquired:return False
        work=call('transcription_processing_claim',{'token':token})
        if work.get('idle'):return False
        result=process(work,token)
        call('transcription_processing_finish',{'token':token,**{key:work[key] for key in ('id','owner','lease')},'result':result})
        return True


def prepare_runtime(token):
    from agents.transcription_readiness import publish
    from agents.setup_transcription import setup
    with lane_lock() as acquired:
        if not acquired:return False
        report=call('transcription_processing_runtime',{'token':token,'action':'start'})
        generation=report['generation'];began=time.monotonic();latest={'status':'preparing','stage':'checking','message':'Checking local transcription.','probe_passed':False,'missing_tools':[]}
        def report_state(stage,message,**extra):
            latest.update(status='preparing',stage=stage,message=message,**extra)
            latest['setup_ms']=(time.monotonic()-began)*1000
            call('transcription_processing_runtime',{'token':token,'action':'report','generation':generation,'result':latest})
            publish(latest)
        try:
            if not sys.platform.startswith('linux'):raise ValueError('Local transcription runs on the PC; no model is loaded on this Mac.')
            report_state('checking','Checking the pinned local transcription engine.')
            try:binary,model=runtime()
            except ValueError:
                if os.environ.get('STACK_TRANSCRIPTION_AUTO_SETUP','1')!='1':raise ValueError('PC automatic transcription setup is disabled. Recordings are saved.')
                if os.environ.get('STACK_TRANSCRIPTION_CLI') or os.environ.get('STACK_TRANSCRIPTION_MODEL'):raise ValueError('The configured PC transcription runtime failed verification and was preserved.')
                setup(progress=report_state,deadline=600);binary,model=runtime()
            report_state('probe','Checking the local model with synthetic speech.')
            fixture=json.loads(Path(__file__).with_name('transcription_probe.json').read_text());raw=base64.b64decode(fixture['content'],validate=True)
            if hashlib.sha256(raw).hexdigest()!=fixture['sha256']:raise ValueError('Synthetic transcription fixture failed verification.')
            wav_info(raw)
            result=run_cli(binary,model,raw,lambda *args:report_state('probe','Checking the local model with synthetic speech.'),deadline=90)
            words=set(re.findall(r'[a-z]+',result['text'].lower()))
            if not {'recording','saved','tested','transcription'}<=words:raise ValueError('Local model returned an unexpected synthetic sample transcript. Recordings are saved; retry setup.')
            latest.update(status='ready',stage='ready',message='Local transcription ready.',probe_passed=True,missing_tools=[],
                          load_ms=result['load_ms'],transcribe_ms=result['transcribe_ms'],setup_ms=(time.monotonic()-began)*1000)
        except Exception as error:
            latest.update(status='unavailable',message=str(error)[:500] if isinstance(error,(ValueError,RuntimeError)) else 'Local transcription setup failed. Recordings are saved; retry setup.',setup_ms=(time.monotonic()-began)*1000)
        call('transcription_processing_runtime',{'token':token,'action':'report','generation':generation,'result':latest});publish(latest)
        return True


def main(token):
    from agents.transcription_readiness import publish
    first=True
    while True:
        try:
            state=call('transcription_processing_runtime',{'token':token})
            if first or state['status']=='pending':
                if prepare_runtime(token):first=False
                time.sleep(1);continue
            publish(state)
            if state['status']=='ready':
                if not run_once(token):time.sleep(1)
            else:time.sleep(3)
        except Exception:
            logging.getLogger('stack.transcription').warning('Transcription worker waiting; saved jobs remain available.')
            time.sleep(3)
