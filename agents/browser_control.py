"""Thread-safe control authority. No browser, credentials, or persisted login state."""
import secrets
import threading
import time

# A small public vocabulary, never exception text, URLs, selectors or inputs.
BROWSER_ERROR_MESSAGE = 'Browser operation failed. Review the session or resume the task.'
BROWSER_OPERATIONS = frozenset({'linkedin_scan'})
BROWSER_STAGES = frozenset({
    'operation', 'control_check', 'expire_session', 'validate_profile',
    'validate_session', 'create_session', 'configure_session', 'open_login',
    'check_login', 'check_profile_url', 'navigate_profile', 'verify_profile_page',
    'prepare_capture', 'capture_frame', 'wait_profile_header', 'expand_profile',
    'read_sections', 'scroll_profile', 'wait_section', 'build_capture', 'close_session',
    'rpc_transport', 'rpc_result',
})
BROWSER_ERROR_TYPES = frozenset({
    'Exception', 'Error', 'TimeoutError', 'TargetClosedError', 'ValueError',
    'TypeError', 'RuntimeError', 'OSError', 'PermissionError', 'ConnectionError',
    'BrokenPipeError', 'JSONDecodeError', 'AttributeError', 'KeyError',
})


def sanitize_browser_diagnostic(value):
    if not isinstance(value, dict) or value.get('version') != 1:
        return {}
    operation = value.get('operation')
    if not isinstance(operation, str) or operation not in BROWSER_OPERATIONS:
        return {}
    error_type = value.get('error_type')
    if not isinstance(error_type, str) or error_type not in BROWSER_ERROR_TYPES:
        error_type = 'Exception'
    stage = value.get('stage')
    if not isinstance(stage, str) or stage not in BROWSER_STAGES:
        stage = 'operation'
    duration = value.get('duration_ms')
    duration = max(0, min(duration, 3_600_000)) if type(duration) is int else 0
    return dict(version=1, operation=value['operation'], stage=stage, error_type=error_type,
                code='browser_timeout' if error_type == 'TimeoutError' else 'browser_operation_failed',
                duration_ms=duration)


def browser_diagnostic(operation, stage, exception, duration_ms):
    return sanitize_browser_diagnostic(dict(version=1, operation=operation, stage=stage,
        error_type=type(exception).__name__, duration_ms=duration_ms))


class BrowserInterrupted(ValueError):
    def __init__(self, state):
        super().__init__('Browser control changed.')
        self.state = state


class BrowserControl:
    def __init__(self):
        self.condition = threading.Condition(threading.RLock())
        self.instance = secrets.token_hex(16)
        self.records = {}
        self.revoked_owners = set()
        self.tickets = {}
        self.viewers = {}

    def _record(self, key):
        if key not in self.records:
            self.records[key] = dict(mode='agent', generation=0, controller='',
                                     sequence=0, active=False, changed=False)
            if key[0] in self.revoked_owners:
                self.records[key].update(mode='stopped', generation=1, revoked=True)
        return self.records[key]

    def state(self, key):
        with self.condition:
            return {**{k: v for k, v in self._record(key).items() if k != 'active'}, 'instance': self.instance}

    def transition(self, key, action, generation, controller='', instance=None):
        with self.condition:
            value = self._record(key)
            if action == 'status':
                return self.state(key)
            if action == 'stop':
                if value['mode'] not in ('stopping', 'stopped'):
                    value['generation'] += 1
                    value['mode'] = 'stopping'
                self.condition.notify_all()
                return self.state(key)
            if instance is not None and instance != self.instance:
                raise ValueError('The browser restarted. Reconnect before taking control.')
            if generation != value['generation']:
                raise ValueError('Browser control changed. Reconnect before continuing.')
            if not isinstance(controller, str) or not 16 <= len(controller) <= 128:
                raise ValueError('A viewer controller is required.')
            if action == 'take':
                if value['mode'] not in ('agent', 'user'):
                    raise ValueError('Wait for browser activity to pause.')
                value.update(generation=value['generation'] + 1, controller=controller,
                    sequence=0, changed=False, mode='pausing' if value['active'] else 'user')
            elif action == 'resume':
                if value['mode'] != 'user' or controller != value['controller'] or value['active']:
                    raise ValueError('Wait for your browser input to finish before resuming.')
                value.update(generation=value['generation'] + 1, mode='agent', controller='')
            else:
                raise ValueError('Unknown browser control.')
            self.condition.notify_all()
            return self.state(key)

    def begin(self, key, event=None, agent_generation=None, agent_instance=None) -> tuple[int, str]:
        with self.condition:
            value = self._record(key)
            if value['active']:
                raise ValueError('Browser operation is still finishing.')
            expected = 'user' if event is not None else 'agent'
            if value['mode'] != expected:
                raise BrowserInterrupted(self.state(key))
            if event is None and agent_generation is not None:
                if agent_generation != value['generation'] or (agent_instance and agent_instance != self.instance):
                    raise BrowserInterrupted(self.state(key))
            if event is not None:
                if event.get('instance') != self.instance or event.get('generation') != value['generation'] or event.get('controller') != value['controller']:
                    raise ValueError('This browser input belongs to an old control session.')
                sequence = event.get('sequence')
                if type(sequence) is not int or sequence != value['sequence'] + 1:
                    raise ValueError('Browser input is out of order. Reconnect before continuing.')
                value['sequence'] = sequence
                value['changed'] = True
            value['active'] = True
            return value['generation'], expected

    def check(self, key, generation, mode):
        with self.condition:
            value = self._record(key)
            if value['generation'] != generation or value['mode'] != mode:
                raise BrowserInterrupted(self.state(key))

    def end(self, key):
        with self.condition:
            value = self._record(key)
            value['active'] = False
            if value['mode'] == 'pausing':
                value['mode'] = 'user'
            elif value['mode'] == 'stopping':
                value['mode'] = 'stopped'
            self.condition.notify_all()
            return self.state(key)

    def grant(self, key):
        with self.condition:
            if self._record(key).get('revoked') or self._record(key)['mode'] in ('stopping', 'stopped'):
                raise ValueError('This browser viewer is unavailable.')
            now = time.monotonic()
            self.tickets = {t: v for t, v in self.tickets.items() if v[1] > now}
            # A grant is single-use, short-lived, and only created after API ownership checks.
            ticket = secrets.token_urlsafe(32)
            self.tickets[ticket] = key, now + 10
            return ticket

    def consume(self, ticket):
        with self.condition:
            entry = self.tickets.pop(ticket, None)
            if not entry or entry[1] < time.monotonic():
                raise ValueError('Browser viewer authorization expired.')
            if self._record(entry[0]).get('revoked') or self._record(entry[0])['mode'] in ('stopping', 'stopped'):
                raise ValueError('This browser viewer is unavailable.')
            return entry[0]

    def revoke_owner(self, owner):
        # Runs outside the browser-operation lock, including during a long navigation.
        with self.condition:
            self.revoked_owners.add(owner)
            for key, value in self.records.items():
                if key[0] == owner:
                    value.update(mode='stopping', generation=value['generation'] + 1, revoked=True)
            self.tickets = {t: v for t, v in self.tickets.items() if v[0][0] != owner}
            self.condition.notify_all()

    def pending_stops(self):
        with self.condition:
            return [key for key, value in self.records.items() if value['mode'] == 'stopping' and not value['active']]

    def watching(self, key):
        with self.condition:
            return self.viewers.get(key, 0) > 0

    def watch(self, key, delta):
        with self.condition:
            count = self.viewers.get(key, 0) + delta
            if count > 2:
                raise ValueError('Close another browser viewer before opening this one.')
            if count > 0:
                self.viewers[key] = count
            else:
                self.viewers.pop(key, None)
