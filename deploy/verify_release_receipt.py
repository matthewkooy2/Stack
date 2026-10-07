"""Reduce untrusted host stdout to a small CI receipt; fail recovered deployments."""
import argparse
import json
from pathlib import Path
import re
import sys

STAGES = {'stop', 'install', 'start', 'readiness', 'commit', 'complete', 'recovery_stop',
          'recovery_restore', 'recovery_start', 'recovery_readiness', 'preflight_or_receipt'}
CHECKS = {'api_smoke', 'worker_round_trip', 'gateway', 'browser_image', 'browser_smoke',
          'readiness', 'readiness_timeout'}


def verify(raw, commit, exit_code):
    result = {'status': 'invalid_receipt', 'commit': commit,
              'action': 'Review the private host transaction before retrying.'}
    try:
        assert len(raw) <= 8192 and re.fullmatch('[0-9a-f]{40}', commit)
        value = json.loads(raw)
        assert isinstance(value, dict)
        assert value['commit'] == commit and value['probe_protocol'] == 1
        assert re.fullmatch('[0-9a-f]{40}', value['prior_commit'])
        assert value['status'] in ('healthy', 'failed', 'held')
        result.update(status=value['status'], prior_commit=value['prior_commit'], probe_protocol=1)
        for key, allowed in (('stage', STAGES), ('failing_stage', STAGES), ('recovery_stage', STAGES),
                             ('failing_check', CHECKS), ('recovery', {'healthy', 'failed', 'not_needed'})):
            if value.get(key) in allowed: result[key] = value[key]
        for key in ('candidate_checks', 'prior_checks'):
            check = value.get(key, {})
            if not isinstance(check, dict):
                continue
            if (check.get('commit') in (commit, value['prior_commit']) and check.get('checks') == 'passed'
                    and type(check.get('attempts')) is int and 1 <= check['attempts'] <= 20
                    and type(check.get('elapsed_ms')) is int and 0 <= check['elapsed_ms'] <= 60000):
                result[key] = {k: check[k] for k in ('commit', 'checks', 'attempts', 'elapsed_ms')}
        good = (exit_code == 0 and result['status'] == 'healthy' and result.get('stage') == 'complete'
                and result.get('candidate_checks', {}).get('commit') == commit)
        return result, good
    except (AssertionError, ValueError, KeyError, TypeError):
        return result, False


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True); parser.add_argument('--output', required=True)
    parser.add_argument('--commit', required=True); parser.add_argument('--exit-code', required=True, type=int)
    args = parser.parse_args()
    receipt, good = verify(Path(args.input).read_bytes(), args.commit, args.exit_code)
    Path(args.output).write_text(json.dumps(receipt, sort_keys=True) + '\n')
    print(json.dumps(receipt, sort_keys=True))
    sys.exit(0 if good else 1)
