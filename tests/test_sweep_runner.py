"""The daily sweep runner, offline: order, boards found by lists, isolated failures and the matching step."""
import sys
from pathlib import Path
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from discovery import sweep as runner

LIST = {'id': 'github:list', 'adapter': 'github'}
BOARD = {'id': 'greenhouse:a', 'adapter': 'greenhouse'}
FOUND = {'id': 'lever:found', 'adapter': 'lever'}
BROKEN = {'id': 'ashby:broken', 'adapter': 'ashby'}


class Runner(unittest.TestCase):
    def run_sweep(self, pages):
        calls = []

        def call(name, args):
            calls.append((name, args))
            if name == 'jobs_sweep_begin':
                return {'run': 'r', 'sources': [{'config': BOARD, 'checkpoint': {}}, {'config': BROKEN, 'checkpoint': {}},
                                                {'config': LIST, 'checkpoint': {'etag': 'x'}}]}
            if name == 'jobs_sweep_source':
                return {'saved': True, 'added': [FOUND] if args['id'] == LIST['id'] and args.get('candidates') else []}
            if name == 'jobs_sweep_finish':
                done = sum(1 for n, _ in calls if n == 'jobs_sweep_finish') >= 2
                return {'done': done, 'prepared': 3}
            raise AssertionError(name)

        def collect(config, checkpoint):
            return pages[config['id']](checkpoint)

        with patch.object(runner, 'call', side_effect=call), patch.object(runner, 'collect', side_effect=collect):
            result = runner.sweep('token', log=lambda *_: None)
        return calls, result

    def test_lists_first_found_boards_collected_and_one_failure_isolated(self):
        page = lambda jobs, complete=True, after=None: {'jobs': jobs, 'candidates': [], 'invalid': 0, 'complete': complete, 'checkpoint': after or {}}
        pages = {
            LIST['id']: lambda cp: {**page([]), 'candidates': [FOUND], 'checkpoint': {'etag': 'y'}},
            BOARD['id']: lambda cp: page([{'id': 2}]) if cp else page([{'id': 1}], False, {'offset': 1}),
            FOUND['id']: lambda cp: page([{'id': 3}]),
            BROKEN['id']: lambda cp: (_ for _ in ()).throw(ValueError('Board returned HTTP 500.')),
        }
        calls, result = self.run_sweep(pages)
        sources = [a for n, a in calls if n == 'jobs_sweep_source']
        self.assertEqual(sources[0]['id'], LIST['id'])
        self.assertEqual(sources[0]['checkpoint'], {'etag': 'y'})
        board = [a for a in sources if a['id'] == BOARD['id']]
        self.assertEqual([a['complete'] for a in board], [False, True])
        self.assertTrue(any(a['id'] == FOUND['id'] and a['complete'] for a in sources))
        self.assertEqual([a['error'] for a in sources if a['id'] == BROKEN['id']], ['Board returned HTTP 500.'])
        self.assertEqual(calls[-1][0], 'jobs_sweep_finish')
        self.assertEqual(result['prepared'], 3)

    def test_large_pages_are_sent_in_chunks_and_only_the_last_completes(self):
        jobs = [{'id': i} for i in range(runner.CHUNK * 2 + 1)]
        pages = {k: (lambda cp: {'jobs': [], 'candidates': [], 'invalid': 0, 'complete': True, 'checkpoint': {}}) for k in (LIST['id'], FOUND['id'], BROKEN['id'])}
        pages[BOARD['id']] = lambda cp: {'jobs': jobs, 'candidates': [], 'invalid': 1, 'complete': True, 'checkpoint': {}}
        calls, _ = self.run_sweep(pages)
        board = [a for n, a in calls if n == 'jobs_sweep_source' and a['id'] == BOARD['id']]
        self.assertEqual([len(a['jobs']) for a in board], [runner.CHUNK, runner.CHUNK, 1])
        self.assertEqual([a['complete'] for a in board], [False, False, True])
        self.assertEqual([a['invalid'] for a in board], [0, 0, 1])


if __name__ == '__main__':
    unittest.main(verbosity=2)
