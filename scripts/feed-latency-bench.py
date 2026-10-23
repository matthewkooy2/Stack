"""Manual benchmark for #105/#107: search_jobs latency with a large synthetic catalog.

Seeds N fictional jobs through the real collector endpoints into disposable embedded data, then times
search_jobs in three situations:
  steady   the account's feed already matches its search
  changed  the search changed and the catalog view is older than the old 300 s expiry
           (on main this rebuilds the view and prepares the feed inline)
  upkeep   discovery_maintain doing that work in the background (only where the endpoint exists)

Run from the repository root:
  ./scripts/jac run --no-serve scripts/feed-latency-bench.py [--jobs 10000] [--rounds 8]
Not a CI check. Prints JSON with p50/p95/max in milliseconds.
"""
import argparse
import json
import os
import statistics
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

if os.environ.get('JAC_DB_URL'):
    raise SystemExit('Use disposable embedded data: unset JAC_DB_URL.')
os.environ['JAC_DB_SCRATCH'] = '1'
from jaclang.testing.testing import JacTestClient
from discovery.normalize import normalize, digest

ROOT = Path(__file__).resolve().parents[1]
FILLER = (' Responsibilities include designing services, reviewing code, mentoring peers, partnering with product and '
          'design, and improving observability. Qualifications: 2+ years of experience with Python or Go, SQL and cloud '
          'platforms; strong communication. Benefits include health coverage, retirement matching and a learning budget.') * 14
TITLES = ['Software Engineer', 'Data Analyst', 'Registered Nurse', 'Financial Analyst', 'Product Designer',
          'Marketing Coordinator', 'Mechanical Engineer', 'Account Executive', 'Junior Software Engineer', 'Operations Associate']
CITIES = ['Detroit, MI', 'Austin, TX', 'New York, NY', 'Remote', 'Chicago, IL', 'Seattle, WA']


def percentiles(samples):
    ordered = sorted(samples)
    pick = lambda q: ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]
    return {'n': len(ordered), 'p50_ms': round(statistics.median(ordered) * 1000, 1),
            'p95_ms': round(pick(0.95) * 1000, 1), 'max_ms': round(ordered[-1] * 1000, 1)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--jobs', type=int, default=10000)
    parser.add_argument('--rounds', type=int, default=8)
    parser.add_argument('--sources', type=int, default=20)
    parser.add_argument('--raw', action='store_true', help='also print every sample in order')
    args = parser.parse_args()
    scratch = ROOT / '.jac/feed-bench'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        client = JacTestClient.from_file(str(ROOT / 'main.jac'), base_path=tmp)
        try:
            token = client.register_user('feed-bench-user', 'Fixture-password-bench-1').data['token']

            def call(name, body=None, auth=True):
                if auth:
                    client.set_auth_token(token)
                else:
                    client.clear_auth()
                response = client.post('/function/' + name, json=body or {})
                return response

            def rpc(name, body=None, auth=True):
                response = call(name, body, auth)
                assert response.ok, response.text
                result = response.data['result']
                assert not (isinstance(result, dict) and result.get('error')), result
                return result

            rpc('bootstrap')
            catalogs = [m for n, m in list(sys.modules.items()) if n.endswith('core.catalog') and hasattr(m, '_worker_allowed')]
            for module in catalogs:
                patch.object(module, '_worker_allowed', return_value=True).start()
            per_source = max(1, args.jobs // args.sources)
            seeded = 0
            started = time.time()
            for s in range(args.sources):
                url = f'https://example.com/feed-bench/{s}'
                source = 'career:' + digest(url)
                rpc('import_job_url', {'url': url})
                claim = rpc('discovery_claim', {'token': 'bench', 'preferred_id': source}, auth=False)
                assert claim.get('id') == source, claim
                rows = []
                for i in range(per_source):
                    n = s * per_source + i
                    rows.append(normalize({'title': TITLES[n % len(TITLES)], 'company': f'Fixture {n % 400}',
                                           'url': f'{url}/{i}', 'country': 'US', 'location': CITIES[n % len(CITIES)],
                                           'employment_type': 'Full-time', 'description': f'Fixture listing {n}.' + FILLER,
                                           'posted_at': time.time() - n * 60}, claim['config']))
                rpc('discovery_complete', {'token': 'bench', 'id': source, 'lease': claim['lease'],
                                           'result': {'jobs': rows, 'complete': True}}, auth=False)
                seeded += len(rows)
            seed_seconds = time.time() - started
            has_upkeep = call('discovery_maintain', {'token': 'bench'}, auth=False).status_code not in (404, 405)

            def upkeep():
                if has_upkeep:
                    began = time.time()
                    rpc('discovery_maintain', {'token': 'bench', 'budget_seconds': 60}, auth=False)
                    return time.time() - began
                return None

            def age_view():
                for module in catalogs:
                    module._catalog_cache['at'] -= 301

            queries = ['Software engineer', 'Data analyst', 'Registered nurse', 'Financial analyst']
            rpc('search_jobs', {'query': queries[0], 'filters': {}})
            upkeep()
            changed, steady, background = [], [], []
            for r in range(args.rounds):
                query = queries[(r + 1) % len(queries)]
                rpc('save_search', {'query': query, 'filters': {}})
                age_view()
                began = time.time()
                first = rpc('search_jobs', {'query': query, 'filters': {}})
                changed.append(time.time() - began)
                spent = upkeep()
                if spent is not None:
                    background.append(spent)
                for _ in range(3):
                    began = time.time()
                    rpc('search_jobs', {'query': query, 'filters': {}})
                    steady.append(time.time() - began)
            print(json.dumps({'jobs_seeded': seeded, 'seed_seconds': round(seed_seconds, 1),
                              'background_upkeep_endpoint': has_upkeep,
                              'search_after_change_and_expired_view': percentiles(changed),
                              'search_steady': percentiles(steady),
                              'background_upkeep': percentiles(background) if background else None,
                              **({'raw_ms': {'changed': [round(x * 1000) for x in changed], 'steady': [round(x * 1000) for x in steady],
                                             'upkeep': [round(x * 1000) for x in background]}} if args.raw else {})}, indent=2))
        finally:
            client.close()


if __name__ == '__main__':
    main()
