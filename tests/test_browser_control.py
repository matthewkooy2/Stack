"""Control races and stream grants, with no browser/site/provider calls."""
import unittest
from agents.browser_control import BrowserControl, BrowserInterrupted


class BrowserControlTests(unittest.TestCase):
    def setUp(self):
        self.control = BrowserControl()
        self.key = ('account-a', 'run')
        self.client = 'viewer-synthetic-client'

    def test_takeover_acknowledges_only_after_agent_has_stopped(self):
        generation, mode = self.control.begin(self.key)
        value = self.control.transition(self.key, 'take', generation, self.client)
        self.assertEqual(value['mode'], 'pausing')
        with self.assertRaises(BrowserInterrupted): self.control.check(self.key, generation, mode)
        with self.assertRaises(ValueError): self.control.begin(self.key, dict(instance=self.control.instance, generation=1, controller=self.client, sequence=1))
        self.assertEqual(self.control.end(self.key)['mode'], 'user')
        with self.assertRaises(BrowserInterrupted): self.control.begin(self.key)

    def test_only_current_controller_and_ordered_commands_can_write(self):
        state = self.control.transition(self.key, 'take', 0, self.client)
        event = dict(instance=self.control.instance, generation=state['generation'], controller=self.client, sequence=1)
        self.control.begin(self.key, event);self.control.end(self.key)
        for stale in (event, {**event, 'sequence':3}, {**event, 'generation':0, 'sequence':2}, {**event, 'controller':'different-viewer', 'sequence':2}):
            with self.subTest(stale=stale), self.assertRaises(ValueError): self.control.begin(self.key, stale)
        resumed = self.control.transition(self.key, 'resume', 1, self.client)
        self.assertTrue(resumed['changed'])
        self.assertEqual(resumed['generation'], 2)
        with self.assertRaises(BrowserInterrupted): self.control.begin(self.key, {**event, 'sequence':2})
        self.control.begin(self.key);self.control.end(self.key)

    def test_second_viewer_fences_first_and_cannot_resume_during_input(self):
        self.control.transition(self.key, 'take', 0, self.client)
        self.control.begin(self.key, dict(instance=self.control.instance, generation=1, controller=self.client, sequence=1))
        with self.assertRaises(ValueError): self.control.transition(self.key, 'resume', 1, self.client)
        other = 'viewer-second-synthetic'
        self.assertEqual(self.control.transition(self.key, 'take', 1, other)['mode'], 'pausing')
        self.control.end(self.key)
        with self.assertRaises(ValueError): self.control.begin(self.key, dict(instance=self.control.instance, generation=2, controller=self.client, sequence=1))

    def test_stop_is_out_of_band_and_tombstones_old_commands(self):
        generation, mode = self.control.begin(self.key)
        self.assertEqual(self.control.transition(self.key, 'stop', -1)['mode'], 'stopping')
        with self.assertRaises(BrowserInterrupted): self.control.check(self.key, generation, mode)
        self.assertEqual(self.control.end(self.key)['mode'], 'stopped')
        with self.assertRaises(BrowserInterrupted): self.control.begin(self.key)
        with self.assertRaises(ValueError): self.control.transition(self.key, 'take', 1, self.client)

    def test_accounts_and_stream_grants_are_isolated_and_single_use(self):
        self.control.transition(self.key, 'take', 0, self.client)
        self.assertEqual(self.control.state(('account-b', 'run'))['mode'], 'agent')
        ticket = self.control.grant(self.key)
        self.assertEqual(self.control.consume(ticket), self.key)
        with self.assertRaises(ValueError): self.control.consume(ticket)
        self.control.watch(self.key, 1);self.control.watch(self.key, 1)
        with self.assertRaises(ValueError): self.control.watch(self.key, 1)
        self.control.watch(self.key, -1);self.control.watch(self.key, -1)
        self.assertFalse(self.control.watching(self.key))
        self.assertEqual(self.control.state(self.key)['mode'], 'user')

    def test_account_revocation_fences_active_operations_and_pending_grants(self):
        generation, mode = self.control.begin(self.key)
        pending = self.control.grant(self.key)
        other = ('account-b', 'run')
        allowed = self.control.grant(other)
        self.control.revoke_owner(self.key[0])
        self.assertTrue(self.control.state(self.key)['revoked'])
        with self.assertRaises(BrowserInterrupted): self.control.check(self.key, generation, mode)
        with self.assertRaises(ValueError): self.control.consume(pending)
        with self.assertRaises(ValueError): self.control.grant(self.key)
        self.assertEqual(self.control.consume(allowed), other)
        late = (self.key[0], 'previously-queued-run')
        with self.assertRaises(BrowserInterrupted): self.control.begin(late, agent_generation=0)
        with self.assertRaises(ValueError): self.control.grant(late)
        self.control.end(self.key)
        with self.assertRaises(ValueError): self.control.transition(self.key, 'take', 1, self.client)

if __name__ == '__main__': unittest.main()
