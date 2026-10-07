"""Fixed loopback readiness protocol. Import only from the trusted host helper."""
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time
import urllib.request
# Isolated child execution does not add its script directory to sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_safety import Held

MAX_RESPONSE = 8192


def _http(url, body=None, token='', timeout=3):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers)
    # No redirects, proxy origins, response bodies or credentials in receipts.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        raw = response.read(MAX_RESPONSE + 1)
        if len(raw) > MAX_RESPONSE:
            raise Held('response_limit')
        return json.loads(raw)


def http(url, body=None, token='', timeout=3):
    # A process deadline, unlike urllib's per-read socket timeout, also bounds
    # slow-drip HTTP bodies. Credentials travel through stdin, never argv/logs.
    result = subprocess.run(['/usr/bin/python3', '-I', str(Path(__file__)), '--http'],
        input=json.dumps({'url': url, 'body': body, 'token': token, 'timeout': timeout}).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode or len(result.stdout) > MAX_RESPONSE:
        raise Held('transport')
    return json.loads(result.stdout)


class Probe:
    def __init__(self, live, worker_token, browser_token='', browser_check=None):
        self.channel = live / '.jac/release-readiness'
        self.live = live
        self.worker_token = worker_token
        self.browser_token = browser_token
        self.browser_check = browser_check
        self.commit = None

    def ipc(self, action, *args):
        result = subprocess.run(['/usr/sbin/runuser', '-u', 'stack', '--',
            '/usr/bin/python3', '-I', str(Path(__file__).with_name('release_channel.py')),
            action, *args], cwd=self.live, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
        if result.returncode or len(result.stdout) > MAX_RESPONSE:
            raise Held('worker_round_trip')
        return json.loads(result.stdout)

    def __call__(self, commit, remaining):
        began = time.monotonic()
        def budget():
            left = remaining - (time.monotonic() - began)
            if left <= 0:
                raise Held('readiness_timeout')
            return min(3, left)
        # Reuse one fresh challenge through retries, replace it on recovery.
        if commit != self.commit:
            self.commit, self.nonce = commit, secrets.token_hex(16)
            self.ipc('prepare', commit, self.nonce)
        expected = {'commit': commit, 'nonce': self.nonce, 'protocol': 1}
        stage = 'api_smoke'
        # Check is <=12 seconds total, bounded by wait_ready's remaining budget.
        try:
            result = http('http://127.0.0.1:8000/function/release_smoke',
                          {'token': self.worker_token, 'nonce': self.nonce}, timeout=budget())
            if result.get('data', {}).get('result') != expected:
                raise Held(stage)
            stage = 'worker_round_trip'
            if self.ipc('read') != expected:
                raise Held(stage)
            stage = 'gateway'
            # Existing gateway must serve the expected application asset.
            value = http('http://127.0.0.1:8080/release-health', timeout=budget())
            if value != {'commit': commit, 'ready': True}:
                raise Held(stage)
            if self.browser_token:
                stage = 'browser_image'
                self.browser_check(min(2, budget()))
                stage = 'browser_smoke'
                result = http('http://127.0.0.1:8011/release-smoke', {'nonce': self.nonce},
                              token=self.browser_token, timeout=budget())
                if result != {'ready': True, 'nonce': self.nonce}:
                    raise Held(stage)
        except Exception:
            raise Held(stage) from None

    def close(self):
        try:
            self.ipc('close')
        except Exception:
            pass  # A stale challenge cannot satisfy a later nonce/revision.


if __name__ == '__main__':
    try:
        assert sys.argv[1:] == ['--http']
        value = json.loads(sys.stdin.buffer.read(8193))
        assert value['url'] in {'http://127.0.0.1:8000/function/release_smoke',
                                'http://127.0.0.1:8080/release-health',
                                'http://127.0.0.1:8011/release-smoke'}
        print(json.dumps(_http(**value)))
    except Exception:
        sys.exit(1)
