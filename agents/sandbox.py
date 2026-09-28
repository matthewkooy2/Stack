"""Untrusted code runs only in a disposable gVisor container, never on the API host."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid
from agents.prep import problem, evaluate_outputs


def container_command(directory, name):
    image = os.environ.get('STACK_SANDBOX_IMAGE', '')
    if '@sha256:' not in image:
        raise ValueError('Code execution is unavailable until a pinned sandbox image is configured.')
    return ['docker', 'run', '--rm', '--name', name, '--runtime=runsc', '--network=none',
            '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
            '--memory=256m', '--memory-swap=256m', '--cpus=0.5', '--pids-limit=64',
            '--ulimit', 'fsize=16384:16384', '--ulimit', 'nofile=64:64',
            '--user=65534:65534', '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m',
            '--mount', 'type=bind,source=' + str(directory) + ',target=/work,readonly',
            image, 'python3', '-I', '/work/harness.py']


def bounded_process(command, limit=65536, seconds=25):
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env={'PATH': os.environ.get('PATH', '/usr/bin:/bin')})
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + seconds
    try:
        while selector.get_map():
            if time.monotonic() > deadline:
                raise ValueError('Execution exceeded the time limit.')
            for key, _ in selector.select(0.1):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > limit:
                    raise ValueError('Execution exceeded the output limit.')
        return proc.wait(timeout=2), output.decode(errors='replace')
    finally:
        selector.close()
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        proc.stdout.close()


def execute(session):
    p = problem(session['problem_id'])
    language = session['language']
    if language not in p['languages']:
        raise ValueError('This exercise does not execute code.')
    if len(session['code']) > 30000:
        raise ValueError('Code is too long.')
    name = 'stack-prep-' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='stack-prep-') as tmp:
        directory = Path(tmp)
        directory.chmod(0o755)
        code_path = directory / ('answer.cpp' if language == 'cpp' else 'answer.txt')
        code_path.write_text(session['code'])
        if language == 'cpp':
            calls = []
            for t in p['tests']:
                if p['id'] == 'two-sum':
                    values, target = t['args']
                    calls.append('{auto v=solve(vector<int>{' + ','.join(map(str, values)) + '},' + str(target) + '); cout<<"["; for(size_t i=0;i<v.size();i++){if(i)cout<<",";cout<<v[i];}cout<<"]\\n";}')
                else:
                    calls.append('cout<<(solve(string(' + json.dumps(t['args'][0]) + '))?"true":"false")<<"\\n";')
            code_path.write_text('#include <bits/stdc++.h>\nusing namespace std;\n' + session['code'] + '\nint main(){' + ''.join(calls) + '}')
        harness = '''import json, sqlite3, subprocess, resource, sys
resource.setrlimit(resource.RLIMIT_CPU, (12,12))
tests=json.loads(%r)
language=%r
if language=='cpp':
 r=subprocess.run(['g++','-std=c++20','-O0','/work/answer.cpp','-o','/tmp/answer'],capture_output=True,timeout=18)
 if r.returncode: print(r.stderr.decode(errors='replace')[:12000],file=sys.stderr);sys.exit(2)
 sys.exit(subprocess.run(['/tmp/answer'],timeout=5).returncode)
code=open('/work/answer.txt').read()
for test in tests:
 if language=='sql':
  db=sqlite3.connect(':memory:');db.execute('CREATE TABLE applications(id INTEGER,company TEXT,status TEXT)')
  db.executemany('INSERT INTO applications VALUES(?,?,?)',test['rows'])
  db.set_authorizer(lambda action,*args: sqlite3.SQLITE_OK if action in (sqlite3.SQLITE_SELECT,sqlite3.SQLITE_READ,sqlite3.SQLITE_FUNCTION,sqlite3.SQLITE_RECURSIVE) and not (action==sqlite3.SQLITE_FUNCTION and args[1]=='load_extension') else sqlite3.SQLITE_DENY)
  db.set_progress_handler(lambda: 1,1000000)
  result=[list(row) for row in db.execute(code).fetchmany(1000)];db.close()
 else:
  scope={};exec(compile(code,'answer.py','exec'),scope);result=scope['solve'](*test['args'])
 print(json.dumps(result),flush=True)
''' % (json.dumps(p['tests']), language)
        (directory / 'harness.py').write_text(harness)
        try:
            status, output = bounded_process(container_command(directory, name))
            if status:
                return {'passed': 0, 'total': len(p['tests']), 'error': output[:12000], 'execution_status': 'error'}
            try:
                values = [json.loads(line) for line in output.splitlines()]
            except ValueError:
                return {'passed': 0, 'total': len(p['tests']), 'error': 'Unexpected program output.', 'output': output[:2000]}
            return evaluate_outputs(p['id'], values)
        finally:
            # Killing the docker client does not necessarily stop its container.
            try:
                subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
