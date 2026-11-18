"""Validation shared by the API and workers. No credentials or mutable state."""
import hashlib;
import json;
import math;
import os;
import re;
import time;
import from pathlib { Path }
import from urllib.parse { urlsplit }
with entry {
    VERSION = 1;
    CLI_PROVIDERS = {'codex-cli', 'claude-cli'};
    LOCAL_PROVIDERS = {'ollama', 'lmstudio'};
    MODEL_CONTEXT_TOKENS = 32768;
    MODEL_OUTPUT_TOKENS = 6144;
    PROVIDERS = CLI_PROVIDERS | LOCAL_PROVIDERS | {'openai', 'meta'};
    STEPS = {
        'autofill': ['browser_autofill'],
        'linkedin': ['linkedin_scan', 'linkedin_review'],
        'linkedin_pdf': ['linkedin_pdf', 'linkedin_review'],
        'live': ['interview'],
        'jobs': ['fit'],
        'resume': ['tailor', 'approve_resume'],
        'network': ['research', 'draft', 'send'],
        'profile': ['profile'],
        'prep': ['coach'],
        'stories': ['story'],
        'interview_turn': ['interview_turn'],
        'interview_coach': ['interview_coach'],
        'sync': ['sync'],
        'code': ['execute'],
        'calendar': ['calendar']
    };
    MODEL_STEPS = {'linkedin_review', 'fit', 'tailor', 'draft', 'coach', 'profile', 'story', 'interview_turn', 'interview_coach'};
    EXTERNAL = {
        'send': 'send_email',
        'calendar': 'calendar_write'
    };
    TERMINAL = {'completed', 'cancelled', 'failed'};
    FACT_KEYS = {
        'name',
        'email',
        'phone',
        'location',
        'linkedin',
        'website',
        'work_authorization',
        'sponsorship',
        'salary',
        'relocation',
        'availability'
    };
}
def digest(value: any) -> str {
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    ).hexdigest();
}
"""Deployment config is private, never accepted from a mobile client."""
def config(selection: str = "") -> dict[(str, any)] {
    if selection not in ('', 'codex-cli', 'local') { raise ValueError('Choose Codex CLI or Local model.'); }
    path = Path(os.environ.get('STACK_AGENT_CONFIG', 'storage/agents/config.json'));
    try {
        try { raw = json.loads(path.read_text()); }
        except FileNotFoundError { raw = {}; }
        if not isinstance(raw, `dict) { raise ValueError('Agent configuration must be a JSON object.'); }
        return _read_config(raw, selection);
    } except (OSError, ValueError, TypeError, AttributeError, OverflowError) {
        raise ValueError('Agent configuration is invalid. Check STACK_AGENT_CONFIG for a readable JSON object and valid limits.') from None;
    }
}

def first_party_ai_only() -> bool {
    return os.environ.get("STACK_FIRST_PARTY_AI_ONLY") == "1";
}

def _read_config(raw: dict[str, any], selection: str) -> dict[(str, any)] {
    if first_party_ai_only() { selection = "local"; }
    # Model overrides do not control admission. Only a JSON false in the deployment config opens it.
    invite_only = raw.get('invite_only') is not False;
    if selection {
        chosen = raw.get('model_options', {}).get(selection, {});
        if selection == 'codex-cli' {
            raw = {**raw, 'model': raw.get('model', '') if raw.get('provider') == 'codex-cli' else '', **chosen, 'provider': 'codex-cli'};
        } else {
            if not chosen and raw.get('provider') not in LOCAL_PROVIDERS {
                raw = {**raw, 'provider': 'ollama', 'model': '', 'local_model_url': ''};
            } else { raw = {**raw, **chosen}; }
            if raw.get('provider') not in LOCAL_PROVIDERS { raw = {**raw, 'provider': 'ollama', 'model': '', 'local_model_url': ''}; }
        }
    }
    # Optional faster model for the coach step, per provider (#124). Present only when
    # set, so deployments without it keep their configuration digest.
    coach = raw.get('coach_models', {});
    chosen_coach = {str(k): str(v).strip() for (k, v) in coach.items() if str(v).strip()} if isinstance(coach, `dict) else {};
    extra: dict[str, any] = {'coach_models': chosen_coach} if chosen_coach else {};
    fallback_api = raw.get('fallback_api', {});
    if not isinstance(fallback_api, `dict) { raise ValueError('Invalid fallback API configuration.'); }
    fallback = raw.get('fallback_enabled', True) is True and not first_party_ai_only();
    extra['fallback_enabled'] = fallback;
    if fallback_api {
        extra['fallback_api'] = {
            'provider': str(fallback_api.get('provider', 'openai')),
            'model': str(fallback_api.get('model', ''))
        };
    }
    return {
        **extra,
        'provider': str(raw.get('provider', 'openai')),
        'monthly_cents': int(raw.get('monthly_cents', 0)),
        'user_monthly_cents': int(raw.get('user_monthly_cents', 0)),
        'model': str(raw.get('model', '')),
        'local_model_url': str(raw.get('local_model_url', '')),
        'local_model_timeout': min(90, max(5, int(raw.get('local_model_timeout', 90)))),
        'local_model_context_tokens': min(MODEL_CONTEXT_TOKENS, max(1024, int(raw.get('local_model_context_tokens', MODEL_CONTEXT_TOKENS)))),
        'max_output_tokens': min(
            MODEL_OUTPUT_TOKENS, max(256, int(raw.get('max_output_tokens', MODEL_OUTPUT_TOKENS)))
        ),
        'action_daily_limits': raw.get('action_daily_limits', {}),
        'invite_only': invite_only,
        'web_url': str(raw.get('web_url', '')),
        'sandbox_available': (raw.get('sandbox_available') is True)
    };
}
def model_context_limit(c: dict[str, any]) -> int {
    if c['provider'] in LOCAL_PROVIDERS {
        return min(MODEL_CONTEXT_TOKENS, c.get('local_model_context_tokens', MODEL_CONTEXT_TOKENS));
    }
    return MODEL_CONTEXT_TOKENS;
}

# UTF-8 bytes conservatively account for input tokens, including the schema.
def model_request_size(system: str, prompt: str, schema: dict[str, any], output_tokens: int) -> int {
    return len(system.encode()) + len(prompt.encode()) + len(json.dumps(schema).encode()) + output_tokens + 512;
}

def model_access(c: dict[(str, any)], owner: str) {
    if (c['provider'] not in PROVIDERS) {
        raise ValueError('Choose a supported model provider.');
    }
    if (c['provider'] not in CLI_PROVIDERS) {
        if (c['provider'] in LOCAL_PROVIDERS) {
            import from agents.local_model { origin }
            try { origin(c['provider'], c.get('local_model_url', '')); }
            except ValueError { if not c.get('fallback_enabled') { raise; } }
            if not c['model'].strip() and not c.get('fallback_enabled') { raise ValueError('Choose an installed local model.'); }
        } elif not c['model'].strip() {
            raise ValueError('The operator must configure an API model.');
        }
    }
}
def model_status(owner: str, selection: str = "") -> dict[(str, any)] {
    c = config(selection);
    try {
        model_access(c, owner);
        message = 'No local model is configured; Codex and Claude are checked when a task runs.'
            if c['provider'] in LOCAL_PROVIDERS and not c['model'].strip() and c.get('fallback_enabled')
            else 'Local subscription selected; the server CLI sign-in is checked when a task runs.'
            if (c['provider'] in CLI_PROVIDERS)
            else 'Local inference configured; the installed model and service are checked when a task runs.'
            if (c['provider'] in LOCAL_PROVIDERS)
            else 'API model configured; provider credentials are checked when a task runs.';
        ready = True;
    } except ValueError as exc {
        (message, ready) = (str(exc), False);
    }
    return {
        'provider': c['provider'],
        'model': c['model'],
        'configured': ready,
        'billing': 'subscription' if (c['provider'] in CLI_PROVIDERS) else 'local' if (c['provider'] in LOCAL_PROVIDERS) else 'api',
        'message': message
    };
}
def default_policy() -> dict[(str, any)] {
    return {
        'enabled': False,
        'actions': [],
        'domains': [],
        'daily_limits': {},
        'expires_at': 0,
        'followup_limit': 0,
        'followup_days': 7,
        'analyze_top_matches': False
    };
}
def validate_policy(value: dict[(str, any)]) -> dict[(str, any)] {
    allowed = {'send_email', 'calendar_write', 'gmail_read'};
    accepted = allowed | {'model'};
    p = default_policy();
    p.update(
        {
            k: value[k]
            for k in p
            if (k in value)
        }
    );
    if (
        not isinstance(p['enabled'], bool)
        or not isinstance(p['actions'], `list)
        or not (`set(p['actions']) <= accepted)
    ) {
        raise ValueError('Choose valid agent permissions.');
    }
    if not isinstance(p['analyze_top_matches'], bool) {
        raise ValueError('Choose whether to analyze top matches.');
    }
    if (not isinstance(p['domains'], `list) or (len(p['domains']) > 100)) {
        raise ValueError('Use at most 100 destination domains.');
    }
    p['domains'] = sorted(`set(str(x).strip().lower() for x in p['domains']));
    if `any(
        not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}', x)
        for x in p['domains']
    ) {
        raise ValueError('Use exact domain names, without wildcards or URLs.');
    }
    if (
        not isinstance(p['daily_limits'], `dict)
        or `any(
            ((k not in accepted) or (`type(v) is not int) or (v < 1) or (v > 100))
            for (k, v) in p['daily_limits'].items()
        )
    ) {
        raise ValueError('Daily limits must be between 1 and 100.');
    }
    # Model use is no longer a standing permission. Silently migrate saved policies
    # and older clients while preserving outbound-action controls.
    p['actions'] = [a for a in p['actions'] if a != 'model'];
    p['daily_limits'] = {k: v for (k, v) in p['daily_limits'].items() if k != 'model'};
    if (
        (`type(p['expires_at']) not in (int, float))
        or not math.isfinite(p['expires_at'])
    ) {
        raise ValueError('Choose a valid permission expiration.');
    }
    if (
        p['enabled']
        and (
            (p['expires_at'] <= time.time())
            or (p['expires_at'] > (time.time() + (366 * 86400)))
        )
    ) {
        raise ValueError('Permissions must expire within one year.');
    }
    if (
        (`type(p['followup_limit']) is not int) or not (0 <= p['followup_limit'] <= 3)
    ) {
        raise ValueError('Choose zero to three follow-ups.');
    }
    if (
        (`type(p['followup_days']) is not int) or not (3 <= p['followup_days'] <= 30)
    ) {
        raise ValueError('Space follow-ups between 3 and 30 days apart.');
    }
    return p;
}
def authorize(
    policy: dict[(str, any)],
    action: str,
    destination: str = '',
    now: (float | None) = None
) -> None {
    # Keep older callers working while making model use independent of standing
    # permissions. Only outbound actions are authorized here now.
    if action == 'model' { return; }
    if (
        not policy.get('enabled')
        or (policy.get('expires_at', 0) <= (now or time.time()))
        or (action not in policy.get('actions', []))
    ) {
        raise ValueError(
            (
                'Enable an unexpired standing permission for '
                + action.replace('_', ' ')
                + '.'
            )
        );
    }
    if destination {
        host = urlsplit(destination).hostname
            if destination.startswith('https://')
            else destination.rsplit('@', 1)[-1].lower();
        if (host not in policy.get('domains', [])) {
            raise ValueError(
                ('This destination is outside your standing permissions: ' + str(host))
            );
        }
    }
    if (
        (action in EXTERNAL.values()) and not policy.get('daily_limits', {}).get(action)
    ) {
        raise ValueError('Set a daily limit for this action.');
    }
}
def validate_facts(items: list[dict[(str, any)]]) -> list[dict[(str, any)]] {
    if (not isinstance(items, `list) or (len(items) > 250)) {
        raise ValueError('Save at most 250 facts at a time.');
    }
    out = [];
    for item in items {
        (key, value) = (
            str(item.get('key', '')).strip(),
            str(item.get('value', '')).strip()
        );
        if (
            not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,100}', key)
            or not value
            or (len(value) > 8000)
        ) {
            raise ValueError(
                'Each fact needs a key and a value under 8,000 characters.'
            );
        }
        if (
            (key == 'email') and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value)
        ) {
            raise ValueError('Enter a valid email address.');
        }
        out.append(
            {
                'key': key,
                'value': value,
                'source': str(item.get('source', 'User confirmed'))[:500],
                'verified': (item.get('verified') is True),
                'resume_id': str(item.get('resume_id', ''))[:100],
                'updated_at': time.time()
            }
        );
    }
    if (len({x['key'] for x in out}) != len(out)) {
        raise ValueError('Fact keys must be unique.');
    }
    return out;
}
def context_facts(
    facts: list[dict[(str, any)]], context: dict[(str, any)]
) -> list[dict[(str, any)]] {
    selected = context.get('resume_id', '');
    out = [
        f
        for f in facts
        if (not selected or not f.get('resume_id') or (f['resume_id'] == selected))
    ];
    # Explicit saved Profile name is a task snapshot, never split into inferred names.
    for f in context.get('autofill_profile',[]) {
        if f.get('key')=='name' and not [x for x in out if x['key']=='name'] { out.append(f); }
    }
    return out;
}
def validate_contact(data: dict[(str, any)]) -> dict[(str, any)] {
    (name, email) = (
        str(data.get('name', '')).strip(),
        str(data.get('email', '')).strip().lower()
    );
    if (
        not name
        or (len(name) > 120)
        or (email and not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', email))
    ) {
        raise ValueError('Enter a name and a valid, verified email address.');
    }
    source_url = str(data.get('source_url', ''))[:2000];
    if (source_url and (urlsplit(source_url).scheme != 'https')) {
        raise ValueError('Use an HTTPS research source.');
    }
    return {
        'name': name,
        'email': email,
        'company': str(data.get('company', ''))[:160],
        'source_url': source_url,
        'role': str(data.get('role', ''))[:160],
        'source': str(data.get('source', ''))[:2000],
        'relationship': str(data.get('relationship', ''))[:2000],
        'selected': (data.get('selected') is True),
        'stopped': False
    };
}
def validate_evidence(items: list[dict[str, any]], sources: dict[str, str]) -> list[dict[str, any]] {
    for item in items {
        if (
            not item.get('quote')
            or (item.get('source') not in sources)
            or (item['quote'] not in sources[item['source']])
        ) {
            raise ValueError('The generated claim has no matching source quotation.');
        }
    }
    return items;
}
def summarize_run(run: dict[str, any]) -> dict[str, any] {
    return {
        k: run.get(k)
        for k in (
            'id',
            'kind',
            'target_id',
            'status',
            'step',
            'message',
            'created_at',
            'updated_at',
            'cost_cents'
        )
    };
}

# Version 1 is the workflow persisted before per-resume review was introduced.
def workflow_steps(kind: str, version: int = 2) -> list[str] {
    if version == 1 and kind == "resume" { return ["tailor"]; }
    # Read-only step names for archived records; application is absent from STEPS.
    if kind == "application" { return ["inspect", "fit", "tailor"] + ([] if version == 1 else ["approve_resume"]) + ["fill", "submit"]; }
    return STEPS[kind];
}
