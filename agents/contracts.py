"""Validation shared by the API and workers. No credentials or mutable state."""
import hashlib
import json
import math
import os
import re
import time
from typing import Any
from pathlib import Path
from urllib.parse import urlsplit

VERSION = 1
CLI_PROVIDERS = {'codex-cli', 'claude-cli'}
PROVIDERS = CLI_PROVIDERS | {'openai', 'meta'}
STEPS = {
    'live': ['interview'], 'jobs': ['fit'], 'resume': ['tailor'],
    'application': ['inspect', 'fit', 'tailor', 'fill', 'submit'],
    'network': ['research', 'draft', 'send'], 'profile': ['profile'], 'prep': ['coach'], 'sync': ['sync'], 'code': ['execute'], 'calendar': ['calendar'],
}
PAID = {'fit', 'tailor', 'draft', 'coach', 'profile'}
EXTERNAL = {'fill': 'browser_fill', 'submit': 'submit_application',
            'send': 'send_email', 'calendar': 'calendar_write'}
TERMINAL = {'completed', 'cancelled', 'failed'}
FACT_KEYS = {'name', 'email', 'phone', 'location', 'linkedin', 'website',
             'work_authorization', 'sponsorship', 'salary', 'relocation', 'availability'}


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def config() -> dict[str, Any]:
    """Deployment config is private, never accepted from a mobile client."""
    path = Path(os.environ.get('STACK_AGENT_CONFIG', 'storage/agents/config.json'))
    raw = json.loads(path.read_text()) if path.exists() else {}
    return {
        'provider': str(raw.get('provider', 'openai')),
        'local_cli_owner': str(raw.get('local_cli_owner', '')),
        'local_cli_daily_limit': int(raw.get('local_cli_daily_limit', 0)),
        'monthly_cents': int(raw.get('monthly_cents', 0)),
        'user_monthly_cents': int(raw.get('user_monthly_cents', 0)),
        'model': str(raw.get('model', '')),
        'input_cents_per_million': int(raw.get('input_cents_per_million', 0)),
        'output_cents_per_million': int(raw.get('output_cents_per_million', 0)),
        'max_output_tokens': min(12000, max(256, int(raw.get('max_output_tokens', 3000)))),
        'certified_adapters': [x for x in raw.get('certified_adapters', []) if x in ('greenhouse', 'lever', 'ashby')],
        'action_daily_limits': raw.get('action_daily_limits', {}),
        'invite_only': bool(raw.get('invite_only', False)),
        'web_url': str(raw.get('web_url', '')),
    }


def model_access(c: dict[str, Any], owner: str) -> None:
    if c['provider'] not in PROVIDERS:
        raise ValueError('Choose a supported model provider.')
    if c['provider'] in CLI_PROVIDERS:
        if not owner or c['local_cli_owner'] != owner:
            raise ValueError('The operator must connect this Stack account to the local CLI subscription.')
        if not 1 <= c['local_cli_daily_limit'] <= 100:
            raise ValueError('Set a local CLI daily request limit between 1 and 100.')
    elif not all(c[k] > 0 for k in ('monthly_cents', 'user_monthly_cents', 'input_cents_per_million', 'output_cents_per_million')) or not c['model']:
        raise ValueError('Paid agents are disabled. The operator must configure a model, prices, and monthly limits.')


def model_status(owner: str) -> dict[str, Any]:
    c = config()
    try:
        model_access(c, owner)
        message = 'Local subscription selected; CLI sign-in and provider limits still apply.' if c['provider'] in CLI_PROVIDERS else 'API billing configured; provider credentials are checked when a task runs.'
        ready = True
    except ValueError as exc:
        message, ready = str(exc), False
    return {'provider': c['provider'], 'model': c['model'], 'configured': ready,
            'billing': 'subscription' if c['provider'] in CLI_PROVIDERS else 'api',
            'message': message, 'daily_limit': c['local_cli_daily_limit'] if c['provider'] in CLI_PROVIDERS else 0}


def reserve_cents(context: dict[str, Any]) -> int:
    c = config()
    if c['provider'] in CLI_PROVIDERS:
        raise ValueError('Local subscriptions use request limits, not API spend reservations.')
    if not all(c[k] > 0 for k in ('monthly_cents', 'user_monthly_cents', 'input_cents_per_million', 'output_cents_per_million')) or not c['model']:
        raise ValueError('Paid agents are disabled. The operator must configure a model, prices, and monthly limits.')
    # UTF-8 bytes conservatively bound tokens; include instructions and output schema.
    upper = 3 * len(json.dumps(context).encode()) + 16000
    return max(1, math.ceil((upper * c['input_cents_per_million'] + c['max_output_tokens'] * c['output_cents_per_million']) / 1_000_000))


def default_policy() -> dict[str, Any]:
    return {'enabled': False, 'actions': [], 'domains': [], 'daily_limits': {},
            'expires_at': 0, 'followup_limit': 0, 'followup_days': 7, 'analyze_top_matches': False}


def validate_policy(value: dict[str, Any]) -> dict[str, Any]:
    allowed = {'model', 'browser_fill', 'submit_application', 'send_email', 'calendar_write', 'gmail_read'}
    p = default_policy()
    p.update({k: value[k] for k in p if k in value})
    if not isinstance(p['enabled'], bool) or not isinstance(p['actions'], list) or not set(p['actions']) <= allowed:
        raise ValueError('Choose valid agent permissions.')
    if not isinstance(p['analyze_top_matches'], bool): raise ValueError('Choose whether to analyze top matches.')
    if not isinstance(p['domains'], list) or len(p['domains']) > 100:
        raise ValueError('Use at most 100 destination domains.')
    p['domains'] = sorted(set(str(x).strip().lower() for x in p['domains']))
    if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}', x) for x in p['domains']):
        raise ValueError('Use exact domain names, without wildcards or URLs.')
    if not isinstance(p['daily_limits'], dict) or any(k not in allowed or type(v) is not int or v < 1 or v > 100 for k, v in p['daily_limits'].items()):
        raise ValueError('Daily limits must be between 1 and 100.')
    if type(p['expires_at']) not in (int, float) or not math.isfinite(p['expires_at']):
        raise ValueError('Choose a valid permission expiration.')
    if p['enabled'] and (p['expires_at'] <= time.time() or p['expires_at'] > time.time() + 366 * 86400):
        raise ValueError('Permissions must expire within one year.')
    if type(p['followup_limit']) is not int or not 0 <= p['followup_limit'] <= 3:
        raise ValueError('Choose zero to three follow-ups.')
    if type(p['followup_days']) is not int or not 3 <= p['followup_days'] <= 30:
        raise ValueError('Space follow-ups between 3 and 30 days apart.')
    return p


def authorize(policy: dict[str, Any], action: str, destination: str = '', now: float | None = None) -> None:
    if not policy.get('enabled') or policy.get('expires_at', 0) <= (now or time.time()) or action not in policy.get('actions', []):
        raise ValueError('Enable an unexpired standing permission for ' + action.replace('_', ' ') + '.')
    if destination:
        host = urlsplit(destination).hostname if destination.startswith('https://') else destination.rsplit('@', 1)[-1].lower()
        if host not in policy.get('domains', []):
            raise ValueError('This destination is outside your standing permissions: ' + str(host))
    if action in EXTERNAL.values() and not policy.get('daily_limits', {}).get(action):
        raise ValueError('Set a daily limit for this action.')


def validate_facts(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not isinstance(items, list) or len(items) > 250:
        raise ValueError('Save at most 250 facts at a time.')
    out = []
    for item in items:
        key, value = str(item.get('key', '')).strip(), str(item.get('value', '')).strip()
        if not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,100}', key) or not value or len(value) > 8000:
            raise ValueError('Each fact needs a key and a value under 8,000 characters.')
        if key == 'email' and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value):
            raise ValueError('Enter a valid email address.')
        out.append({'key': key, 'value': value, 'source': str(item.get('source', 'User confirmed'))[:500],
                    'verified': item.get('verified') is True, 'resume_id': str(item.get('resume_id', ''))[:100], 'updated_at': time.time()})
    if len({x['key'] for x in out}) != len(out):
        raise ValueError('Fact keys must be unique.')
    return out


def answers(facts):
    return {f['key']: f['value'] for f in facts if f.get('verified')}


def context_facts(facts: list[dict[str, Any]], context: dict[str, Any]) -> list[dict[str, Any]]:
    selected = context.get('resume_id', '')
    return [f for f in facts if not selected or not f.get('resume_id') or f['resume_id'] == selected]


def adapter_for(url):
    p = urlsplit(url)
    if p.scheme != 'https' or p.username or p.password:
        return ''
    host = (p.hostname or '').lower()
    if host in ('boards.greenhouse.io', 'job-boards.greenhouse.io', 'boards.eu.greenhouse.io', 'job-boards.eu.greenhouse.io'):
        return 'greenhouse'
    if host in ('jobs.lever.co', 'jobs.eu.lever.co'):
        return 'lever'
    if host == 'jobs.ashbyhq.com':
        return 'ashby'
    return ''


def validate_contact(data: dict[str, Any]) -> dict[str, Any]:
    name, email = str(data.get('name', '')).strip(), str(data.get('email', '')).strip().lower()
    if not name or len(name) > 120 or (email and not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', email)):
        raise ValueError('Enter a name and a valid, verified email address.')
    source_url = str(data.get('source_url', ''))[:2000]
    if source_url and urlsplit(source_url).scheme != 'https': raise ValueError('Use an HTTPS research source.')
    return {'name': name, 'email': email, 'company': str(data.get('company', ''))[:160], 'source_url': source_url,
            'role': str(data.get('role', ''))[:160], 'source': str(data.get('source', ''))[:2000],
            'relationship': str(data.get('relationship', ''))[:2000], 'selected': data.get('selected') is True,
            'stopped': False}


def validate_evidence(items, sources):
    for item in items:
        if not item.get('quote') or item.get('source') not in sources or item['quote'] not in sources[item['source']]:
            raise ValueError('The generated claim has no matching source quotation.')
    return items


def summarize_run(run):
    return {k: run.get(k) for k in ('id', 'kind', 'target_id', 'status', 'step', 'message', 'created_at', 'updated_at', 'cost_cents')}
