#!/usr/bin/env python3
"""Route existing checks; unavailable identity/diff always means full verification."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ALL = {'backend': True, 'native': True}
PROSE = {'README.md', 'AGENTS.md', 'THIRD_PARTY_NOTICES.txt'}


def select(paths):
    result = {'backend': False, 'native': False}
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
    # Disable rename detection so both old and new paths are classified. NUL
    # delimiters preserve spaces/newlines and deletions without API truncation.
    data = git('diff', '--no-ext-diff', '--no-textconv', '--no-renames',
               '--name-only', '-z', before, head, '--')
    if data and not data.endswith(b'\0'):
        raise ValueError('Incomplete changed-path data')
    return [p.decode('utf-8', errors='strict') for p in data.split(b'\0') if p]


def upload_relevant(paths):
    # Preserve the existing automatic native upload map, over the whole push.
    return any(path.startswith(('ios/', 'scripts/ci/ios-', 'scripts/ci/resume-review/',
                                '.github/actions/prepare-resume-review-fixture/'))
               or path in ('.github/workflows/ios-swift.yml', '.github/workflows/swift-testflight.yml',
                           'mobile/feature-rpcs.js') for path in paths)


def selection(event, name, include_upload=False):
    try:
        paths = changed_paths(event, name)
        result = select(paths)
        if include_upload:
            result['native_upload'] = upload_relevant(paths)
        return result
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.SubprocessError) as error:
        print(f'Full verification: diff unavailable or unsupported ({type(error).__name__}).')
        return dict(ALL, native_upload=True) if include_upload else dict(ALL)


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    except (KeyError, ValueError, OSError):
        event = {}
    result = selection(event, os.environ.get('GITHUB_EVENT_NAME', ''), include_upload=True)
    lines = ''.join(f'{name}={str(value).lower()}\n' for name, value in result.items())
    print(lines, end='')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(lines)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as summary:
            summary.write('Existing check selection (credential scans always run):\n\n' +
                          '\n'.join(f'- {name}: {"run" if value else "not applicable"}'
                                    for name, value in result.items()) + '\n')


if __name__ == '__main__':
    main()
