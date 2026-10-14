import subprocess
import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'deploy'))
import promote_backend


class DiscoveryLifecycleTests(unittest.TestCase):
    def test_enabled_collector_stops_first_and_starts_last(self):
        with patch.object(promote_backend.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, 'enabled\n')):
            services = promote_backend.deployment_services()
        self.assertEqual(services[0], 'stack-discovery.service')
        self.assertEqual(list(reversed(services))[0], 'stack-api.service')
        self.assertEqual(list(reversed(services))[-1], 'stack-discovery.service')

    def test_disabled_absent_and_static_collectors_stay_off(self):
        for code, state in ((1, ''), (1, 'disabled'), (0, 'static')):
            with patch.object(promote_backend.subprocess, 'run',
                              return_value=subprocess.CompletedProcess([], code, state)):
                self.assertEqual(promote_backend.deployment_services(), promote_backend.SERVICES)


if __name__ == '__main__':
    unittest.main()
