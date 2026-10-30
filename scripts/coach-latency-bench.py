"""Opt-in coaching latency benchmark (#124): real model calls with synthetic answers.

Times the coach step the way the worker runs it and splits the wall time into the
CLI sign-in check, the model call and Stack's own parsing. It makes real requests to
the configured provider, so subscription limits or API charges apply. No account,
database or server is involved.

    ./scripts/jac run --no-serve scripts/coach-latency-bench.py claude-cli --model claude-haiku-5-5 --repeat 3

With --workflow it instead runs the whole server path in a disposable account and
database (save the answer, queue the run, worker claim, coach, store, read back) and
times each phase. The production worker also waits up to 3 s between idle polls,
and the app polls every 0.8 s; neither is simulated here.
"""
import argparse
import json
import os
from pathlib import Path
import tempfile
import statistics
import time
from unittest.mock import patch

from agents import contracts, local_cli, prep, provider

ANSWERS = {
    'short': ('In a class project our team kept missing deadlines. I made a task list, asked each teammate to own one task '
              'and set a weekly check-in. We shipped on time.'),
    'typical': ('Last summer I interned on a payments team. Our nightly reconciliation job failed about twice a week and the '
                'on-call engineer had to rerun it by hand. I owned the investigation. I added logging, found that two upstream '
                'files sometimes arrived late, and proposed waiting on a file-ready signal instead of a fixed start time. My '
                'manager was worried about delaying reports, so I measured arrival times for a month and showed the job would '
                'still finish an hour before the deadline. After the change we had no failures in six weeks, and I wrote the '
                'runbook. Next time I would bring the downstream report owners in earlier.'),
    'rambling': ('So um, I guess one time there was this conflict on my team, it was a group project, and basically there were '
                 'like five of us and two people did not really agree about the design, and I kind of stepped in, well not '
                 'really stepped in but I talked to both of them, and we had meetings, a lot of meetings, and eventually it '
                 'sort of worked out I think, the professor liked it, we got a decent grade, and I learned that communication '
                 'is important and that you should talk to people, and also that deadlines matter. ') * 2,
}
QUESTION = 'project'


def timed_runs(original):
    """Record how long each CLI subprocess takes, by command."""
    spans = []

    def run(command, *args, **kwargs):
        start = time.monotonic()
        try:
            return original(command, *args, **kwargs)
        finally:
            kind = 'auth' if ('status' in command[1:3]) else 'model'
            spans.append((kind, time.monotonic() - start))
    return run, spans


def one(configuration, answer):
    context = {'problem': prep.problem(QUESTION), 'session': {'answer': answer, 'mode': 'behavioral'}}
    run, spans = timed_runs(local_cli.run)
    events = {}

    def observe(event, data):
        events.setdefault(event, time.monotonic())
    start = time.monotonic()
    with patch.object(local_cli, 'run', side_effect=run):
        try:
            result = provider.generate('coach', context, configuration, observe=observe)
            error = ''
        except ValueError as exc:
            result, error = {'artifact': {}}, str(exc)
    total = time.monotonic() - start
    artifact = result['artifact']
    model = events.get('model_response', start + total) - events.get('model_request', start)
    return {
        'total_s': round(total, 2),
        'auth_s': round(sum(s for (k, s) in spans if k == 'auth'), 2),
        'model_s': round(sum(s for (k, s) in spans if k == 'model') or model, 2),
        'format': artifact.get('format', 'text' if artifact.get('text') else ''),
        'words': len(str(artifact.get('text', '')).split()),
        'scores': len(artifact.get('scores', [])),
        'error': error,
        'text': str(artifact.get('text', '')),
    }


def workflow(provider_name, model, answers, repeat, coach_model=''):
    """Time each server phase of one coaching request, end to end, in a disposable database."""
    os.environ['JAC_DB_SCRATCH'] = '1'
    from jaclang.testing.testing import JacTestClient
    from agents.worker import dispatch
    rows = []
    with tempfile.TemporaryDirectory(prefix='stack-coach-bench-') as directory:
        path = Path(directory) / 'config.json'
        path.write_text(json.dumps({'provider': provider_name, 'model': model, **({'coach_models': {provider_name: coach_model}} if coach_model else {})}))
        with patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(path), 'STACK_AGENT_WORKER_TOKEN': 'coach-bench-worker'}):
            client = JacTestClient.from_file(str(Path('main.jac').resolve()), base_path=directory)

            def rpc(name, values=None):
                response = client.post('/function/' + name, json=values or {})
                assert response.ok, response.text
                data = response.data['result'];assert 'error' not in data, data;return data
            try:
                created = client.register_user('coach-bench-owner', 'Synthetic-coach-bench-password-123');assert created.ok
                token = created.data['token']
                for name in answers:
                    for index in range(repeat):
                        client.set_auth_token(token);marks = [time.monotonic()]
                        session = rpc('prep_create', {'problem_id': QUESTION});data = session['data'];data['answer'] = ANSWERS[name]
                        session = rpc('prep_save', {'id': session['id'], 'revision': session['revision'], 'data': data})
                        run = rpc('agent_start', {'kind': 'prep', 'target_id': session['id']});marks.append(time.monotonic())
                        client.clear_auth();work = rpc('agent_claim', {'token': 'coach-bench-worker'});marks.append(time.monotonic())
                        assert work['id'] == run['id'], work
                        with patch('agents.worker.call', side_effect=rpc):
                            result = dispatch(work, 'coach-bench-worker')
                        marks.append(time.monotonic())
                        rpc('agent_finish', {'token': 'coach-bench-worker', **{k: work[k] for k in ('id', 'owner', 'lease')}, 'result': result})
                        marks.append(time.monotonic())
                        client.set_auth_token(token);saved = rpc('prep_get', {'id': session['id']});marks.append(time.monotonic())
                        spans = [round((b - a) * 1000) for (a, b) in zip(marks, marks[1:])]
                        row = {'provider': provider_name, 'model': coach_model or model or 'default', 'answer': name, 'run': index + 1,
                               'save_ms': spans[0], 'claim_ms': spans[1], 'coach_ms': spans[2], 'finish_ms': spans[3], 'read_ms': spans[4],
                               'total_s': round((marks[-1] - marks[0]), 2), 'stored': bool(saved['feedback']),
                               'format': saved['feedback'][-1]['data'].get('format', 'text') if saved['feedback'] else ''}
                        rows.append(row);print(json.dumps(row), flush=True)
            finally:
                client.close()
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('provider', choices=sorted(contracts.CLI_PROVIDERS | contracts.LOCAL_PROVIDERS | {'openai', 'meta'}))
    parser.add_argument('--model', default='')
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--answers', default=','.join(ANSWERS))
    parser.add_argument('--json', action='store_true', help='print one JSON object per run')
    parser.add_argument('--show', action='store_true', help='print each coaching reply')
    parser.add_argument('--workflow', action='store_true', help='time the full server path instead of the model call alone')
    parser.add_argument('--coach-model', default='', help='with --workflow, set coach_models for this provider')
    args = parser.parse_args()
    if args.workflow:
        workflow(args.provider, args.model, args.answers.split(','), args.repeat, args.coach_model)
        return
    configuration = {**contracts.config(), 'provider': args.provider, 'model': args.model}
    rows = []
    for name in args.answers.split(','):
        for index in range(args.repeat):
            row = {'provider': args.provider, 'model': args.model or 'default', 'answer': name, 'run': index + 1,
                   **one(configuration, ANSWERS[name])}
            rows.append(row)
            text = row.pop('text')
            print(json.dumps(row) if args.json else
                  f"{name:9} #{index + 1}  total {row['total_s']:6.2f}s  auth {row['auth_s']:5.2f}s  model {row['model_s']:6.2f}s  "
                  f"{row['format'] or '-':10} {row['words']:4} words  {row['scores']} scores  {row['error']}", flush=True)
            if args.show: print(text + '\n', flush=True)
    good = [r['total_s'] for r in rows if not r['error']]
    if good:
        print(f"\n{len(good)}/{len(rows)} ok  median {statistics.median(good):.2f}s  max {max(good):.2f}s")


if __name__ == '__main__':
    main()
