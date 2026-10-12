#!/usr/bin/env python3
"""Reuse native verification only with matching GitHub run, tree and toolchain evidence."""
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REPO = 'matthewkooy2/Stack'
WORKFLOW = '.github/workflows/ios-swift.yml'
JOB = 'Native core (Xcode 27)'
PROOF = ROOT / '.jac/native-proof.json'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def api(path, raw=False):
    command = ['gh', 'api', 'repos/' + REPO + '/' + path]
    if path.endswith('/logs'):
        command += ['-H', 'Range: bytes=0-131071']
        # New gh versions reject ANSI in logs even when stdout is a pipe. Permit
        # captured bytes only for job logs; checkout_commit parses a bounded prefix
        # into one hex SHA and never sends these untrusted bytes to a terminal.
        if raw and re.fullmatch(r'actions/jobs/\d+/logs', path):
            help_text = subprocess.check_output(['gh', 'api', '--help'], text=True)
            if '--allow-escape-sequences' in help_text:
                command += ['--allow-escape-sequences']
    data = subprocess.check_output(command)
    return data if raw else json.loads(data)


def output(name, value):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as target:
            target.write(f'{name}={value}\n')
    print(f'{name}={value}')


def toolchain():
    version = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
    if version != 'Xcode 27.0\nBuild version 27A266a':
        raise ValueError('Expected Xcode 27.0 build 27A266a')
    generator = subprocess.check_output(['xcodegen', '--version'], text=True).strip()
    if not re.fullmatch(r'(?:Version: )?2\.46\.0', generator):
        raise ValueError('Expected XcodeGen 2.46.0 for verification and archive')
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
    runtime = next(r for r in runtimes if r['identifier'] == RUNTIME and r['isAvailable'])
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices'][RUNTIME]
    device = [d for d in devices if d['name'] == 'iPhone 18 Pro' and d['isAvailable']]
    if len(device) != 1 or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise ValueError('Require a disposable GitHub-hosted runner and one iPhone 18 Pro on iOS 27.0')
    return {'xcode': version, 'xcodegen': '2.46.0', 'runtime': RUNTIME, 'runtime_build': runtime['buildversion'],
            'device': 'iPhone 18 Pro'}


def runs(workflow, **query):
    suffix = '&'.join(f'{name}={value}' for name, value in query.items())
    return api('actions/workflows/' + workflow + '/runs?per_page=100&' + suffix)['workflow_runs']


def release_changes(commit):
    parents = git('rev-list', '--parents', '-n', '1', commit).split()
    if len(parents) > 1:
        return git('diff', '--name-only', parents[1], commit).splitlines()
    return git('diff-tree', '--root', '--no-commit-id', '--name-only', '-r', commit).splitlines()


def checkout_commit(job):
    # GitHub drops PR associations from old runs once a PR closes. The pinned
    # checkout action's first Git log command still records the actual tested SHA.
    log = api(f"actions/jobs/{job['id']}/logs", raw=True)[:131072].decode('utf-8-sig')
    match = re.search(r'(?m)^20\d\d-\S+ \[command\]\S*git log -1 --format=%H\r?\n'
                      r'20\d\d-\S+ ([0-9a-f]{40})\r?$', log)
    if not match:
        raise ValueError('Missing GitHub checkout identity; verify actual main')
    return match.group(1)


def proof_for(run):
    name = f"native-proof-{run['id']}-{run['run_attempt']}"
    artifacts = api(f"actions/runs/{run['id']}/artifacts?per_page=100")['artifacts']
    matches = [a for a in artifacts if a['name'] == name and not a['expired']]
    if len(matches) != 1 or matches[0]['size_in_bytes'] > 65536:
        raise ValueError('Missing or ambiguous current-attempt native proof')
    content = api(f"actions/artifacts/{matches[0]['id']}/zip", raw=True)
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        if archive.namelist() != ['native-proof.json'] or archive.getinfo('native-proof.json').file_size > 16384:
            raise ValueError('Invalid proof archive')
        return json.loads(archive.read('native-proof.json'))


def validate(run, proof, tree, machine, depth=0):
    if depth > 1 or run['path'] != WORKFLOW or run['status'] != 'completed' or run['conclusion'] != 'success':
        raise ValueError('Native source workflow is not successful')
    if run['head_repository']['full_name'] != REPO or run['event'] not in ('push', 'pull_request'):
        raise ValueError('Native source is not a trusted repository push or PR')
    if proof['run_id'] != run['id'] or proof['attempt'] != run['run_attempt'] or proof['toolchain'] != machine:
        raise ValueError('Native run/attempt/toolchain mismatch')
    if not re.fullmatch(r'[0-9a-f]{40}', str(proof['commit'])):
        raise ValueError('Invalid native commit identity')
    commit = api('git/commits/' + proof['commit'])
    if proof['tree'] != tree or commit['tree']['sha'] != tree:
        raise ValueError('The actual release tree differs from native verification')
    jobs = api(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100")['jobs']
    jobs = [j for j in jobs if j['name'] == JOB]
    if len(jobs) != 1 or jobs[0]['conclusion'] != 'success' or jobs[0]['runner_group_name'] != 'GitHub Actions':
        raise ValueError('Expected successful isolated native job')
    if run['event'] == 'push':
        if run['head_branch'] != 'main' or proof['commit'] != run['head_sha']:
            raise ValueError('Native push did not verify this exact main commit')
    else:
        prs = run['pull_requests']
        if any(pr['head']['repo']['id'] != run['repository']['id'] for pr in prs):
            raise ValueError('Fork or ambiguous PR evidence cannot authorize release')
        if checkout_commit(jobs[0]) != proof['commit']:
            raise ValueError('Manifest differs from GitHub-owned checkout identity')
        if len(commit['parents']) != 2 or commit['parents'][1]['sha'] != run['head_sha']:
            raise ValueError('PR evidence did not test its synthetic merge commit')
        # Derive the merged code ourselves from GitHub-owned base/head identities.
        # A PR-produced manifest cannot choose a different tree with fabricated merge parents.
        parents = [p['sha'] for p in commit['parents']]
        git('fetch', '--no-tags', 'origin', *parents)
        if git('merge-tree', '--write-tree', *parents).splitlines()[0] != tree:
            raise ValueError('Proof tree differs from the actual base/head merge')
    # No fallback to an earlier green run after a newer failure, cancellation or pending run.
    latest = runs('ios-swift.yml', head_sha=run['head_sha'], event=run['event'])[0]
    if latest['id'] != run['id'] or latest['run_attempt'] != run['run_attempt']:
        raise ValueError('Native proof was superseded')
    steps = {s['name']: s['conclusion'] for s in jobs[0]['steps']}
    if steps.get('Publish native proof') != 'success':
        raise ValueError('Native proof publication was not verified by GitHub')
    if proof.get('reused_run'):
        if run['event'] != 'push' or steps.get('Verify identical native tree') != 'success':
            raise ValueError('Invalid native reuse')
        source = api(f"actions/runs/{int(proof['reused_run'])}")
        validate(source, proof_for(source), tree, machine, depth + 1)
    elif any(steps.get(name) != 'success' for name in ('Run selected native cases', 'Compile unsigned Release')):
        raise ValueError('Native tests or Release build did not succeed')


def record(machine):
    if git('status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Tracked source changed during native verification')
    proof = {'commit': git('rev-parse', 'HEAD'), 'tree': git('rev-parse', 'HEAD^{tree}'),
             'run_id': int(os.environ['GITHUB_RUN_ID']), 'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
             'toolchain': machine, 'reused_run': int(os.environ.get('NATIVE_REUSED_RUN', '0'))}
    PROOF.parent.mkdir(parents=True, exist_ok=True)
    PROOF.write_text(json.dumps(proof, sort_keys=True) + '\n')


def reuse(machine):
    output('reused_run', 0)
    if os.environ['GITHUB_EVENT_NAME'] != 'push':
        return
    tree = git('rev-parse', 'HEAD^{tree}')
    # One recent PR candidate, not an unbounded search for a convenient green tree.
    for run in runs('ios-swift.yml', event='pull_request')[:1]:
        try:
            proof = proof_for(run)
            if proof['tree'] == tree:
                validate(run, proof, tree, machine)
                output('reused_run', run['id'])
                return
        except (ValueError, KeyError, IndexError, subprocess.CalledProcessError):
            continue
    print('No reusable native result: execute the selected cases on actual main.')


def release(machine):
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    source = event.get('workflow_run')
    if source:
        if source['event'] != 'push' or source['head_branch'] != 'main' or source['head_repository']['full_name'] != REPO:
            raise ValueError('Release requires this repository main-push verification')
        commit = source['head_sha']
    else:
        if os.environ['GITHUB_REF'] != 'refs/heads/main':
            raise ValueError('Manual release requires main')
        commit = os.environ['GITHUB_SHA']
    if api('git/ref/heads/main')['object']['sha'] != commit:
        raise ValueError('Release candidate is no longer current main')
    git('fetch', '--no-tags', 'origin', commit)
    git('checkout', '--detach', commit)
    tree = git('rev-parse', 'HEAD^{tree}')
    native = runs('ios-swift.yml', head_sha=commit, event='push')[0]
    validate(native, proof_for(native), tree, machine)
    # Backend deployment is independent; native upload waits for its relevant same-commit core check.
    deadline = time.monotonic() + (600 if source else 0)
    while True:
        backend = runs('ci.yml', head_sha=commit, event='push')
        if backend and backend[0]['status'] == 'completed':
            if backend[0]['conclusion'] != 'success':
                raise ValueError('Exact-commit backend/security CI failed')
            jobs = api(f"actions/runs/{backend[0]['id']}/attempts/{backend[0]['run_attempt']}/jobs?per_page=100")['jobs']
            if {j['name']: j['conclusion'] for j in jobs} != {'Backend and security': 'success', 'CI passed': 'success'}:
                raise ValueError('Required backend/security jobs did not succeed')
            break
        if time.monotonic() >= deadline:
            raise ValueError('Exact-commit backend/security CI is missing or pending')
        time.sleep(15)
    # Docs-only main pushes never create automatic beta uploads. Manual upload remains explicit.
    changes = release_changes(commit)
    relevant = any(p.startswith(('ios/', 'scripts/ci/ios-', 'scripts/ci/resume-review/',
                                 '.github/actions/prepare-resume-review-fixture/'))
                   or p in (WORKFLOW, '.github/workflows/swift-testflight.yml', 'mobile/feature-rpcs.js')
                   for p in changes)
    output('upload', str(not source or relevant).lower())
    output('release_commit', commit)
    if api('git/ref/heads/main')['object']['sha'] != commit:
        raise ValueError('Main advanced while waiting for verification')
    record(machine)


if __name__ == '__main__':
    os.chdir(ROOT)
    mode = sys.argv[1]
    machine = toolchain()
    {'record': record, 'reuse': reuse, 'release': release}[mode](machine)
