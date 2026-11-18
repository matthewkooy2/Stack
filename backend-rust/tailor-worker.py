"""Persistent records-based resume worker for the Rust task API."""

import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

RELEASE = Path('/opt/stack-rust/current').resolve()
sys.path[:0] = [str(RELEASE), str(RELEASE / 'score-docs')]
from agents import contracts, local_model, memory_access, memory_tailoring, record_resume, scoring

MODEL = 'gpt-6.2-sol'
SLOTS = 32
LIMIT = 110_000_000_000  # Nanodollars, including the prior staging model QA.
# Historical QA outside the ledger and margin for earlier cache-write pricing.
PRIOR = 781_632_207
SOL_CONTEXT = 65_536
LOCAL = threading.Semaphore(1)
RENDER = threading.Lock()


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def send(url, payload, token='', timeout=25):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = Request(url, data=json.dumps(payload, ensure_ascii=False).encode(), headers=headers)
    with build_opener(ProxyHandler({}), NoRedirect()).open(request, timeout=timeout) as response:
        return json.load(response), response.headers


class Budget:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS calls (id INTEGER PRIMARY KEY, reserved INTEGER NOT NULL, used INTEGER, http INTEGER)')
        self.lock = threading.Lock()

    def reserve(self, input_bound, output_tokens):
        # Ultrafast at 3x, reserving the most expensive supported cache-write rate.
        amount = input_bound * 15000 + output_tokens * 30000
        with self.lock, self.db:
            upper, = self.db.execute('SELECT COALESCE(SUM(COALESCE(used,reserved)),0) FROM calls').fetchone()
            if upper + PRIOR + amount > LIMIT:
                raise ValueError('The staging AI budget has been reached.')
            return self.db.execute('INSERT INTO calls(reserved) VALUES (?)', (amount,)).lastrowid

    def settle(self, ident, used, status):
        with self.lock, self.db:
            self.db.execute('UPDATE calls SET used=?,http=? WHERE id=?', (used, status, ident))


class Worker:
    def __init__(self):
        credential_dir = Path(os.environ['CREDENTIALS_DIRECTORY'])
        self.token = (credential_dir / 'worker-token').read_text().strip()
        self.key = (credential_dir / 'openai-key').read_text().strip()
        if len(self.key) < 30 or not self.key.startswith('sk-') or len(self.token) < 16:
            raise RuntimeError('Worker credentials are invalid')
        self.budget = Budget(Path(os.environ['STATE_DIRECTORY']) / 'budget.db')
        self.backoff = 0
        self.backoff_lock = threading.Lock()
        self.reported_limits = False

    def rpc(self, route, **args):
        for attempt in range(4):
            try:
                body, _ = send(f'http://127.0.0.1:8181/function/{route}', {'token': self.token, **args})
                break
            except HTTPError as error:
                if error.code != 503 or attempt == 3:
                    raise RuntimeError(f'Rust {route} returned HTTP {error.code}') from None
                print(f'worker_retry route={route} status=503 attempt={attempt+1}', flush=True)
                time.sleep(.25 * (attempt + 1))
        data = body.get('data', {})
        result = data.get('result', data)
        if not body.get('ok') or not isinstance(result, dict) or result.get('error'):
            raise RuntimeError(f'Rust rejected {route}')
        return result

    def sol(self, lease, step, system, prompt, schema, cap):
        payload = {
            'model': MODEL, 'store': False, 'max_output_tokens': cap,
            'reasoning': {'effort': 'low'}, 'service_tier': 'ultrafast',
            'instructions': system, 'input': prompt,
            'text': {'format': {'type': 'json_schema', 'name': 'stack_' + step,
                                'strict': True, 'schema': schema}},
        }
        input_bound = contracts.model_request_size(system, prompt, schema, 0)
        for attempt in range(5):
            with self.backoff_lock:
                delay = self.backoff - time.monotonic()
            if delay > 0:
                time.sleep(delay + secrets.randbelow(500) / 1000)
            if lease and not self.rpc('agent_lease_active', **lease).get('active'):
                raise ValueError('The request is no longer active.')
            ident = self.budget.reserve(input_bound, cap)
            try:
                body, headers = send('https://api.openai.com/v1/responses', payload, self.key, timeout=80)
            except HTTPError as error:
                code = ''
                try:
                    code = json.loads(error.read(128 * 1024)).get('error', {}).get('code')
                except (ValueError, AttributeError, OSError):
                    pass
                # A rate-limit rejection occurs before generation. Retain the full
                # reservation for an ambiguous server or transport failure.
                self.budget.settle(ident, 0 if 400 <= error.code < 500 else None, error.code)
                code = code if isinstance(code, str) and re.fullmatch(r'[a-z0-9_]+', code) else 'unknown'
                print(f'provider_http={error.code} code={code} step={step} attempt={attempt+1}', flush=True)
                if error.code != 429 or code in {'insufficient_quota', 'billing_hard_limit_reached'} or attempt == 4:
                    raise ValueError('OpenAI could not complete this request.') from None
                retry = error.headers.get('Retry-After', '')
                delay = min(60, max(2, float(retry))) if retry.replace('.', '', 1).isdigit() else min(30, 2 ** (attempt + 1))
                with self.backoff_lock:
                    self.backoff = max(self.backoff, time.monotonic() + delay)
                continue
            with self.backoff_lock:
                if not self.reported_limits:
                    rpm = headers.get('x-ratelimit-limit-requests', '')
                    tpm = headers.get('x-ratelimit-limit-tokens', '')
                    print(f'rate_limits rpm={rpm if rpm.isdigit() else "unknown"} tpm={tpm if tpm.isdigit() else "unknown"}', flush=True)
                    self.reported_limits = True
            usage = body.get('usage')
            if usage and isinstance(usage.get('input_tokens'), int) and isinstance(usage.get('output_tokens'), int):
                details = usage.get('input_tokens_details') or {}
                cached = details.get('cached_tokens', 0)
                writes = details.get('cache_write_tokens', 0)
                short = (details.get('cache_write_tokens_details') or {}).get('ttl_30m_tokens', 0)
                fresh = usage['input_tokens'] - cached - writes
                tier = body.get('service_tier')
                multiplier = {'default': 1, 'fast': 2, 'priority': 2}.get(tier, 3)
                actual = multiplier * (fresh * 2000 + cached * 100 + short * 2500
                                       + (writes - short) * 5000 + usage['output_tokens'] * 10000)
                self.budget.settle(ident, actual, 200)
                print(f'served_tier={tier} step={step}', flush=True)
            if body.get('status') != 'completed':
                raise ValueError('OpenAI returned an incomplete response.')
            return ''.join(part['text'] for item in body.get('output', [])
                           for part in item.get('content', []) if part.get('type') == 'output_text')
        raise ValueError('OpenAI is rate limiting requests.')

    def tailor(self, work):
        lease = {key: work[key] for key in ('id', 'owner', 'lease')}
        started = time.monotonic()
        phase = 'prepare'
        try:
            config = contracts.config(work['model_selection'])
            if contracts.digest(config) != work['provider_config_hash']:
                raise ValueError('The model configuration changed. Retry tailoring.')
            provider, model = config['provider'], config['model']
            if provider not in contracts.LOCAL_PROVIDERS and (provider != 'openai' or model != MODEL):
                raise ValueError('Choose the staging default model or Local model to tailor this resume.')
            source = self.rpc('agent_worker_resume_source', **lease)
            if source.get('format') != 'records':
                raise ValueError('Review and confirm the imported resume records before tailoring.')
            prepared = record_resume.prepare(source)
            memory = memory_access.validate(self.rpc('agent_worker_memory', **lease), work['owner'])
            job = work['context']['job']

            def generate(step, context, current):
                system, prompt, schema = memory_tailoring.request(step, context)
                cap = memory_tailoring.OUTPUT_TOKENS[step]
                attempt = {'attempt_id': secrets.token_hex(16), 'provider': provider, 'model': model}
                self.rpc('agent_model_log', **lease, record={**attempt, 'status': 'started'})
                try:
                    if provider == 'openai':
                        text = self.sol(lease, step, system, prompt, schema, cap)
                    else:
                        with LOCAL:
                            if not self.rpc('agent_lease_active', **lease).get('active'):
                                raise ValueError('The request is no longer active.')
                            text = local_model.complete(step, system, prompt, schema,
                                                        {**current, 'max_output_tokens': cap}, lambda *_: None)['text']
                    artifact = json.loads(text)
                    local_model.validate(artifact, schema)
                except (ValueError, OSError):
                    self.rpc('agent_model_log', **lease, record={**attempt, 'status': 'error',
                                                                 'error': 'Model request failed'})
                    raise
                self.rpc('agent_model_log', **lease, record={**attempt, 'status': 'accepted'})
                return {'artifact': artifact, 'cost_cents': 0}

            served = local_model.served_context(config) if provider in contracts.LOCAL_PROVIDERS else None
            phase = 'plan'
            proposal = memory_tailoring.run(prepared, memory, job, config, generate, served,
                                          work['context']['resume_id'],
                                          planner_limit=SOL_CONTEXT if provider == 'openai' else None)
            phase = 'render'
            # ReportLab shares font state and the document inspectors have bounded slots.
            # Keep validation intact and queue render work while model calls run concurrently.
            with RENDER:
                artifact = memory_tailoring.tailor(prepared, proposal)
            phase = 'score'
            if job:
                before = scoring.score(prepared['outline'], job, [],
                                       text='\n'.join(row['text'] for row in prepared['records']))
                after = scoring.score(record_resume.prepare({**prepared, 'records': artifact['records']})['outline'],
                                      job, [], pages=artifact['pdf']['pages'],
                                      text='\n'.join(row['text'] for row in artifact['records']))
                artifact['score'] = {'before': scoring.summary(before), 'after': scoring.summary(after)}
            phase = 'finish'
            self.rpc('agent_finish', **lease, result={'artifact': artifact, 'cost_cents': 0})
            print(f'tailor outcome=accepted provider={provider} seconds={time.monotonic()-started:.3f}', flush=True)
        except (ValueError, OSError, RuntimeError) as error:
            detail = str(error)
            render_error = ''
            if phase == 'render':
                if detail.startswith('Generated file text differs'):
                    render_error = ' document_error=text_mismatch'
                elif detail.startswith('LaTeX could not compile'):
                    render_error = ' document_error=compile'
                elif detail.startswith('The tailored resume exceeds'):
                    render_error = ' document_error=record_limit'
            print(f'tailor outcome=error phase={phase} type={type(error).__name__}{render_error} seconds={time.monotonic()-started:.3f}', flush=True)
            if self.rpc('agent_lease_active', **lease).get('active'):
                message = detail if detail.startswith(
                    ('The staging AI budget', 'The model configuration changed',
                     'Choose the staging default', 'Review and confirm',
                     'The model did not review every resume section and line.',
                     'Generated file text differs', 'The tailored resume exceeds')) else 'Tailoring could not finish. Retry this task.'
                self.rpc('agent_finish', **lease, result={'needs_input': True, 'message': message, 'requests': []})

    def process(self, work):
        if work['step'] == 'tailor' and work['context'].get('resume_format') == 'records':
            return self.tailor(work)
        from agents.worker import dispatch
        from agents.staging_openai import lease_context
        lease = {key: work[key] for key in ('id', 'owner', 'lease')}
        binding = lease_context.set(lease)
        try:
            result = dispatch(work, self.token)
        except Exception as error:
            print(f"step={work['step']} outcome=error type={type(error).__name__}", flush=True)
            result = {'needs_input': True, 'message': str(error) if isinstance(error, ValueError)
                      else 'AI generation could not finish. Please retry.', 'requests': []}
        finally:
            lease_context.reset(binding)
        if self.rpc('agent_lease_active', **lease).get('active'):
            self.rpc('agent_finish', **lease, result=result)

    def run(self):
        print(f'tailor worker ready model={MODEL} effort=low slots={SLOTS}', flush=True)
        from agents.staging_openai import start_server
        start_server(self.sol)
        pending = set()
        with ThreadPoolExecutor(max_workers=SLOTS) as pool:
            while True:
                finished, pending = wait(pending, timeout=.1 if len(pending) == SLOTS else 0,
                                         return_when=FIRST_COMPLETED)
                for task in finished:
                    if task.exception():
                        print(f'tailor worker result error type={type(task.exception()).__name__}', flush=True)
                if len(pending) == SLOTS:
                    continue
                try:
                    work = self.rpc('agent_claim', steps=['tailor', 'fit', 'draft', 'profile', 'story', 'coach', 'interview_turn',
                                                        'interview_coach', 'linkedin_review', 'sync'], inference_only=True)
                    if 'lease' in work:
                        pending.add(pool.submit(self.process, work))
                    elif not finished:
                        time.sleep(.5)
                except (ValueError, OSError, RuntimeError) as error:
                    print(f'tailor worker claim error type={type(error).__name__}', flush=True)
                    time.sleep(1)


if __name__ == '__main__':
    cache = Path('.jac/tectonic-cache')
    cache.parent.mkdir(exist_ok=True)
    if not cache.is_symlink():
        cache.symlink_to(Path('/opt/stack-rust/current/score-docs/tex-cache'), target_is_directory=True)
    Worker().run()
