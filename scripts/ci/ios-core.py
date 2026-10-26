#!/usr/bin/env python3
"""Select existing XCTest cases and reject missing, skipped or failing cases."""
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SELECTION = ROOT / 'scripts/ci/ios-core-tests.txt'


def selected():
    cases = [line.strip() for line in SELECTION.read_text().splitlines()
             if line.strip() and not line.startswith('#')]
    if len(set(cases)) != 30 or len(cases) != 30:
        raise ValueError('Expected exactly 30 unit cases without duplicates')
    if sum(case.startswith('StackTests/') for case in cases) != 30:
        raise ValueError('Expected exactly 30 unit cases')
    for case in cases:
        if not re.fullmatch(r'(StackTests|StackUITests)/\w+/test\w+', case):
            raise ValueError('Invalid selected XCTest identity: ' + case)
        target, owner, method = case.split('/')
        sources = [path.read_text() for path in (ROOT / 'ios' / target).glob('*.swift')]
        if not any(re.search(r'final class ' + owner + r'\b', source)
                   and re.search(r'func ' + method + r'\(', source) for source in sources):
            raise ValueError('Selected XCTest is absent: ' + case)
    return cases


def require_passed(log):
    missing = []
    for case in selected():
        target, owner, method = case.split('/')
        pattern = r"Test Case '-\[" + re.escape(target + '.' + owner + ' ' + method) + r"\]' passed"
        if len(re.findall(pattern, log)) != 1:
            missing.append(case)
    if missing:
        raise ValueError('Selected cases did not execute and pass exactly once: ' + ', '.join(missing))


if __name__ == '__main__':
    if len(sys.argv) == 2:
        require_passed(Path(sys.argv[1]).read_text())
        print('All 30 selected XCTest cases executed and passed.')
    else:
        print('\n'.join('-only-testing:' + case for case in selected()))
