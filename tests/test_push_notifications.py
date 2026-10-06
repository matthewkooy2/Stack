"""Real worker/API/storage with a controlled HTTP Expo transport; no outbound pushes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
import urllib.request

if os.environ.get('JAC_DB_URL'):
    raise RuntimeError('Push verification requires disposable embedded storage; unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from agents import notifications, worker, security

ROOT = Path(__file__).resolve().parents[1]
WORKER = 'synthetic-push-worker'
DEVICE = 'ExpoPushToken[synthetic-device-'

@contextmanager
def controlled_transport(origin):
    """Rewrite only the fixed Expo destination at the HTTP opener boundary."""
    original = urllib.request.build_opener
    class Transport:
        def open(self, request, timeout=30):
            if not request.full_url.startswith('https://exp.host/--/api/v2/push/'):
                return original(security.NoRedirect).open(request, timeout=timeout)
            local = urllib.request.Request(origin + request.full_url.split('/push/', 1)[1],
                data=request.data, headers=dict(request.header_items()), method=request.get_method())
            return original(security.NoRedirect).open(local, timeout=timeout)
    with patch.object(urllib.request, 'build_opener', return_value=Transport()):
        yield

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.requests.append((self.path, body, dict(self.headers)))
        status = 200
        if self.path == '/send':
            device = body['to']; queue = self.server.replies.get(device, [])
            result = queue.pop(0) if queue else {'status': 'ok', 'id': 'ticket-' + str(len(self.server.requests))}
            if isinstance(result, int): status = result; result = {}
            self.server.sent.append(device)
            if result.get('id'): self.server.tickets[result['id']] = device
            response = {'data': result}
        else:
            ticket = body['ids'][0]
            result = self.server.receipts.get(ticket, {'status': 'ok'})
            if isinstance(result, list): result = result.pop(0) if result else {'status': 'ok'}
            if isinstance(result, int): status = result; response = {}
            else: response = {'data': {} if result is None else {ticket: result}}
        raw = json.dumps(response).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)

class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        args = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with self.server.lock:
            self.server.client.clear_auth()
            response = self.server.client.post(self.path, json=args)
            value = response.data
        raw = json.dumps({'data': value}).encode()
        self.send_response(response.status_code); self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)

@contextmanager
def serve(handler, **fields):
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    for key, value in fields.items(): setattr(server, key, value)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try: yield server, 'http://127.0.0.1:' + str(server.server_port) + '/'
    finally: server.shutdown(); server.server_close(); thread.join(2)

class PushNotifications(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='stack-push-')
        self.addCleanup(self.directory.cleanup)
        config = Path(self.directory.name) / 'agents.json'
        config.write_text(json.dumps({'provider': 'ollama', 'model': 'synthetic'}))
        from cryptography.fernet import Fernet
        env = patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(config), 'STACK_AGENT_WORKER_TOKEN': WORKER,
            'STACK_CONNECTION_KEY': Fernet.generate_key().decode(), 'EXPO_ACCESS_TOKEN': 'synthetic-expo-secret'})
        env.start(); self.addCleanup(env.stop)
        self.client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=self.directory.name)
        self.addCleanup(self.client.close)
        self.auth = self.client.register_user('push-owner', 'Synthetic-password-123').data['token']
        self.other = self.client.register_user('push-other', 'Synthetic-password-123').data['token']
        self.client.set_auth_token(self.other); self.other_owner = self.rpc('bootstrap')['user_id']
        self.client.set_auth_token(self.auth); self.owner = self.rpc('bootstrap')['user_id']
        self.rpc('agent_save_policy', {'policy': {'enabled': True, 'expires_at': time.time()+3600, 'actions': ['model']}})
        self.fixture_context = serve(Fixture, requests=[], sent=[], replies={}, receipts={}, tickets={})
        self.provider, self.origin = self.fixture_context.__enter__(); self.addCleanup(self.fixture_context.__exit__, None, None, None)
        self.api_context = serve(Bridge, client=self.client, lock=threading.RLock())
        self.api, api_url = self.api_context.__enter__(); self.addCleanup(self.api_context.__exit__, None, None, None)
        env_api = patch.dict(os.environ, {'STACK_WORKER_API': api_url.rstrip('/')})
        env_api.start(); self.addCleanup(env_api.stop)
        self.now = time.time()

    def rpc(self, name, args=None):
        response = self.client.post('/function/'+name, json=args or {})
        self.assertTrue(response.ok, response.text)
        return response.data['result']

    def device(self, label):
        token = DEVICE + label + ']'
        self.client.set_auth_token(self.auth)
        self.assertEqual(self.rpc('agent_register_push', {'device_token': token}), {'registered': True})
        return token

    def queue(self):
        self.client.set_auth_token(self.auth)
        session = self.rpc('prep_create', {'problem_id': 'project'})
        run = self.rpc('agent_start', {'kind': 'prep', 'target_id': session['id']})
        self.assertNotIn('error', run)
        self.client.clear_auth(); claim = self.rpc('agent_claim', {'token': WORKER})
        self.assertEqual(claim['id'], run['id'])
        self.rpc('agent_finish', {'token': WORKER, **{k: claim[k] for k in ('id', 'owner', 'lease')},
            'result': {'needs_input': True, 'message': 'Controlled attention', 'requests': []}})
        self.client.set_auth_token(self.auth)
        values = self.rpc('agent_notification_status')['notifications']
        return next(n['id'] for n in values if n['run_id'] == run['id'])

    def view(self, nid):
        self.client.set_auth_token(self.auth)
        return self.rpc('agent_notification_status', {'id': nid})

    def step(self, advance=0):
        self.now += advance
        with patch.object(time, 'time', return_value=self.now), controlled_transport(self.origin):
            return worker.notification_once(WORKER)

    def claim(self, advance=0):
        self.now += advance
        with patch.object(time, 'time', return_value=self.now):
            return worker.call('agent_notification_claim', {'token': WORKER})

    def finish(self, claim, result):
        with patch.object(time, 'time', return_value=self.now):
            return worker.call('agent_notification_finish', {'token': WORKER,
                **{k: claim[k] for k in ('owner', 'id', 'key', 'lease')}, 'result': result})

    def test_real_worker_acceptance_receipt_mixed_devices_and_retirement(self):
        good = self.device('good'); invalid = self.device('invalid'); late = self.device('late-invalid')
        self.provider.replies[invalid] = [{'status': 'error', 'details': {'error': 'DeviceNotRegistered'}}]
        nid = self.queue()
        for _ in range(3): self.assertEqual(self.step(), {'saved': True})
        accepted = self.view(nid)
        self.assertEqual(accepted['state'], 'accepted')
        self.assertEqual(sorted(d['state'] for d in accepted['devices']), ['accepted', 'accepted', 'failed'])
        late_ticket = next(t for t, device in self.provider.tickets.items() if device == late)
        self.provider.receipts[late_ticket] = {'status': 'error', 'details': {'error': 'DeviceNotRegistered'}}
        self.step(901); self.step()
        self.assertEqual(self.view(nid)['state'], 'partial')
        self.client.reload(); self.assertEqual(self.view(nid)['state'], 'partial')
        nid2 = self.queue(); self.step()
        self.assertEqual(len(self.view(nid2)['devices']), 1)
        self.assertEqual(self.provider.sent[-1], good)
        for path, body, headers in self.provider.requests:
            self.assertEqual(headers['Authorization'], 'Bearer synthetic-expo-secret')
            if path == '/send':
                self.assertEqual(body['body'], 'An agent task needs your attention.')
                self.assertEqual(set(body['data']), {'user_id', 'target_type', 'target_id'})
                self.assertEqual(body['data']['user_id'], self.owner)

    def test_transient_send_retries_are_bounded_and_do_not_resend_accepted_devices(self):
        flaky = self.device('flaky'); good = self.device('good')
        self.provider.replies[flaky] = [429, 503, {'status': 'error', 'details': {'error': 'MessageRateExceeded'}}]
        nid = self.queue(); self.step(); self.step()
        self.assertEqual(self.step(), {'idle': True})
        self.step(31); self.step(61)
        values = self.view(nid)['devices']
        self.assertEqual(values[0]['attempts'], 3); self.assertEqual(values[0]['error'], 'SendAttemptsExhausted')
        self.assertEqual(self.provider.sent.count(good), 1)
        self.step(901); self.assertEqual(self.view(nid)['state'], 'partial')

    def test_missing_receipts_and_receipt_transport_failures_are_bounded(self):
        self.device('missing'); nid = self.queue(); self.step()
        ticket = self.view(nid)['devices'][0]['ticket']; self.provider.receipts[ticket] = [503, None] + [None]*12
        for _ in range(12): self.step(901)
        d = self.view(nid)['devices'][0]
        self.assertEqual(d['state'], 'uncertain'); self.assertEqual(d['receipt_attempts'], 12)
        self.assertEqual(d['error'], 'ReceiptAttemptsExhausted'); self.assertEqual(len(self.provider.sent), 1)
        self.assertEqual(self.step(), {'idle': True})

    def test_rate_exceeded_receipt_requeues_only_the_rejected_device(self):
        device = self.device('receipt-rate'); nid = self.queue(); self.step()
        ticket = self.view(nid)['devices'][0]['ticket']
        self.provider.receipts[ticket] = {'status': 'error', 'details': {'error': 'MessageRateExceeded'}}
        self.step(901)
        self.assertEqual(self.view(nid)['devices'][0]['state'], 'queued')
        self.assertEqual(self.step(), {'idle': True})
        self.step(31); self.step(901)
        self.assertEqual(self.provider.sent.count(device), 2)
        self.assertEqual(self.view(nid)['state'], 'delivered')

    def test_missing_credential_stops_without_provider_io(self):
        self.device('no-credential'); nid = self.queue()
        with patch.dict(os.environ, {'EXPO_ACCESS_TOKEN': ''}): self.step()
        self.assertEqual(self.provider.sent, [])
        self.assertEqual(self.view(nid)['devices'][0]['error'], 'MissingCredential')

    def test_empty_accounts_removed_devices_and_owner_isolation(self):
        nid = self.queue(); self.assertEqual(self.step(), {'idle': True})
        self.assertEqual(self.view(nid)['state'], 'no_devices')
        self.client.set_auth_token(self.other)
        self.assertIn('error', self.rpc('agent_notification_status', {'id': nid}))
        self.assertIn('error', self.rpc('agent_notification_claim', {'token': WORKER}))
        self.assertEqual(self.rpc('agent_notification_status')['notifications'], [])
        self.device('removed'); nid2 = self.queue(); claim = self.claim()
        self.client.set_auth_token(self.auth)
        self.rpc('agent_remove_push', {'device_token': DEVICE+'removed]'})
        # A claimed device is rechecked when reclaiming after a pre-send crash.
        self.assertEqual(self.claim(121), {'idle': True})
        self.assertEqual(self.view(nid2)['state'], 'failed')
        self.assertIn('error', self.rpc('agent_notification_begin', {'token': WORKER,
            **{k: claim[k] for k in ('id', 'key', 'lease')}, 'owner': self.other_owner}))

    def test_finish_is_idempotent_and_rejects_stale_or_wrong_owner_callbacks(self):
        self.device('one'); nid = self.queue(); claim = self.claim()
        auth = {'token': WORKER, **{k: claim[k] for k in ('id', 'owner', 'key', 'lease')}}
        worker.call('agent_notification_begin', auth)
        result = {'state': 'accepted', 'ticket': 'synthetic-ticket'}
        self.assertEqual(self.finish(claim, result), {'saved': True})
        self.assertEqual(self.finish(claim, result), {'saved': True})
        with self.assertRaises(ValueError): self.finish(claim, {'state': 'delivered'})
        with self.assertRaises(ValueError): self.finish({**claim, 'owner': self.other_owner}, result)
        self.assertEqual(self.view(nid)['devices'][0]['attempts'], 1)
        self.assertNotIn('lease', json.dumps(self.view(nid)))
        self.assertNotIn('synthetic-expo-secret', json.dumps(self.view(nid)))

    def test_removed_device_cannot_begin_and_expired_callbacks_cannot_finish(self):
        device = self.device('removed-after-claim'); nid = self.queue(); claim = self.claim()
        self.client.set_auth_token(self.auth); self.rpc('agent_remove_push', {'device_token': device})
        auth = {'token': WORKER, **{k: claim[k] for k in ('owner', 'id', 'key', 'lease')}}
        with self.assertRaises(ValueError): worker.call('agent_notification_begin', auth)
        self.assertEqual(self.view(nid)['devices'][0]['error'], 'DeviceRemoved')
        self.device('expired'); nid2 = self.queue(); old = self.claim(); fresh = self.claim(121)
        self.assertNotEqual(old['lease'], fresh['lease'])
        with self.assertRaises(ValueError): self.finish(old, {'state': 'accepted', 'ticket': 'old'})
        self.assertEqual(self.view(nid2)['devices'][0]['state'], 'claimed')

    def test_ambiguous_send_and_invalid_provider_response_never_claim_delivery(self):
        for reply in ({'status': 'ok'}, {'status': 'strange'}):
            device = self.device('ambiguous'+str(len(self.provider.sent)))
            self.provider.replies[device] = [reply]
            nid = self.queue()
            # Older devices may participate in each new notification.
            for _ in range(len(self.view(nid)['devices']) or len(self.provider.sent)+1): self.step()
            states = [d['state'] for d in self.view(nid)['devices']]
            self.assertIn('uncertain', states)
        with patch.object(notifications, 'http', side_effect=TimeoutError('private-token-do-not-log')):
            result = notifications.deliver(DEVICE+'timeout]', {'owner': self.owner, 'run_id': 'run'})
        self.assertEqual(result, {'state': 'uncertain', 'error': 'TransportUncertain'})

    def kill_at(self, stage):
        marker = Path(self.directory.name) / (stage+'.marker')
        env = {**os.environ, 'STACK_TEST_PUSH_ORIGIN': self.origin, 'STACK_TEST_PUSH_PAUSE': stage,
            'STACK_TEST_PUSH_MARKER': str(marker)}
        executable = os.environ.get('STACK_TEST_JAC_BIN', 'jac')
        proc = subprocess.Popen([executable, 'run', '--no-serve', str(Path(__file__).resolve()), '--worker-child'],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic()+120
        try:
            while not marker.exists() and proc.poll() is None and time.monotonic()<deadline: time.sleep(.05)
            if not marker.exists():
                proc.kill(); output = proc.communicate(timeout=10)[0]
                self.fail('Worker failed to reach '+stage+': '+output[-3000:])
            proc.kill(); output = proc.communicate(timeout=10)[0]
            self.assertNotEqual(proc.returncode, 0, output)
        finally:
            if proc.poll() is None: proc.kill(); proc.wait(timeout=10)

    def test_killed_worker_before_send_reclaims_and_sends_once(self):
        self.device('kill-before'); nid = self.queue(); self.kill_at('before_send')
        self.assertEqual(len(self.provider.sent), 0)
        self.now = time.time()
        self.client.reload(); self.step(121)
        self.assertEqual(len(self.provider.sent), 1); self.assertEqual(self.view(nid)['state'], 'accepted')
        self.step(901); self.assertEqual(self.view(nid)['state'], 'delivered')

    def test_killed_worker_after_acceptance_without_saved_ticket_becomes_uncertain(self):
        self.device('kill-after'); nid = self.queue(); self.kill_at('after_acceptance')
        self.assertEqual(len(self.provider.sent), 1)
        self.now = time.time()
        self.client.reload(); self.assertEqual(self.step(121), {'idle': True})
        self.assertEqual(self.view(nid)['state'], 'uncertain')
        self.assertEqual(self.view(nid)['devices'][0]['ticket'], '')
        self.assertEqual(len(self.provider.sent), 1)

    def test_killed_worker_before_receipt_finish_repolls_without_resending(self):
        self.device('kill-finish'); nid = self.queue(); self.step()
        # Make receipt due without modifying stored graph records.
        self.now += 901
        with patch.object(time, 'time', return_value=self.now): self.kill_at('before_finish')
        self.client.reload(); self.step(121)
        self.assertEqual(self.view(nid)['state'], 'delivered'); self.assertEqual(len(self.provider.sent), 1)


def child():
    stage = os.environ['STACK_TEST_PUSH_PAUSE']; original = worker.call
    def call(name, args):
        if ((stage == 'after_acceptance' and name == 'agent_notification_finish' and args['result']['state'] == 'accepted')
            or (stage == 'before_finish' and name == 'agent_notification_finish' and args['result']['state'] == 'delivered')):
            Path(os.environ['STACK_TEST_PUSH_MARKER']).write_text(stage)
            threading.Event().wait(120)
        value = original(name, args)
        if stage == 'before_send' and name == 'agent_notification_claim' and not value.get('idle'):
            Path(os.environ['STACK_TEST_PUSH_MARKER']).write_text(stage)
            threading.Event().wait(120)
        return value
    with patch.object(worker, 'call', side_effect=call), controlled_transport(os.environ['STACK_TEST_PUSH_ORIGIN']):
        worker.notification_once(WORKER)

if __name__ == '__main__':
    if '--worker-child' in sys.argv: child()
    else: unittest.main(verbosity=2)
