"""Candidate-facing ATS forms. Browser state is isolated by account and run."""
import base64
import hashlib
import json
import os
import time
import threading
from pathlib import Path
from urllib.parse import urlsplit
from agents.contracts import adapter_for, answers, digest
from discovery.transport import public_url

HOSTS = {
    'greenhouse': {'boards.greenhouse.io', 'job-boards.greenhouse.io', 'boards.eu.greenhouse.io', 'job-boards.eu.greenhouse.io', 'boards-api.greenhouse.io', 'boards-api.eu.greenhouse.io'},
    'lever': {'jobs.lever.co', 'jobs.eu.lever.co'},
    'ashby': {'jobs.ashbyhq.com'},
}
FIELDS_JS = '''() => Array.from(document.querySelectorAll('input,textarea,select')).filter(e => {
 const r=e.getBoundingClientRect();return r.width&&r.height&&!e.disabled&&!['submit','button','hidden'].includes(e.type);
}).map((e,i)=>({index:i,tag:e.tagName.toLowerCase(),type:e.type||'text',name:e.name||'',id:e.id||'',
 label:(e.labels?.[0]?.innerText||e.getAttribute('aria-label')||e.placeholder||e.name||'').trim(),
 required:e.required||e.getAttribute('aria-required')==='true',valid:e.checkValidity(),checked:!!e.checked,value:e.type==='file'?'':e.value,
 options:e.tagName==='SELECT'?Array.from(e.options).map(o=>({value:o.value,label:o.text})):[]}))'''


def field_key(field):
    label = field['label'].lower().strip().rstrip('*').strip()
    common = {'first name': 'first_name', 'last name': 'last_name', 'full name': 'name', 'name': 'name',
              'email': 'email', 'email address': 'email', 'phone': 'phone', 'phone number': 'phone',
              'location': 'location', 'linkedin profile': 'linkedin', 'website': 'website'}
    return common.get(label, 'answer:' + hashlib.sha256(label.encode()).hexdigest()[:24])


class BrowserFrames:
    """Latest live frame only, in memory, scoped to the account and task."""
    def __init__(self):
        self.lock = threading.Lock()
        self.values = {}

    def put(self, key, frame):
        with self.lock:
            self.values[key] = frame

    def get(self, key):
        with self.lock:
            return self.values.get(key, {'pending': True})

    def remove(self, key):
        with self.lock:
            self.values.pop(key, None)


class BrowserPool:
    def __init__(self):
        from playwright.sync_api import sync_playwright
        self.driver = sync_playwright().start()
        # Browser host is a dedicated container with no API/database/model credentials.
        self.browser = self.driver.chromium.launch(headless=True, chromium_sandbox=True)
        self.sessions = {}
        self.frames = BrowserFrames()

    def publish(self, owner, run):
        value = self.sessions[(owner, run)]
        page = value['page']
        viewport = page.viewport_size or {'width': 1100, 'height': 800}
        # URL query parameters and fragments can contain sign-in state.
        url = urlsplit(page.url)
        frame = {'image': base64.b64encode(page.screenshot(type='jpeg', quality=65)).decode(),
                 **viewport, 'url': url._replace(query='', fragment='').geturl(),
                 'private_login': value.get('adapter') == 'linkedin', 'captured_at': time.time(),
                 'progress': value.get('progress', '')}
        self.frames.put((owner, run), frame)
        return frame

    def session(self, owner, run, url, create=True):
        key = (owner, run)
        if key in self.sessions:
            value = self.sessions[key]
            value['touched'] = time.time()
            return value
        if not create:
            raise ValueError('The browser session expired. Resume the run to restore its form.')
        public_url(url)
        adapter = adapter_for(url)
        if not adapter:
            raise ValueError('This site needs manual application. Your documents remain available.')
        allowed = HOSTS[adapter] | set(filter(None, os.environ.get('STACK_BROWSER_RESOURCE_HOSTS', '').split(',')))
        saved = self.load(owner, run)
        context = self.browser.new_context(accept_downloads=False, service_workers='block', viewport={'width': 1100, 'height': 800}, **({'storage_state': saved['storage']} if saved else {}))
        def route(r):
            request = r.request
            try:
                public_url(request.url)
                host = urlsplit(request.url).hostname
                if host not in allowed or (request.method not in ('GET', 'HEAD') and host not in HOSTS[adapter]):
                    r.abort(); return
                r.continue_()
            except Exception:
                r.abort()
        context.route('**/*', route)
        if hasattr(context, 'route_web_socket'):
            context.route_web_socket('**/*', lambda ws: ws.close())
        page = context.new_page()
        page.on('filechooser', lambda chooser: self.sessions.get(key, {}).update({'chooser': chooser}))
        page.goto(url, wait_until='domcontentloaded', timeout=30000)
        if saved:
            for field in saved.get('fields', []):
                if field['type'] in ('file', 'password', 'checkbox', 'radio') or not field['value']:
                    continue
                selector = '[id=' + json.dumps(field['id']) + ']' if field['id'] else '[name=' + json.dumps(field['name']) + ']'
                element = page.locator(selector)
                if element.count() == 1 and element.is_visible():
                    try:
                        if field['tag'] == 'select': element.select_option(field['value'])
                        else: element.fill(field['value'])
                    except Exception:
                        pass  # The next inspection validates the current form again.
        value = {'page': page, 'context': context, 'adapter': adapter, 'touched': time.time(), 'filled_hash': '', 'submitted': False}
        self.sessions[key] = value
        return value

    def path(self, owner, run):
        return Path(os.environ.get('STACK_BROWSER_STORAGE', '/tmp/stack-browser-sessions')) / digest(owner) / (digest(run) + '.enc')

    def load(self, owner, run):
        from cryptography.fernet import Fernet
        key = os.environ.get('STACK_BROWSER_SESSION_KEY', '')
        if not key:
            raise ValueError('Browser session encryption must be configured.')
        path = self.path(owner, run)
        if not path.exists(): return {}
        try:
            return json.loads(Fernet(key.encode()).decrypt(path.read_bytes(), ttl=86400))
        except Exception:
            path.unlink(missing_ok=True);return {}

    def checkpoint(self, owner, run):
        value = self.sessions[(owner, run)]
        if value.get('adapter') == 'linkedin':
            return  # LinkedIn credentials and page input values are never checkpointed.
        from cryptography.fernet import Fernet
        fields = [f for f in value['page'].evaluate(FIELDS_JS) if f['type'] != 'password']
        payload = {'storage': value['context'].storage_state(), 'fields': fields}
        path = self.path(owner, run);path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = path.with_suffix('.tmp')
        temporary.write_bytes(Fernet(os.environ['STACK_BROWSER_SESSION_KEY'].encode()).encrypt(json.dumps(payload).encode()))
        temporary.chmod(0o600);temporary.replace(path)

    def close(self, owner, run):
        self.frames.remove((owner, run))
        value = self.sessions.pop((owner, run), None)
        if value:
            value['context'].close()
        return {'closed': True}

    def linkedin_scan(self, owner, run, context):
        from agents.linkedin import scan
        return scan(self, owner, run, context)

    def purge(self, owner):
        for key in list(self.sessions):
            if key[0] == owner:
                self.close(*key)
        directory = self.path(owner, '').parent
        if directory.exists():
            for path in directory.glob('*.enc'): path.unlink()
        return {'purged': True}

    def blocked(self, page):
        text = page.locator('body').inner_text(timeout=5000).lower()
        for term in ('verify you are human', 'complete the captcha', 'sign in to apply', 'sign your application', 'assessment required'):
            if term in text:
                return term
        if page.locator('iframe[src*="captcha"], input[type="password"]').count():
            return 'Login or challenge requires your input'
        return ''

    def inspect(self, owner, run, context):
        value = self.session(owner, run, context['job']['url'])
        page = value['page']
        reason = self.blocked(page)
        if reason:
            return {'needs_input': True, 'message': reason, 'requests': [{'key': 'browser', 'label': 'Open the browser handoff, then resume.'}]}
        fields = page.evaluate(FIELDS_JS)
        if not fields:
            # A known application link, never an arbitrary model-selected destination.
            link = page.get_by_role('link', name='Apply for this job', exact=True)
            if link.count() == 1:
                link.click(); fields = page.evaluate(FIELDS_JS)
        if not fields:
            return {'needs_input': True, 'message': 'Open the application form in the browser handoff.', 'requests': []}
        verified = answers(context.get('facts', []))
        requests = []
        for field in fields:
            field['key'] = field_key(field)
            if field['required'] and field['type'] not in ('file', 'checkbox', 'radio') and field['key'] not in verified and not field['value']:
                requests.append({'key': field['key'], 'label': field['label'], 'options': field['options']})
            if field['type'] in ('checkbox', 'radio') or field['tag'] not in ('input', 'textarea', 'select'):
                # These require control-specific semantics; do not guess consents or group answers.
                if field['required'] and not field['valid']:
                    requests.append({'key': 'browser', 'label': 'Complete this choice in the browser: ' + field['label']})
        artifact = {'adapter': value['adapter'], 'fields': fields, 'schema_hash': digest([{k: f[k] for k in ('tag', 'type', 'name', 'id', 'label', 'required', 'options')} for f in fields])}
        self.checkpoint(owner, run)
        requests = list({r['key']: r for r in requests}.values())
        if requests:
            return {'needs_input': True, 'message': 'Complete these missing application answers.', 'requests': requests, 'artifact': artifact}
        return {'artifact': artifact}

    def fill(self, owner, run, context, artifacts):
        value = self.session(owner, run, context['job']['url'])
        page = value['page']
        reason = self.blocked(page)
        if reason:
            return {'needs_input': True, 'message': reason, 'requests': []}
        fields = page.evaluate(FIELDS_JS)
        schema_hash = digest([{k: f[k] for k in ('tag', 'type', 'name', 'id', 'label', 'required', 'options')} for f in fields])
        if schema_hash != artifacts['inspect']['schema_hash']:
            return {'needs_input': True, 'message': 'The form changed. Review it in the browser before continuing.', 'requests': []}
        verified = answers(context.get('facts', []))
        for f in fields:
            selector = '[id=' + json.dumps(f['id']) + ']' if f['id'] else '[name=' + json.dumps(f['name']) + ']'
            element = page.locator(selector)
            if element.count() != 1:
                continue
            if f['type'] == 'file' and any(x in f['label'].lower() for x in ('resume', 'cover letter', 'cv')):
                pdf = artifacts.get('tailor', {}).get('cover_letter' if 'cover' in f['label'].lower() else 'pdf', {})
                if pdf:
                    element.set_input_files({'name': pdf['name'], 'mimeType': 'application/pdf', 'buffer': base64.b64decode(pdf['content'])})
            elif f['type'] not in ('checkbox', 'radio', 'file') and field_key(f) in verified:
                answer = verified[field_key(f)]
                if f['tag'] == 'select':
                    options = [o for o in f['options'] if answer in (o['label'], o['value'])]
                    if len(options) != 1:
                        raise ValueError('A saved answer does not match the form choices.')
                    element.select_option(options[0]['value'])
                else:
                    element.fill(answer)
                    if element.input_value() != answer:
                        raise ValueError('A field did not retain the saved answer.')
        valid = page.evaluate('() => Array.from(document.forms).every(f=>f.checkValidity())')
        if not valid:
            raise ValueError('The completed form still has invalid or missing fields. Review it in the browser.')
        value['filled_hash'] = digest(page.evaluate(FIELDS_JS))
        self.checkpoint(owner, run)
        return {'artifact': {'verified': True, 'form_hash': value['filled_hash']}}

    def submit(self, owner, run, context, artifacts):
        value = self.session(owner, run, context['job']['url'], create=False)
        page = value['page']
        if value['submitted']:
            raise ValueError('Submission was already attempted. Reconcile the receipt.')
        if not value['filled_hash'] or digest(page.evaluate(FIELDS_JS)) != value['filled_hash'] or self.blocked(page):
            raise ValueError('The form changed or a challenge appeared. Reconcile before submitting.')
        button = page.get_by_role('button', name='Submit application', exact=True)
        if button.count() != 1:
            raise ValueError('The tested submit control was not found.')
        value['submitted'] = True
        button.click(timeout=15000)
        page.wait_for_timeout(1500)
        text = page.locator('body').inner_text(timeout=10000)
        markers = ('application has been submitted', 'application was submitted', 'thank you for applying', 'application received')
        if not any(m in text.lower() for m in markers):
            raise ValueError('Submission confirmation could not be verified.')
        return {'artifact': {'receipt': text[:3000], 'url': page.url, 'at': time.time(), 'adapter': value['adapter']}}

    def handoff(self, owner, run, event):
        value = self.sessions.get((owner, run))
        if not value:
            raise ValueError('Browser session unavailable. Resume the run to open it.')
        page = value['page']
        kind = event.get('type', 'snapshot')
        if kind == 'click':
            x, y = event.get('x', -1), event.get('y', -1)
            viewport = page.viewport_size or {'width': 1100, 'height': 800}
            if not 0 <= x < viewport['width'] or not 0 <= y < viewport['height']:
                raise ValueError('Click is outside the browser viewport.')
            page.mouse.click(x, y)
        elif kind == 'reload' and value.get('adapter') == 'linkedin':
            page.goto(value['url'], wait_until='domcontentloaded', timeout=30000)
        elif kind == 'login' and value.get('adapter') == 'linkedin':
            page.goto('https://www.linkedin.com/login', wait_until='domcontentloaded', timeout=30000)
        elif kind == 'text':
            page.keyboard.insert_text(str(event.get('text', ''))[:8000])
        elif kind == 'file':
            if value.get('adapter') == 'linkedin':
                raise ValueError('Profile review does not upload files.')
            chooser = value.pop('chooser', None)
            if not chooser:
                raise ValueError('Select the upload control in your browser first.')
            content = base64.b64decode(event.get('content', ''), validate=True)
            if len(content) > 10000000 or not content.startswith(b'%PDF-'):
                raise ValueError('Upload a PDF smaller than 10 MB.')
            chooser.set_files({'name': Path(event.get('name', 'Document.pdf')).name, 'mimeType': 'application/pdf', 'buffer': content})
        elif kind == 'key' and event.get('key') in ('Tab', 'Enter', 'Backspace', 'Escape', 'ArrowDown', 'ArrowUp'):
            page.keyboard.press(event['key'])
        elif kind == 'scroll':
            page.mouse.wheel(0, max(-700, min(700, int(event.get('dy', 0)))))
        elif kind != 'snapshot':
            raise ValueError('Unknown browser input.')
        value['touched'] = time.time()
        self.checkpoint(owner, run)
        return self.publish(owner, run)

    def expire(self):
        for key, value in list(self.sessions.items()):
            if value['touched'] < time.time() - 3600:
                value['context'].close(); del self.sessions[key]
                self.frames.remove(key)
