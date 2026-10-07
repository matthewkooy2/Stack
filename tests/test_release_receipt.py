import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'deploy'))
from verify_release_receipt import verify


class Receipt(unittest.TestCase):
    def test_healthy_exact_receipt_and_private_field_redaction(self):
        value = dict(commit='a'*40, prior_commit='b'*40, probe_protocol=1, status='healthy', stage='complete',
            source_backup='/private/host/path', token='synthetic-private',
            candidate_checks=dict(commit='a'*40, checks='passed', attempts=2, elapsed_ms=120))
        result, good = verify(json.dumps(value).encode(), 'a'*40, 0)
        self.assertTrue(good)
        self.assertNotIn('synthetic-private', json.dumps(result))
        self.assertNotIn('/private/host/path', json.dumps(result))
        for key in ('commit', 'probe_protocol', 'candidate_checks'):
            invalid = {**value, key: None}
            self.assertFalse(verify(json.dumps(invalid).encode(), 'a'*40, 0)[1])

    def test_recovered_and_transport_failed_jobs_stay_failed(self):
        value = dict(commit='a'*40, prior_commit='b'*40, probe_protocol=1, status='failed', stage='readiness',
                     failing_check='browser_smoke', recovery='healthy')
        result, good = verify(json.dumps(value).encode(), 'a'*40, 1)
        self.assertFalse(good); self.assertEqual(result['failing_check'], 'browser_smoke')
        self.assertFalse(verify(b'not-json', 'a'*40, 255)[1])


if __name__ == '__main__': unittest.main()
