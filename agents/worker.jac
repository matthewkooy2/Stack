"""Resumable adapter worker; claims and external-action authority come from Jac."""
import json;
import os;
import from pathlib { Path }
import time;
import urllib.request;
import from agents.contracts { CLI_PROVIDERS, config, digest, model_access }
def call(name: str, args: dict[str, any]) -> dict[str, any] {
    base = os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000');
    request = urllib.request.Request(
        (base + '/function/' + name),
        data=json.dumps(args).encode(),
        headers={'Content-Type': 'application/json'}
    );
    with urllib.request.urlopen(request, timeout=110) as response {
        value = json.load(response)['data']['result'];
    }
    if value.get('error') {
        raise ValueError(value['error']);
    }
    return value;
}
def browser_call(step: str, work: dict[str, any]) -> dict[str, any] {
    # The private browser origin is operator-owned, never taken from task content.
    base = os.environ.get('STACK_BROWSER_URL', '');
    token = os.environ.get('STACK_BROWSER_TOKEN', '');
    if (not base or not token) {
        raise ValueError(
            'Browser automation is unavailable until the browser worker is configured.'
        );
    }
    request = urllib.request.Request(
        (base.rstrip('/') + '/' + step),
        data=json.dumps(work).encode(),
        headers={
            'Content-Type': 'application/json',
            'Authorization': ('Bearer ' + token)
        }
    );
    with urllib.request.urlopen(request, timeout=100) as response {
        result = json.load(response);
    }
    if result.get('error') {
        raise ValueError(result['error']);
    }
    return result;
}
def dispatch(work: dict[str, any], token: str) -> dict[str, any] {
    import from agents.provider { generate }
    (step, context, artifacts) = (work['step'], work['context'], work['artifacts']);
    auth = {k: work[k] for k in ('id', 'owner', 'lease')};
    auth['token'] = token;
    if (step == 'research') {
        import from agents.research { contact_source }
        return {'artifact': contact_source(context['contact'])};
    }
    if (step in ('fit', 'tailor', 'draft', 'coach', 'profile')) {
        c = config();
        if (work.get('provider_config_hash') != digest(c)) {
            return {
                'needs_input': True,
                'message': 'Model configuration changed. Resume this task to use the current provider.',
                'requests': []
            };
        }
        model_access(c, work['owner']);
        if (
            (step == 'tailor')
            and not `any(
                (f['key'].startswith('resume.') and f.get('verified'))
                for f in context.get('facts', [])
            )
        ) {
            return {
                'needs_input': True,
                'message': 'Confirm the facts extracted from your resume before tailoring.',
                'requests': []
            };
        }
        try {
            result = generate(
                step, {** context, 'research': artifacts.get('research', {})}, c
            );
        } except ValueError as exc {
            if (c['provider'] in CLI_PROVIDERS) {
                return {'needs_input': True, 'message': str(exc), 'requests': []};
            }
            raise;
        }
        if (step == 'tailor') {
            import from agents.documents { render_variant }
            facts = {
                f['key']: f
                for f in context['facts']
                if (f.get('verified') and f['key'].startswith('resume.'))
            };
            keys = result['artifact']['ordered_fact_keys'];
            if ((len(keys) != len(`set(keys))) or (`set(keys) != `set(facts))) {
                raise ValueError(
                    'Tailoring omitted or introduced facts. Review it before use.'
                );
            }
            result['artifact']['pdf'] = render_variant(
                context.get('profile', {}).get('name', 'Resume'),
                context.get('resume_text', ''),
                [facts[k] for k in keys]
            );
            fields = artifacts.get('inspect', {}).get('fields', []);
            if `any(
                (('cover' in f['label'].lower()) and ('letter' in f['label'].lower()))
                for f in fields
            ) {
                job = context['job'];
                letter = [
                    {
                        'key': 'intro',
                        'value': (
                            'I am applying for the '
                            + job['title']
                            + ' role at '
                            + job['company']
                            + '.'
                        )
                    }
                ];
                letter += [facts[k] for k in keys[:3]];
                letter += [
                    {
                        'key': 'closing',
                        'value': 'Thank you for considering my application.'
                    }
                ];
                result['artifact']['cover_letter'] = render_variant(
                    context.get('profile', {}).get('name', ''), '', letter
                );
                result['artifact']['cover_letter']['name'] = 'Cover letter.pdf';
            }
        }
        return result;
    }
    if (step in ('inspect', 'fill', 'submit')) {
        if (step != 'inspect') {
            call(
                'agent_authorize',
                {** auth, 'payload_hash': digest([context, artifacts])}
            );
        }
        return browser_call(step, work);
    }
    if (step in ('send', 'sync', 'calendar')) {
        import from agents { google }
        connection = call('agent_worker_connection', auth);
        if (step == 'calendar') {
            call(
                'agent_authorize', {** auth, 'payload_hash': digest(context['event'])}
            );
            calendar_id = (
                connection['calendar_id']
                or google.create_calendar(connection['tokens'])
            );
            event = `dict(context['event']);
            uid = event.pop('uid');
            result = google.add_event(connection['tokens'], calendar_id, event, uid);
            return {'artifact': {'receipt': result['id'], 'calendar_id': calendar_id}};
        }
        if (step == 'send') {
            authority = call(
                'agent_authorize', {** auth, 'payload_hash': digest(artifacts['draft'])}
            );
            receipt = google.send(
                connection['tokens'],
                context['contact'],
                artifacts['draft'],
                authority['action_id'],
                context.get('thread_id', '')
            );
            return {'artifact': receipt};
        }
        result = google.synchronize(
            connection['tokens'],
            connection.get('checkpoint', {}),
            context.get('applications', []),
            context.get('contacts', []),
            context.get('interviews', [])
        );
        return {'artifact': result};
    }
    if (step == 'execute') {
        base = os.environ.get('STACK_SANDBOX_URL', '');
        secret = os.environ.get('STACK_SANDBOX_TOKEN', '');
        if (not base or not secret) {
            return {
                'needs_input': True,
                'message': 'Code execution needs a configured isolated sandbox. Your code is saved.',
                'requests': []
            };
        }
        request = urllib.request.Request(
            (base.rstrip('/') + '/execute'),
            data=json.dumps(context['session']).encode(),
            headers={
                'Content-Type': 'application/json',
                'Authorization': ('Bearer ' + secret)
            }
        );
        with urllib.request.urlopen(request, timeout=45) as response {
            artifact = json.load(response);
        }
        return {'artifact': artifact};
    }
    raise ValueError('Unsupported worker step.');
}
def main() {
    token = (
        os.environ.get('STACK_AGENT_WORKER_TOKEN', '')
        or Path('storage/agents/worker-token').read_text().strip()
    );
    last_tick = 0.0;
    while True {
        try {
            if ((time.time() - last_tick) > 60) {
                call('agent_schedule', {'token': token});
                last_tick = time.time();
                try {
                    import from agents.pubsub { notifications, acknowledge }
                    batch = notifications();
                    if batch {
                        call(
                            'agent_schedule', {'token': token, 'wake_key': batch['key']}
                        );
                        acknowledge(batch);
                    }
                } except Exception {
                    print(
                        'Gmail notifications unavailable; checkpoint recovery polling remains active.',
                        flush=True
                    );
                }
            }
            notice = call('agent_notification_claim', {'token': token});
            if not notice.get('idle') {
                import from agents.notifications { deliver }
                receipts = [];
                for device in notice['devices'] {
                    try {
                        receipts.append(deliver(device, notice));
                    } except Exception {
                        ;
                    }
                }
                call(
                    'agent_notification_finish',
                    {
                        'token': token,
                        'owner': notice['owner'],
                        'id': notice['id'],
                        'receipt': ','.join(receipts)
                    }
                );
            }
            work = call('agent_claim', {'token': token});
            if work.get('idle') {
                time.sleep(3);
                continue;
            }
            try {
                result = dispatch(work, token);
            } except Exception as exc {
                result = {
                    'error': str(exc)
                        if isinstance(exc, ValueError)
                        else ('Adapter unavailable (' + `type(exc).__name__ + ').')
                };
            }
            call(
                'agent_finish',
                {
                    'token': token,
                    ** {k: work[k] for k in ('id', 'owner', 'lease')},
                    'result': result
                }
            );
        } except KeyboardInterrupt {
            break;
        } except Exception {
            print(
                'Agent worker waiting for API; durable work will resume.', flush=True
            );
            time.sleep(5);
        }
    }
}
with entry:__main__ { main(); }
