"""Side-effect-free release smoke protocol; no graph writes or provider calls.

Capture identity once at process import, so changing a marker cannot make an
already running API/worker claim to serve a new revision.
"""
import json
from pathlib import Path
import re
import secrets
from typing import Any

IDENTITY = Path('.release-identity.json')
CHANNEL = Path('.jac/release-readiness')
SHA = re.compile(r'[0-9a-f]{40}\Z')
NONCE = re.compile(r'[0-9a-f]{32}\Z')


def identity():
    try:
        value = json.loads(IDENTITY.read_bytes())
        return value['commit'] if SHA.fullmatch(value['commit']) else ''
    except (OSError, ValueError, KeyError, TypeError):
        return ''


REVISION = identity()


def api_smoke(nonce: str) -> dict[str, Any]:
    if not NONCE.fullmatch(nonce):
        return {'error': 'Invalid release challenge.'}
    return {'commit': REVISION, 'nonce': nonce, 'protocol': 1}


def worker_smoke(call, token):
    """Called by the actual adapter polling loop; acknowledge one fresh nonce.

Only the fixed release endpoint is called. No task, notification, user account,
model, browser session, mail, or graph mutation is created by this protocol.
"""
    try:
        raw = (CHANNEL / 'challenge.json').read_bytes()
        if len(raw) > 256:
            return
        request = json.loads(raw)
        nonce = request['nonce']
        if not NONCE.fullmatch(nonce) or request['commit'] != REVISION:
            return
        result = call('release_smoke', {'token': token, 'nonce': nonce})
        if result != {'commit': REVISION, 'nonce': nonce, 'protocol': 1}:
            return
        temp = CHANNEL / ('reply-' + secrets.token_hex(8) + '.tmp')
        temp.write_text(json.dumps(result))
        temp.chmod(0o600)
        temp.replace(CHANNEL / 'reply.json')
    except (OSError, ValueError, KeyError, TypeError):
        # An absent deployment challenge must not disrupt normal worker work.
        return
