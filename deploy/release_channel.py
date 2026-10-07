"""Run ONLY as stack: ephemeral worker challenge IPC, no privileged file writes."""
import json
import os
from pathlib import Path
import re
import sys


def channel(action, commit='', nonce=''):
    base = Path('.jac/release-readiness')
    if action == 'prepare':
        assert re.fullmatch('[0-9a-f]{40}', commit) and re.fullmatch('[0-9a-f]{32}', nonce)
        base.mkdir(mode=0o700, exist_ok=True)
        (base / 'reply.json').unlink(missing_ok=True)
        path = base / 'challenge.json'
        path.unlink(missing_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'commit': commit, 'nonce': nonce}, stream)
        return {}
    if action == 'read':
        fd = os.open(base / 'reply.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            raw = stream.read(8193)
        assert len(raw) <= 8192
        return json.loads(raw)
    if action == 'close':
        for name in ('challenge.json', 'reply.json'):
            (base / name).unlink(missing_ok=True)
        return {}
    raise ValueError('Unsupported channel action')


if __name__ == '__main__':
    try:
        assert os.geteuid() != 0
        print(json.dumps(channel(*sys.argv[1:])))
    except Exception:
        sys.exit(1)
