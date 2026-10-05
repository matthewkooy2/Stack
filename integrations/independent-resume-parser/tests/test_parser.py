import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from dataclasses import replace

from fixtures import pdf, SINGLE, TWO_COLUMN
from resume_parser import Limits, ParseError, parse_pdf, sandbox
from resume_parser.structure import structure

NODE = os.environ.get('STACK_PARSER_TEST_NODE', 'node')


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'fictional.pdf'

    def parse(self, rows=SINGLE, **kwargs):
        self.path.write_bytes(pdf([rows]))
        return parse_pdf(self.path, node=NODE, **kwargs)

    def assert_coverage(self, result):
        source = [s['id'] for p in result['source']['pages'] for s in p['spans'] if s['text']]
        assigned = [s for blocks in result['sections'].values() for b in blocks for s in b['sourceSpanIds']]
        self.assertCountEqual(source, assigned)
        self.assertEqual(len(assigned), len(set(assigned)))

    def test_sections_contacts_provenance_and_no_loss(self):
        result = self.parse()
        self.assertEqual(result['contact']['email'][0]['value'], 'avery@example.invalid')
        self.assertEqual(result['contact']['phone'][0]['value'], '+1 202-555-0142')
        self.assertEqual(result['contact']['url'][0]['value'], 'https://example.invalid/avery')
        for kind, expected in [('education', 'Fictional University'), ('employment', 'Sample Labs'),
                               ('projects', 'Orbit Notes'), ('skills', 'Python'), ('unclassified', 'ceramics')]:
            self.assertIn(expected, '\n'.join(b['text'] for b in result['sections'][kind]))
        self.assertTrue(result['review']['required'])
        self.assert_coverage(result)

    def test_two_columns_are_independent(self):
        result = self.parse(TWO_COLUMN)
        skills = '\n'.join(b['text'] for b in result['sections']['skills'])
        jobs = '\n'.join(b['text'] for b in result['sections']['employment'])
        self.assertIn('TypeScript', skills)
        self.assertNotIn('Sample Labs', skills)
        self.assertIn('Sample Labs', jobs)
        self.assertNotIn('College', jobs)
        self.assertIn('COLUMN_ORDER_INFERRED', [w['code'] for w in result['warnings']])
        self.assert_coverage(result)

    def test_missing_headings_conservative(self):
        result = self.parse([(45, 45, 'Avery Example'), (45, 70, 'Fictional University BSc 2022'),
                             (45, 100, 'Software Engineer | Sample Labs | 2022 - 2024'),
                             (45, 130, 'Project: Orbit Notes'), (45, 160, 'Tools: Python, SQL'),
                             (45, 190, 'An ambiguous sentence remains untouched.')])
        for key in ('education', 'employment', 'projects', 'skills'):
            self.assertTrue(result['sections'][key])
            self.assertLess(result['sections'][key][0]['confidence'], .7)
        self.assertIn('ambiguous', result['sections']['unclassified'][-1]['text'])
        self.assert_coverage(result)

    def test_exact_unicode_and_whitespace_spans_survive(self):
        raw = {'pages': [{'number': 1, 'width': 612, 'height': 792, 'spans': [
            {'id': 's1', 'text': 'Zoë  示例 — résumé', 'bbox': [40, 40, 180, 12], 'direction': 'ltr', 'endOfLine': True},
            {'id': 's2', 'text': '  unusual\ttext  ', 'bbox': [40, 70, 90, 12], 'direction': 'ltr', 'endOfLine': True}]}]}
        result = structure(raw)
        self.assertEqual(result['source'], raw)
        self.assert_coverage(result)

    def test_empty_pdf_requires_ocr(self):
        self.assertEqual(self.parse([])['warnings'][0]['code'], 'NO_EXTRACTABLE_TEXT')

    def test_malformed(self):
        for data in (b'not pdf', b'%PDF-1.7\ninvalid', b'%PDF-1.7\n' + b'[' * 100000):
            self.path.write_bytes(data)
            with self.assertRaises(ParseError) as error:
                parse_pdf(self.path, node=NODE)
            self.assertEqual(error.exception.code, 'INVALID_PDF')

    def test_input_limit_before_extraction(self):
        self.path.write_bytes(b'%PDF-' + b'0' * 1000)
        with self.assertRaises(ParseError) as error:
            parse_pdf(self.path, node=NODE, limits=replace(Limits(), input_bytes=100))
        self.assertEqual(error.exception.code, 'INPUT_LIMIT')

    def test_page_limit(self):
        self.path.write_bytes(pdf([SINGLE] * 3))
        with self.assertRaises(ParseError) as error:
            parse_pdf(self.path, node=NODE, limits=replace(Limits(), pages=2))
        self.assertEqual(error.exception.code, 'PAGE_LIMIT')

    def test_compressed_text_limit(self):
        self.path.write_bytes(pdf([[(45, 45+i, 'x' * 100) for i in range(300)]], compressed=True))
        with self.assertRaises(ParseError) as error:
            parse_pdf(self.path, node=NODE, limits=replace(Limits(), characters=500))
        self.assertEqual(error.exception.code, 'TEXT_LIMIT')

    def test_span_and_output_limits(self):
        for limits, expected in [(replace(Limits(), spans=2), 'SPAN_LIMIT'),
                                 (replace(Limits(), output_bytes=100), 'OUTPUT_LIMIT')]:
            with self.assertRaises(ParseError) as error:
                self.parse(limits=limits)
            self.assertEqual(error.exception.code, expected)

    def test_timeout(self):
        start = time.monotonic()
        with self.assertRaises(ParseError) as error:
            self.parse(limits=replace(Limits(), timeout_seconds=.001))
        self.assertEqual(error.exception.code, 'TIMEOUT')
        self.assertLess(time.monotonic() - start, 5)

    def test_os_memory_limit_terminates_native_allocations(self):
        # Allocate external buffers: a JS heap cap alone cannot contain this.
        script = Path(self.temp.name) / 'allocate.cjs'
        script.write_text("process.stdin.once('data',()=>{process.stderr.write('ALLOCATING\\n');let a=[];while(true)a.push(Buffer.alloc(16*1024*1024,1));});")
        limits = replace(Limits(), memory_bytes=384*1024*1024, timeout_seconds=10)
        code, diagnostic = sandbox.run([NODE, '--jitless', '--max-old-space-size=64', str(script)],
                              b'go\n', self.temp.name, limits)
        self.assertIn('ALLOCATING', diagnostic)
        self.assertNotEqual(code, 0)

    def test_worker_diagnostics_are_bounded(self):
        script = Path(self.temp.name) / 'noisy.cjs'
        script.write_text("process.stdin.once('data',()=>{while(true)process.stderr.write('x'.repeat(1024));});")
        code, diagnostic = sandbox.run([NODE, str(script)], b'go\n', self.temp.name, Limits())
        self.assertNotEqual(code, 0)
        self.assertLessEqual(len(diagnostic), 4096)

    def test_long_unmatched_line_does_not_stall_regex(self):
        raw = {'pages': [{'number': 1, 'width': 612, 'height': 792, 'spans': [
            {'id': 's', 'text': 'x' * 250000, 'bbox': [40, 40, 500, 12]}]}]}
        start = time.monotonic()
        self.assert_coverage(structure(raw))
        self.assertLess(time.monotonic() - start, 3)

    def test_multi_page_and_right_margin_dates(self):
        rows = [(45, 45, 'Experience'), (45, 75, 'Sample Labs - Engineer'),
                (480, 75, '2022 - 2024'), (45, 95, 'Built a tool'),
                (45, 130, 'Example Labs - Analyst'), (480, 130, '2020 - 2022'),
                (45, 150, 'Analyzed test data'), (45, 190, 'Demo Labs - Intern'),
                (480, 190, '2019 - 2020')]
        self.path.write_bytes(pdf([rows, [(45, 45, 'Ambiguous continuation preserved')]]))
        result = parse_pdf(self.path, node=NODE)
        self.assertEqual(len(result['source']['pages']), 2)
        self.assertFalse(any(w['code'] == 'COLUMN_ORDER_INFERRED' for w in result['warnings']))
        self.assertIn('continuation', result['sections']['unclassified'][0]['text'])
        self.assert_coverage(result)

    def test_temporary_files_removed_after_success_and_failure(self):
        from unittest.mock import patch
        root = Path(self.temp.name) / 'private'
        root.mkdir()
        real = tempfile.TemporaryDirectory
        def located(*args, **kwargs):
            return real(*args, dir=root, **kwargs)
        with patch('resume_parser.tempfile.TemporaryDirectory', side_effect=located):
            self.parse()
            self.assertEqual(list(root.iterdir()), [])
            with self.assertRaises(ParseError):
                self.parse(limits=replace(Limits(), timeout_seconds=.001))
            self.assertEqual(list(root.iterdir()), [])

    @unittest.skipUnless(os.name == 'posix', 'POSIX FIFO input')
    def test_fifo_rejected_without_blocking(self):
        os.mkfifo(self.path)
        with self.assertRaises(ParseError) as error:
            parse_pdf(self.path, node=NODE)
        self.assertEqual(error.exception.code, 'NOT_REGULAR_FILE')

    def test_limits_validate(self):
        for value in (0, -1, float('nan'), float('inf'), True):
            with self.assertRaises(ValueError):
                Limits(timeout_seconds=value)

    def test_deterministic_and_editable(self):
        first, second = self.parse(), self.parse()
        self.assertEqual(first, second)
        copy = json.loads(json.dumps(first))
        copy['contact']['name'][0]['value'] = 'User correction'
        self.assertEqual(copy['source'], first['source'])


if __name__ == '__main__':
    unittest.main()
