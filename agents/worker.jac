"""Resumable adapter worker; claims and external-action authority come from Jac."""
import json;
import os;
import from pathlib { Path }
import time;
import urllib.request;
import from agents.contracts { CLI_PROVIDERS, LOCAL_PROVIDERS, config, digest, model_access }
import from agents.tracing { trace_data }
import from agents.browser_control { BROWSER_OPERATIONS, BROWSER_ERROR_MESSAGE, browser_diagnostic, sanitize_browser_diagnostic }
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
def browser_call(step: str, work: dict[str, any], timeout: int = 100) -> dict[str, any] {
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
def dispatch(work: dict[str, any], token: str, observe: any = None) -> dict[str, any] {
    import from agents.provider { generate }
    (step, context, artifacts) = (work['step'], work['context'], work['artifacts']);
    auth = {k: work[k] for k in ('id', 'owner', 'lease')};
    auth['token'] = token;
    if step == 'linkedin_scan' { return browser_call(step, work); }
    if (step == 'research') {
        import from agents.research { contact_source }
        return {'artifact': contact_source(context['contact'])};
    }
    if (step in ('fit', 'tailor', 'draft', 'coach', 'profile', 'linkedin_review')) {
        c = config();
        if (work.get('provider_config_hash') != digest(c)) {
            return {
                'needs_input': True,
                'message': 'Model configuration changed. Resume this task to use the current provider.',
                'requests': []
            };
        }
        model_access(c, work['owner']);
        model_context = {** context, 'research': artifacts.get('research', {}), 'linkedin_profile':artifacts.get('linkedin_scan', {})};
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
        }
        def record(attempt: dict[str, any]) -> None {
            try { call('agent_model_log', {**auth, 'record':attempt}); }
            except Exception { raise ValueError('Stack could not retain the model response log. Check the API before retrying.') from None; }
        }
        try {
            result = generate(step, model_context, c, observe=observe, record=record);
        } except ValueError as exc {
            if step == 'linkedin_review' { return {'blocked':True, 'message':str(exc), 'requests':[]}; }
            if (c['provider'] in (CLI_PROVIDERS | LOCAL_PROVIDERS)) {
                return {'needs_input': True, 'message': str(exc), 'requests': []};
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
                def observe(event: str, data: dict[str, any]) -> None {
                    call('agent_trace', {'token':token, **{k:work[k] for k in ('id','owner','lease')}, 'event':event, 'data':trace_data(data)});
                }
                result = dispatch(work, token, observe=observe);
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
