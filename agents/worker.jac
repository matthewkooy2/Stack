"""Resumable adapter worker; claims and external-action authority come from Jac."""
import json;
import os;
import from pathlib { Path }
import time;
import urllib.request;
import from agents.contracts { CLI_PROVIDERS, LOCAL_PROVIDERS, MODEL_STEPS, config, digest, model_access }
import from agents.tracing { trace_data }
import from agents.browser_control { BROWSER_OPERATIONS, BROWSER_ERROR_MESSAGE, browser_diagnostic, sanitize_browser_diagnostic }
def call(name: str, args: dict[str, any], timeout: any = 110) -> dict[str, any] {
    base = os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000');
    request = urllib.request.Request(
        (base + '/function/' + name),
        data=json.dumps(args).encode(),
        headers={'Content-Type': 'application/json'}
    );
    with urllib.request.urlopen(request, timeout=timeout) as response {
        value = json.load(response)['data']['result'];
    }
    if value.get('error') {
        raise ValueError(value['error']);
    }
    return value;
}
def browser_call(step: str, work: dict[str, any], timeout: int = 100) -> dict[str, any] {
    base = os.environ.get('STACK_BROWSER_URL', '');
    if not base { raise ValueError('Browser automation is unavailable until the browser worker is configured.'); }
    if step=='linkedin_scan' or work.get('linkedin',False) {
        request=urllib.request.Request(base.rstrip('/')+'/linkedin/'+step,
            data=json.dumps(work).encode(),headers={'Content-Type':'application/json'});
        with urllib.request.urlopen(request) as response { return json.load(response); }
    }
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
    started=time.monotonic();phase='rpc_transport';
    try {
        with urllib.request.urlopen(request, timeout=timeout) as response {
            phase='rpc_result';result = json.load(response);
        }
        if not isinstance(result,dict) { raise ValueError('Invalid browser response.'); }
    } except Exception as exc {
        if step not in BROWSER_OPERATIONS { raise; }
        return {'error':BROWSER_ERROR_MESSAGE,'browser_diagnostic':browser_diagnostic(step,phase,exc,int((time.monotonic()-started)*1000))};
    }
    if result.get('error') {
        if step in BROWSER_OPERATIONS {
            diagnostic=sanitize_browser_diagnostic(result.get('browser_diagnostic'));
            if not diagnostic or diagnostic['operation']!=step {
                diagnostic=browser_diagnostic(step,'rpc_result',Exception(),int((time.monotonic()-started)*1000));
            }
            return {'error':BROWSER_ERROR_MESSAGE,'browser_diagnostic':diagnostic};
        }
        raise ValueError(result['error']);
    }
    return result;
}
"""The leased account's confirmed memory (agents.memory_access), read through the API's lease check."""
def leased_memory(auth: dict[str, any], owner: str) -> dict[str, any] {
    import from agents.memory_access { validate }
    return validate(call('agent_worker_memory', auth), owner);
}

"""Tailor a reviewed-record resume from the whole memory bank (docs/MEMORY_TAILORING.md)."""
def memory_tailor(work: dict[str, any], auth: dict[str, any], c: dict[str, any], prepared: any,
                  before: any, observe: any, record: any, cancellation: any = None) -> dict[str, any] {
    import from agents.provider { generate, run_with_fallback }
    import from agents.scoring { score, summary }
    import agents.memory_tailoring as memory_tailoring;
    import agents.record_resume as record_resume;
    context = work['context'];
    def model(step: str, model_context: dict[str, any], configuration: dict[str, any]) -> dict[str, any] {
        # Verification keeps original wording if every provider fails.
        return generate(step, model_context, configuration, record=record, observe=observe,
                        cancellation=cancellation, allow_fallback=step == 'tailor_verify');
    }
    try {
        memory = leased_memory(auth, work['owner']);
        def plan(candidate: dict[str, any]) -> dict[str, any] {
            served = None;
            if candidate['provider'] in LOCAL_PROVIDERS {
                import from agents.local_model { served_context }
                served = served_context(candidate);
            }
            return memory_tailoring.run(prepared, memory, context.get('job', {}), candidate, model, served, context.get('resume_id', ''));
        }
        proposal = run_with_fallback(c, plan, observe, cancellation, allow_fallback=True);
        artifact = memory_tailoring.tailor(prepared, proposal);
    } except ValueError as exc {
        return {'needs_input': True, 'message': str(exc), 'requests': []};
    }
    job = context.get('job', {});
    if job {
        after = score(record_resume.prepare({**prepared, 'records': artifact['records']})['outline'], job, [],
            pages=artifact['pdf']['pages'], text='\n'.join(r['text'] for r in artifact['records']));
        artifact['score'] = {'before': summary(before), 'after': summary(after)};
    }
    return {'artifact': artifact, 'cost_cents': 0, 'provider_id': ''};
}

def dispatch(work: dict[str, any], token: str, observe: any = None, cancellation: any = None) -> dict[str, any] {
    (step, context, artifacts) = (work['step'], work['context'], work['artifacts']);
    auth = {k: work[k] for k in ('id', 'owner', 'lease')};
    auth['token'] = token;
    if step == 'browser_autofill' { return browser_call(step, work); }
    if (step == 'research') {
        import from agents.research { contact_source }
        return {'artifact': contact_source(context['contact'])};
    }
    if (step in ('linkedin_review', 'fit', 'tailor', 'draft', 'coach', 'profile', 'story', 'interview_turn', 'interview_coach')) {
        import from agents.provider { generate }
        c = config(work.get("model_selection", ""));
        if (work.get('provider_config_hash') != digest(c)) {
            if step == 'linkedin_review' {
                return {'blocked': True, 'message': 'Model configuration changed. Retry to use the current provider.'};
            }
            return {
                'needs_input': True,
                'message': 'Model configuration changed. Resume this task to use the current provider.',
                'requests': []
            };
        }
        model_access(c, work['owner']);
        model_context = {** context, 'research': artifacts.get('research', {}), 'linkedin_profile':artifacts.get('linkedin_scan', {})};
        if step == 'linkedin_review' {
            model_context = {'linkedin_profile':artifacts.get('linkedin_pdf', {}), 'target_role':context.get('target_role', '')};
        }
        if (step == 'story') {
            # Only this reviewed event goes to inference, not other resume facts
            # or past answers added by the general agent-memory workflow.
            import from agents.stories { model_source }
            model_context = {'story_source': model_source(context['story_source'])};
        }
        if (step == 'tailor') {
            import from agents.tailoring { prepare }
            try {
                source=call('agent_worker_resume_source', auth);
                if source.get('format')=='records' {
                    import agents.record_resume as record_resume;
                    prepared=record_resume.prepare(source);
                } else { prepared=prepare(source); }
            } except ValueError as exc {
                return {'needs_input': True, 'message': str(exc), 'requests': []};
            }
            import from agents.tailoring { baseline_score }
            import from agents.scoring { guidance }
            if prepared['format']=='records' {
                import from agents.scoring { score }
                before=score(prepared['outline'],context.get('job',{}),[],text='\n'.join(r['text'] for r in prepared['records']));
            } else {
                before = baseline_score(prepared,context.get('job', {}),[f for f in context.get('facts', []) if f.get('verified')]);
            }
            model_context = {
                ** model_context,
                'resume_structure': prepared['outline'],
                'resume_text': '',
                'score_guidance': guidance(before)
            };
            if prepared['format']=='records' {
                model_context['resume_selection_eligible']=[r['id'] for r in prepared['records'] if 'allow_omit' in r and r['allow_omit']];
            }
        }
        def record(attempt: dict[str, any]) -> None {
            try { call('agent_model_log', {**auth, 'record':attempt}); }
            except Exception { raise ValueError('Stack could not retain the model response log. Check the API before retrying.') from None; }
        }
        if step == 'tailor' and prepared['format'] == 'records' {
            return memory_tailor(work, auth, c, prepared, before, observe, record, cancellation);
        }
        try {
            result = generate(step, model_context, c, observe=observe, record=record, allow_fallback=True, cancellation=cancellation);
        } except ValueError as exc {
            if (c['provider'] in (CLI_PROVIDERS | LOCAL_PROVIDERS)) {
                return {'blocked': True, 'message': str(exc), 'requests': []} if step == 'linkedin_review' else {'needs_input': True, 'message': str(exc), 'requests': []};
            }
            raise;
        }
        if (step == 'tailor') {
            import from agents.tailoring { tailor }
            facts = [
                f
                for f in context.get('facts', [])
                if f.get('verified')
            ];
            try {
                if prepared['format']=='records' {
                    import agents.record_resume as record_resume;
                    result['artifact']=record_resume.tailor(prepared,result['artifact'],facts,context.get('job'));
                } else { result['artifact'] = tailor(prepared,result['artifact'],facts,context.get('job')); }
            } except ValueError as exc {
                return {'needs_input': True, 'message': str(exc), 'requests': []};
            }
        }
        return result;
    }
    if (step == 'approve_resume') {
        import from agents.tailoring { prepare, finalize }
        try {
            source=call('agent_worker_resume_source', auth);
            if source.get('format')=='records' {
                import agents.record_resume as record_resume;
                prepared=record_resume.prepare(source);
                if artifacts['tailor'].get('mode')=='memory' {
                    import agents.memory_tailoring as memory_tailoring;
                    return {'artifact':memory_tailoring.finalize(prepared,leased_memory(auth,work['owner']),artifacts['tailor'])};
                }
                return {'artifact':record_resume.finalize(prepared,artifacts['tailor'],context.get('job'))};
            }
            prepared = prepare(source);
            return {
                'artifact': finalize(
                    prepared,
                    artifacts['tailor'],
                    context.get('job'),
                    [
                        f
                        for f in context.get('facts', [])
                        if f.get('verified')
                    ]
                )
            };
        } except ValueError as exc {
            return {'needs_input': True, 'message': str(exc), 'requests': []};
        }
    }
    if (step in ('send', 'sync', 'calendar')) {
        import from agents { google }
        connection = call('agent_worker_connection', auth);
        if step=='sync' and context.get('manual_scan') {
            import from agents.mail_scan { scan_page }
            c=config('local');model_access(c,work['owner']);
            return {'artifact':scan_page(connection['tokens'],context,c)};
        }
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
            context.get('interviews', []),
            context.get('threads', {})
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
def notification_once(token: str) -> dict[str, any] {
    import from agents.notifications { deliver, receipt }
    notice = call('agent_notification_claim', {'token': token});
    if notice.get('idle') { return notice; }
    auth = {'token': token, **{k: notice[k] for k in ('owner', 'id', 'key', 'lease')}};
    if notice['phase'] == 'send' {
        call('agent_notification_begin', auth);
        result = deliver(notice['device'], notice);
    } else { result = receipt(notice['ticket']); }
    return call('agent_notification_finish', {**auth, 'result': result});
}

# Revoke in-flight inference as soon as its durable lease is cancelled or expires.
def watch_lease(stop_event: any, auth: dict[str, any], signal: any) -> None {
    while not stop_event.wait(1) {
        try {
            active=call('agent_lease_active', auth, timeout=3);
            if not active.get('active') and not stop_event.is_set() { signal.stop();return; }
        } except Exception { ; }
    }
}

def main() {
    token = (
        os.environ.get('STACK_AGENT_WORKER_TOKEN', '')
        or Path('storage/agents/worker-token').read_text().strip()
    );
    import from threading { Thread }
    import from agents.resume_processing { main as resume_main }
    Thread(target=resume_main,args=(token,),daemon=True).start();
    import from agents.transcription_worker { main as transcription_main }
    Thread(target=transcription_main,args=(token,),daemon=True).start();
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
            notification_once(token);
            work = call('agent_claim', {'token': token});
            if work.get('idle') {
                time.sleep(3);
                continue;
            }
            import from threading { Event, Lock }
            import from agents.local_model { InferenceCancellation }
            stopped=Event();cancellation=InferenceCancellation(gate=Lock()) if work['step'] in MODEL_STEPS else None;
            if cancellation is not None {
                Thread(target=watch_lease, args=(stopped, {'token':token, **{k:work[k] for k in ('id','owner','lease')}}, cancellation), daemon=True).start();
            }
            try {
                def observe(event: str, data: dict[str, any]) -> None {
                    call('agent_trace', {'token':token, **{k:work[k] for k in ('id','owner','lease')}, 'event':event, 'data':trace_data(data)});
                }
                result = dispatch(work, token, observe=observe, cancellation=cancellation);
            } except Exception as exc {
                result = {
                    'error': str(exc)
                        if isinstance(exc, ValueError)
                        else ('Adapter unavailable (' + `type(exc).__name__ + ').')
                };
            }
            stopped.set();
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
