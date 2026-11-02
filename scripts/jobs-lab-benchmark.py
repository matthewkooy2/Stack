#!/usr/bin/env python3
"""Measure genuinely new accounts against the running isolated jobs browser lab."""
import argparse
import json
import statistics
import time
from urllib.request import Request, urlopen
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:18280')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--role', default='Software engineer')
    parser.add_argument('--output')
    args = parser.parse_args()
    if urlsplit(args.url).hostname not in ('127.0.0.1', 'localhost'):
        parser.error('This benchmark is for a loopback lab only.')
    with urlopen(args.url + '/lab-info') as response:
        catalog = json.load(response)
    if catalog.get('kind') != 'synthetic':
        parser.error('Target did not identify itself as a synthetic jobs lab.')
    runs = []
    for i in range(args.rounds):
        token = ''
        def call(path, body):
            began = time.perf_counter()
            request = Request(args.url + path, data=json.dumps(body).encode(), headers={
                'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + token} if token else {})})
            with urlopen(request, timeout=180) as response:
                payload = json.load(response)
            elapsed = (time.perf_counter() - began) * 1000
            if not payload.get('ok', True):
                raise RuntimeError(payload)
            result = payload['data'].get('result', payload['data'])
            if 'error' in result:
                raise RuntimeError(result['error'])
            return result, elapsed
        user = f'benchmark-{time.time_ns()}-{i}'
        identity = {'type': 'username', 'value': user}
        registered, signup_ms = call('/user/register', {'identities': [identity], 'credential': {
            'type': 'password', 'password': 'Fictional-lab-password-123'}})
        token = registered['token']
        call('/function/bootstrap', {})
        _, profile_ms = call('/function/save_profile', {'name': 'Synthetic benchmark', 'role': args.role,
            'location': '', 'mode': 'Any', 'notifications': False})
        saved, feed_ms = call('/function/save_search', {'query': args.role, 'filters': {}})
        first = saved['feed']
        assert first['jobs'], 'Expected synthetic role coverage'
        assert len(first['jobs']) == min(25, first['total'])
        reload, reload_ms = call('/function/job_feed', {})
        assert [j['id'] for j in first['jobs']] == [j['id'] for j in reload['jobs']]
        paging_ms = None
        if first['next_cursor']:
            page, paging_ms = call('/function/job_feed', {'cursor': first['next_cursor']})
            assert not {j['id'] for j in first['jobs']} & {j['id'] for j in page['jobs']}
        run = dict(signup_ms=round(signup_ms, 1), profile_ms=round(profile_ms, 1),
                   first_feed_ms=round(feed_ms, 1), onboarding_api_ms=round(profile_ms + feed_ms, 1),
                   reload_ms=round(reload_ms, 1), next_page_ms=round(paging_ms, 1) if paging_ms else None,
                   matches=first['total'], cards=len(first['jobs']))
        runs.append(run)
        print(json.dumps(run), flush=True)
    values = [r['first_feed_ms'] for r in runs]
    report = dict(catalog=catalog, role=args.role, runs=runs, first_feed_median_ms=statistics.median(values),
                  first_feed_max_ms=max(values), note='HTTP API timings on this Mac; visible browser rendering measured separately. First run includes a cold account, not necessarily a cold server.')
    if args.output:
        from pathlib import Path
        Path(args.output).write_text(json.dumps(report, indent=2))
    print(json.dumps({k: report[k] for k in ('first_feed_median_ms', 'first_feed_max_ms')}))

if __name__ == '__main__':
    main()
