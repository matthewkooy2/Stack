"""The daily sweep: collects every swept source once over the existing Jac API, then stores each account's matches.

Collection runs here; all catalog and account writes stay in Jac behind the worker token."""
import json
import os
from concurrent.futures import ThreadPoolExecutor
from typing import Any
from urllib.request import Request, urlopen
from discovery.sources import collect

PARALLEL = 4
MAX_PAGES = 400
CHUNK = 100


def call(name: str, args: dict[str, Any]) -> dict[str, Any]:
    request = Request(os.environ.get('STACK_WORKER_API', 'http://127.0.0.1:8000')+
                      '/function/'+name, data=json.dumps(args).encode(),
                      headers={'Content-Type': 'application/json'})
    with urlopen(request, timeout=120) as response:
        result = json.load(response)['data']['result']
    if result.get('error'):
        raise ValueError(result['error'])
    return result


def source(token: str, run: str, config: dict[str, Any], checkpoint: dict[str, Any]) -> list[dict[str, Any]]:
    """Collects one source to completion. Returns the job boards its pages pointed to."""
    added = []
    for _ in range(MAX_PAGES):
        try:
            page = collect(config, checkpoint)
        except Exception as exc:
            error = str(exc) if isinstance(exc, ValueError) else 'Source could not be collected ('+type(exc).__name__+').'
            call('jobs_sweep_source', {'token': token, 'run': run, 'id': config['id'], 'error': error})
            return added
        jobs = page['jobs']
        for start in range(0, max(len(jobs), 1), CHUNK):
            last = start+CHUNK >= len(jobs)
            result = call('jobs_sweep_source', {
                'token': token, 'run': run, 'id': config['id'], 'jobs': jobs[start:start+CHUNK],
                'candidates': page['candidates'] if last else [], 'invalid': page['invalid'] if last else 0,
                'complete': page['complete'] and last, 'checkpoint': page['checkpoint'] if last else {}})
            added += result['added']
        if page['complete']:
            return added
        checkpoint = page['checkpoint']
    call('jobs_sweep_source', {'token': token, 'run': run, 'id': config['id'], 'error': 'Source exceeded the page limit.'})
    return added


def guarded(token: str, run: str, s: dict[str, Any], log) -> list[dict[str, Any]]:
    # One source failing to reach the API must not stop the others or the matching step.
    try:
        return source(token, run, s['config'], s['checkpoint'])
    except Exception as exc:
        log(s['config']['id']+': not recorded ('+type(exc).__name__+').')
        return []


def sweep(token: str, log=print) -> dict[str, Any]:
    begun = call('jobs_sweep_begin', {'token': token})
    run = begun['run']
    lists = [s for s in begun['sources'] if s['config']['adapter'] in ('github', 'github_search')]
    boards = [s for s in begun['sources'] if s not in lists]
    # Lists first: the boards they point to join this run.
    for s in lists:
        boards += [{'config': c, 'checkpoint': {}} for c in guarded(token, run, s, log)]
    with ThreadPoolExecutor(PARALLEL) as pool:
        list(pool.map(lambda s: guarded(token, run, s, log), boards))
    log(f'{len(lists)+len(boards)} sources collected; storing matches.')
    while True:
        result = call('jobs_sweep_finish', {'token': token, 'run': run})
        if result['done']:
            log(f"{result['prepared']} accounts matched.")
            return result
