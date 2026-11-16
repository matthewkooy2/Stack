#!/usr/bin/env python3
"""Route existing checks; unavailable identity/diff always means full verification."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ALL = {'backend': True, 'native': True, 'backend_groups': 'all'}
PROSE = {'README.md', 'AGENTS.md', 'THIRD_PARTY_NOTICES.txt'}
SHARED_WEB = {'web/apple-auth.js', 'web/google-auth.js', 'web/style.css'}
# Audit individual paths. New files in these directories still run all groups.
FEATURE_PATHS = {
    'discovery/branding.py': ('jobs',),
    'discovery/card.py': ('jobs', 'applications'),
    'discovery/photos.py': ('jobs',),
    'discovery/ranking.py': ('jobs',),
    'web/jobs-lab.html': ('jobs',),
    'agents/job_score.jac': ('jobs', 'resume'),
    'agents/record_resume.py': ('jobs', 'resume', 'prep', 'applications'),
    'agents/resume_details.py': ('jobs', 'resume', 'prep', 'applications'),
    'agents/resume_processing.jac': ('resume', 'applications'),
    'agents/resume_templates.jac': ('resume',),
    'agents/templates/awesome-cv.tex': ('resume',),
    'agents/templates/bill-ryan.tex': ('resume',),
    'agents/templates/classic.tex': ('resume',),
    'agents/templates/deedy.tex': ('resume',),
    'agents/templates/jake.tex': ('resume',),
    'agents/templates/jan-kuster.tex': ('resume',),
    'agents/templates/sb2nov.tex': ('resume',),
    'web/BulletBank.jac': ('resume',),
    'agents/contacts.jac': ('network',),
    'agents/linkedin.jac': ('network',),
    'agents/interview.py': ('prep', 'jobs', 'resume', 'applications'),
    'agents/prep.jac': ('prep',),
    'agents/transcription_store.py': ('prep',),
    'agents/transcription_worker.py': ('prep',),
    'core/transcription.jac': ('prep',),
    'web/Interview.js': ('prep',),
    'agents/autofill.py': ('applications',),
}


def select(paths):
    result = {'backend': False, 'native': False}
    groups = set()
    full_backend = False
    for path in paths:
        # Only explicit prose locations are exempt. Fixture READMEs, executable
        # docs/config and unrecognized paths retain full verification.
        if path in PROSE or (path.startswith('docs/') and path.endswith('.md')):
            continue
        result['backend'] = True
        # The web client has no Swift source/build/runtime dependency. Everything
        # else may affect shared API payloads, fixtures, dependencies or policy.
        if not path.startswith('web/'):
            result['native'] = True
        if path in SHARED_WEB:
            continue
        if path in FEATURE_PATHS:
            groups.update(FEATURE_PATHS[path])
        else:
            full_backend = True
    if full_backend:
        result['backend_groups'] = 'all'
    elif result['backend']:
        result['backend_groups'] = ','.join(sorted(groups)) or 'shared'
    else:
        result['backend_groups'] = 'none'
    return result


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, timeout=30, stderr=subprocess.PIPE)


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value) or value == '0' * 40:
        raise ValueError('Missing commit identity')
    return value


def changed_paths(event, name):
    head = git('rev-parse', 'HEAD').decode().strip()
    if name == 'pull_request':
        pr = event['pull_request']
        base, branch = sha(pr['base']['sha']), sha(pr['head']['sha'])
        parents = git('rev-list', '--parents', '-n', '1', head).decode().split()
        if parents != [head, base, branch]:
            raise ValueError('Checkout is not the event synthetic merge')
        # Include changes on either side since divergence: tests execute the
        # merged tree, so base updates must not hide behind a prose-only branch.
        before = git('merge-base', base, branch).decode().strip()
    elif name == 'push':
        before = sha(event['before'])
        if head != sha(event['after']):
            raise ValueError('Checkout does not match pushed commit')
    else:
        raise ValueError('Manual or unsupported event requires all checks')
    return paths_between(before, head)


def paths_between(before, head):
    # Disable rename detection so both old and new paths are classified. NUL
    # delimiters preserve spaces/newlines and deletions without API truncation.
    data = git('diff', '--no-ext-diff', '--no-textconv', '--no-renames',
               '--name-only', '-z', before, head, '--')
    if data and not data.endswith(b'\0'):
        raise ValueError('Incomplete changed-path data')
    return [p.decode('utf-8', errors='strict') for p in data.split(b'\0') if p]


def upload_relevant(paths):
    # Preserve the existing automatic native upload map.
    return any(path.startswith(('ios/', 'scripts/ci/ios-', 'scripts/ci/resume-review/',
                                '.github/actions/prepare-resume-review-fixture/'))
               or path in ('.github/workflows/ios-swift.yml', '.github/workflows/swift-testflight.yml',
                           'mobile/feature-rpcs.js') for path in paths)


def pending_native_upload(head):
    records = json.loads(subprocess.check_output([
        'gh', 'api', f'repos/{os.environ["GITHUB_REPOSITORY"]}/deployments'
        '?environment=stack-testflight&task=stack-swift-testflight-confirmed&per_page=1',
    ], timeout=30))
    if not records:
        return True  # The first confirmed upload establishes the baseline.
    before = sha(records[0]['sha'])
    git('merge-base', '--is-ancestor', before, head)
    return upload_relevant(paths_between(before, head))


def verified_backend_base(event, name):
    """Only discard unchanged feature tests when main already verified those inputs."""
    try:
        if name == 'push' and event['ref'] == 'refs/heads/main':
            base = sha(event['before'])
        elif name == 'pull_request' and event['pull_request']['base']['ref'] == 'main':
            base = sha(event['pull_request']['base']['sha'])
        else:
            return False
        repository = os.environ['GITHUB_REPOSITORY']
        prefix = f'repos/{repository}/actions'
        result = json.loads(subprocess.check_output([
            'gh', 'api', '--method', 'GET', f'{prefix}/workflows/ci.yml/runs',
            '-f', 'branch=main', '-f', 'event=push', '-f', f'head_sha={base}', '-F', 'per_page=1',
        ], timeout=15))
        if result['total_count'] != 1:
            return False
        run, = result['workflow_runs']
        if (run['event'], run['head_branch'], run['head_sha'], run['head_repository']['full_name'],
                run['status'], run['conclusion']) != ('push', 'main', base, repository, 'completed', 'success'):
            return False
        run_id, attempt = run['id'], run['run_attempt']
        if type(run_id) is not int or type(attempt) is not int or min(run_id, attempt) < 1:
            return False
        jobs = json.loads(subprocess.check_output([
            'gh', 'api', f'{prefix}/runs/{run_id}/attempts/{attempt}/jobs?per_page=100',
        ], timeout=15))['jobs']
        return len(jobs) == 2 and {job['name']: job['conclusion'] for job in jobs} == {
            'Backend and security': 'success', 'CI passed': 'success',
        }
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.SubprocessError):
        return False


def selection(event, name, include_upload=False, native_release=False, backend_release=False):
    try:
        paths = changed_paths(event, name)
        result = select(paths)
        if backend_release and result['backend_groups'] != 'all' and not verified_backend_base(event, name):
            print('Full backend verification: no successful CI proof for the exact main baseline.')
            result.update(backend=True, backend_groups='all')
        if include_upload:
            result['native_upload'] = upload_relevant(paths)
            if native_release and name == 'push' and event.get('ref') == 'refs/heads/main':
                result['native_upload'] = pending_native_upload(sha(event['after']))
                result['native'] |= result['native_upload']
        return result
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.SubprocessError) as error:
        print(f'Full verification: diff unavailable or unsupported ({type(error).__name__}).')
        return dict(ALL, native_upload=True) if include_upload else dict(ALL)


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    except (KeyError, ValueError, OSError):
        event = {}
    result = selection(event, os.environ.get('GITHUB_EVENT_NAME', ''), include_upload=True,
                       native_release='--native-release' in sys.argv[1:],
                       backend_release='--backend-release' in sys.argv[1:])
    lines = ''.join(f'{name}={str(value).lower()}\n' for name, value in result.items())
    print(lines, end='')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(lines)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as summary:
            summary.write('Existing check selection (credential scans always run):\n\n')
            for name in ('backend', 'native', 'native_upload'):
                summary.write(f'- {name}: {"run" if result[name] else "not applicable"}\n')
            summary.write(f'- Backend feature groups: {result["backend_groups"]}\n')


if __name__ == '__main__':
    main()
