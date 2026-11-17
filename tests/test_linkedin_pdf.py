"""LinkedIn PDF review: export parsing, local-model fitting, quote checks and the owner-scoped endpoint.

Every profile here is synthetic. The layout fixture copies the geometry of LinkedIn's "Save to PDF"
export (Apache FOP): a sidebar at x=22, a main column at x=224, 26pt name, 15.8pt main headings,
13pt sidebar headings and "Page n of m" footer fragments.
"""
import base64
import copy
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ['JAC_DB_SCRATCH'] = '1'
from agents import linkedin, linkedin_pdf, provider

ROLE = 'Data analyst'


def page(spans):
    return {'width': 612.0, 'height': 792.0, 'spans': [list(s) for s in spans]}


def footer(n, total):
    return [(384, 778, 20, 9.0, 'Page'), (407, 778, 5, 9.0, str(n)), (412, 778, 10, 9.0, 'of'), (425, 778, 5, 9.0, str(total))]


LAYOUT = [
    page([
        (22, 54, 50, 13.0, 'Contact'),
        (224, 66, 180, 26.0, 'Alex Example'),
        (22, 74, 60, 10.5, '5550100000'), (80, 74, 40, 10.5, '(Mobile)'),
        (22, 86, 120, 10.5, 'alex@example.test'),
        (224, 87, 300, 12.0, 'Data Analyst @ Example Corp | Student at Example'),
        (224, 102, 160, 12.0, 'Ann Arbor, Michigan'),
        (22, 111, 150, 11.0, 'www.linkedin.com/in/alex-'), (22, 125, 50, 11.0, 'example'), (71, 125, 50, 11.0, '(LinkedIn)'),
        (224, 140, 80, 15.8, 'Summary'),
        (22, 160, 60, 13.0, 'Top Skills'),
        (224, 170, 330, 10.5, 'I turn messy operational data into dashboards that teams actually'),
        (22, 180, 60, 10.5, 'SQL'),
        (224, 188, 200, 10.5, 'use, with a focus on clear definitions.'),
        (22, 198, 60, 10.5, 'Python (Programming Language)'),
        (224, 230, 80, 15.8, 'Experience'),
        (224, 259, 120, 12.0, 'Example Corp'),
        (224, 276, 160, 11.5, 'Data Analyst Intern'),
        (224, 290, 120, 10.5, 'May 2025 - August 2025'), (327, 290, 40, 10.5, '(4 months)'),
        (224, 305, 160, 10.5, 'Detroit, Michigan, United States'),
        (224, 326, 330, 10.5, '• Built a weekly revenue dashboard in Tableau used by twelve full-'),
        (224, 344, 200, 10.5, 'stack teams across the company'),
        (224, 362, 330, 10.5, '• Automated the CI/CD data checks for the finance pipeline, cutting'),
        (224, 380, 200, 10.5, 'manual review time'),
    ] + footer(1, 2)),
    page([
        (224, 60, 120, 12.0, 'Campus Lab'),
        (224, 76, 160, 11.5, 'Research Assistant'),
        (224, 91, 120, 10.5, 'June 2024 - Present'), (344, 91, 40, 10.5, '(1 year 6 months)'),
        (224, 106, 150, 10.5, 'Helped with research projects.'),
        (224, 361, 80, 15.8, 'Education'),
        (224, 387, 160, 12.0, 'University of Example'),
        (224, 404, 280, 10.5, 'Bachelor of Science - BS, Data Science'), (507, 404, 30, 10.5, '· (2023 - 2027)'),
    ] + footer(2, 2)),
]


def review(**changes):
    data = {
        'summary': 'A clear analyst profile that undersells its results.',
        'strengths': ['Concrete tools and a dashboard project.'],
        'findings': [
            {'section': 'experience', 'priority': 'medium', 'quote': 'Helped with research projects.',
             'weakness': 'The research role is vague.', 'why_it_matters': 'Recruiters skim for outcomes.',
             'recommendation': 'Name one project and what it produced.'},
            {'section': 'headline', 'priority': 'high', 'quote': 'Data Analyst @ Example Corp',
             'weakness': 'The headline leads with an internship title.', 'why_it_matters': 'It is the first line recruiters read.',
             'recommendation': 'Lead with the analysis you do and the tools you use.'},
        ],
        'rewrites': [{'section': 'headline', 'text': 'Data analyst | SQL, Python, Tableau dashboards', 'reason': 'Leads with skills.'}],
        'questions': ['How many people used the revenue dashboard each week?'],
    }
    data.update(changes)
    return data


class Parser(unittest.TestCase):
    def setUp(self):
        self.parsed = linkedin_pdf.sections_from_layout(copy.deepcopy(LAYOUT))
        self.sections = self.parsed['sections']

    def test_columns_sections_and_profile_address(self):
        self.assertEqual(self.parsed['name'], 'Alex Example')
        self.assertEqual(self.sections['headline'], 'Data Analyst @ Example Corp | Student at Example')
        self.assertEqual(self.sections['intro'].splitlines()[-1], 'Ann Arbor, Michigan')
        self.assertEqual(self.sections['skills'], 'SQL\nPython (Programming Language)')
        self.assertEqual(self.parsed['url'], 'https://www.linkedin.com/in/alex-example/')
        self.assertIn('University of Example', self.sections['education'])
        # The sidebar never leaks into main-column sections.
        self.assertNotIn('SQL', self.sections['about'])

    def test_contact_details_and_footers_are_discarded(self):
        text = json.dumps(self.sections)
        for private in ('alex@example.test', '5550100000', '(Mobile)', 'Page', '(LinkedIn)'):
            self.assertNotIn(private, text)

    def test_wrapped_lines_join_and_entry_lines_stay_separate(self):
        self.assertEqual(self.sections['about'], 'I turn messy operational data into dashboards that teams actually use, with a focus on clear definitions.')
        lines = self.sections['experience'].splitlines()
        self.assertIn('• Built a weekly revenue dashboard in Tableau used by twelve full-stack teams across the company', lines)
        self.assertIn('• Automated the CI/CD data checks for the finance pipeline, cutting manual review time', lines)
        # Dates, locations and titles keep their own lines; pages do not merge.
        self.assertIn('May 2025 - August 2025 (4 months)', lines)
        self.assertIn('Detroit, Michigan, United States', lines)
        self.assertIn('Campus Lab', lines)

    def test_other_documents_are_refused(self):
        resume = [page([(72, 72, 200, 18.0, 'Pat Resume'), (72, 100, 300, 10.0, 'Experience at a company')])]
        for layout in ([], [page([])], resume, [page([(72, 72, 200, 12.0, 'Small title only')])]):
            with self.assertRaisesRegex(ValueError, 'Save to PDF'):
                linkedin_pdf.sections_from_layout(copy.deepcopy(layout))

    def test_capture_bounds_and_unknown_sections(self):
        capture = linkedin_pdf.capture(self.parsed, '/private/path/Profile.pdf')
        self.assertEqual(capture['file'], 'Profile.pdf')
        self.assertEqual(capture['source'], 'pdf')
        self.assertIn('featured', capture['unread_sections'])
        self.assertNotIn('experience', capture['unread_sections'])
        long = {**self.parsed, 'sections': {**self.sections, 'experience': ('x' * 70 + '\n') * 200}}
        bounded = linkedin_pdf.capture(long)
        self.assertLessEqual(len(bounded['sections']['experience']), linkedin_pdf.SECTION_LIMIT)
        self.assertLessEqual(sum(map(len, bounded['sections'].values())), linkedin_pdf.TOTAL_LIMIT)
        self.assertIn('experience', bounded['limitations'])

    def test_upload_input_checks_happen_before_pdf_processing(self):
        with patch('agents.pdf_safety.inspect_spans') as inspect:
            for name, content in (('Profile.docx', 'JVBERi0='), ('', 'JVBERi0='), ('Profile.pdf', 'not base64!'),
                                  ('Profile.pdf', base64.b64encode(b'plain text').decode())):
                with self.assertRaises(ValueError):
                    linkedin_pdf.parse_encoded(name, content)
            inspect.assert_not_called()

    @unittest.skipUnless(sys.platform == 'linux' or os.name == 'nt', 'pdf_safety refuses to run without Linux or Windows resource limits')
    def test_real_pdf_through_the_bounded_worker(self):
        from reportlab.pdfgen import canvas
        buffer = io.BytesIO()
        pdf = canvas.Canvas(buffer, pagesize=(612, 792))
        # The standard Helvetica encoding has no "•", so draw the equivalent "- " bullet.
        ascii_bullets = lambda text: text.replace('• ', '- ')
        for spec in LAYOUT:
            for x, y, w, h, text in spec['spans']:
                pdf.setFont('Helvetica', h)
                pdf.drawString(x, 792 - y, ascii_bullets(text))
            pdf.showPage()
        pdf.save()
        capture = linkedin_pdf.parse(buffer.getvalue(), 'Profile.pdf')
        self.assertEqual(capture['sections']['headline'], self.sections['headline'])
        self.assertEqual(capture['sections']['experience'], ascii_bullets(self.sections['experience']))
        self.assertNotIn('alex@example.test', json.dumps(capture))


class Review(unittest.TestCase):
    def setUp(self):
        self.capture = linkedin_pdf.capture(linkedin_pdf.sections_from_layout(copy.deepcopy(LAYOUT)))
        self.shown = self.capture['sections']

    def test_valid_review_is_sorted_rendered_and_keeps_unknowns(self):
        result = linkedin.validate_pdf_review(review(), self.capture, self.shown, [])
        self.assertEqual([f['priority'] for f in result['findings']], ['high', 'medium'])
        self.assertEqual(result['dropped_findings'], 0)
        self.assertEqual(result['profile_url'], 'https://www.linkedin.com/in/alex-example/')
        self.assertIn('featured', result['unread_sections'])
        self.assertIn('Suggested headline', result['text'])

    def test_misquotes_and_quotes_from_other_sections_are_dropped_not_relabelled(self):
        findings = review()['findings'] + [
            dict(review()['findings'][0], quote='Led a team of forty engineers'),
            dict(review()['findings'][0], section='skills', quote='Helped with research projects.'),
            dict(review()['findings'][0], section='featured'),
        ]
        result = linkedin.validate_pdf_review(review(findings=findings), self.capture, self.shown, [])
        self.assertEqual(result['dropped_findings'], 3)
        self.assertEqual({(f['section'], f['quote']) for f in result['findings']},
                         {('experience', 'Helped with research projects.'), ('headline', 'Data Analyst @ Example Corp')})

    def test_quotes_tolerate_wrapping_case_and_curly_punctuation(self):
        finding = dict(review()['findings'][0], quote='BUILT a weekly revenue dashboard   in Tableau used by twelve full-stack teams')
        result = linkedin.validate_pdf_review(review(findings=[finding], rewrites=[]), self.capture, self.shown, [])
        self.assertEqual(len(result['findings']), 1)

    def test_nothing_verifiable_is_an_error(self):
        bad = dict(review()['findings'][0], quote='Invented text')
        with self.assertRaisesRegex(ValueError, 'did not match'):
            linkedin.validate_pdf_review(review(findings=[bad], rewrites=[]), self.capture, self.shown, [])
        with self.assertRaisesRegex(ValueError, 'expected format'):
            linkedin.validate_pdf_review(['not', 'an object'], self.capture, self.shown, [])

    def test_fit_keeps_priority_sections_and_reports_shortening(self):
        sections = {'education': 'e' * 300, 'headline': 'h' * 50, 'experience': ('line ' * 20 + '\n') * 30}
        fitted, shortened = linkedin.fit_sections(sections, 1200)
        self.assertEqual(fitted['headline'], sections['headline'])
        self.assertIn('experience', shortened)
        self.assertTrue(sections['experience'].startswith(fitted['experience']))
        self.assertLessEqual(len(json.dumps(fitted)), 1200)


class ProviderStep(unittest.TestCase):
    def config(self, **changes):
        return {'provider': 'lmstudio', 'model': 'synthetic-qwen', 'local_model_url': 'http://127.0.0.1:1234',
                'local_model_context_tokens': 8192, 'local_model_timeout': 90, 'max_output_tokens': 3000,
                'input_cents_per_million': 0, 'output_cents_per_million': 0, **changes}

    def test_local_model_gets_fitted_profile_and_a_section_enum_it_can_quote(self):
        big = dict(self.capture(), sections={**self.capture()['sections'], 'experience': ('Delivered a reporting project. ' * 3 + '\n') * 120})
        with patch('agents.local_model.complete', return_value={'text': json.dumps(review()), 'model': 'synthetic-qwen'}) as complete:
            result = provider.generate('linkedin_review', {'linkedin_profile': big, 'target_role': ROLE}, self.config())
        step, system, prompt, schema, c, _ = complete.call_args.args
        self.assertEqual(step, 'linkedin_review')
        self.assertEqual(c['max_output_tokens'], linkedin.REVIEW_OUTPUT_TOKENS)
        sent = json.loads(prompt)
        self.assertEqual(sent['target_role'], ROLE)
        self.assertEqual(schema['properties']['findings']['items']['properties']['section']['enum'], list(sent['profile']))
        # The request satisfies local_model's own byte bound, so it is never refused for context.
        self.assertLessEqual(len(system.encode()) + len(prompt.encode()) + len(json.dumps(schema).encode()) + c['max_output_tokens'] + 512, 8192)
        self.assertIn('experience', result['artifact']['limitations'])
        self.assertEqual(result['cost_cents'], 0)

    def test_first_party_deployments_refuse_other_providers(self):
        with patch.dict(os.environ, {'STACK_FIRST_PARTY_AI_ONLY': '1'}), patch('agents.local_cli.generate') as cli:
            with self.assertRaisesRegex(ValueError, 'Stack-hosted AI'):
                provider.generate('linkedin_review', {'linkedin_profile': self.capture()}, self.config(provider='codex-cli'))
            cli.assert_not_called()

    def test_non_json_reply_is_a_retryable_error(self):
        with patch('agents.local_model.complete', return_value={'text': 'Here is some coaching prose.', 'model': 'q'}):
            with self.assertRaisesRegex(ValueError, 'expected format'):
                provider.generate('linkedin_review', {'linkedin_profile': self.capture()}, self.config())

    def capture(self):
        return linkedin_pdf.capture(linkedin_pdf.sections_from_layout(copy.deepcopy(LAYOUT)))


class Endpoint(unittest.TestCase):
    def test_upload_review_retry_and_account_isolation(self):
        from jaclang.testing.testing import JacTestClient
        upload = {'name': 'Profile.pdf', 'content': base64.b64encode(b'%PDF-1.4 synthetic').decode(), 'target_role': ROLE}
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / 'model.json'
            cfg.write_text(json.dumps({'invite_only': False, 'provider': 'lmstudio', 'model': 'synthetic-qwen',
                                       'local_model_url': 'http://127.0.0.1:1234'}))
            with patch.dict(os.environ, {'STACK_AGENT_CONFIG': str(cfg), 'JAC_DB_URL': '', 'STACK_REQUIRE_INVITE': '0',
                                         'STACK_LINKEDIN_ENABLED': '0'}), \
                    patch('agents.pdf_safety.inspect_spans', return_value={'pages': 2, 'text': '', 'layout': copy.deepcopy(LAYOUT)}):
                client = JacTestClient.from_file(str(Path('tests/linkedin_pdf_api.jac').resolve()), base_path=tmp + '/db')

                def rpc(name, args):
                    response = client.post('/function/' + name, json=args)
                    self.assertTrue(response.ok, response.text)
                    return response.data['result']
                try:
                    owner = client.register_user('linkedin-owner', 'Synthetic-password-123').data['token']
                    # Works while the browser LinkedIn feature is switched off.
                    with patch('agents.local_model.complete', side_effect=ValueError('Synthetic model unavailable')):
                        failed = rpc('linkedin_pdf_review', upload)
                    self.assertEqual((failed['kind'], failed['status']), ('linkedin_pdf', 'failed'))
                    self.assertIn('Synthetic model unavailable', failed['message'])
                    run_id = failed['id']
                    with patch('agents.local_model.complete', return_value={'text': json.dumps(review()), 'model': 'synthetic-qwen'}) as model:
                        done = rpc('agent_retry', {'id': run_id})
                        sent = json.loads(model.call_args.args[2])
                    self.assertEqual(done['status'], 'completed')
                    self.assertEqual(sent['target_role'], ROLE)
                    self.assertNotIn('alex@example.test', json.dumps(sent))
                    stored = rpc('agent_run', {'id': run_id})
                    self.assertEqual(stored['artifacts']['linkedin_review']['findings'][0]['priority'], 'high')
                    self.assertEqual(stored['artifacts']['linkedin_pdf']['file'], 'Profile.pdf')
                    self.assertIn('error', rpc('agent_retry', {'id': run_id}))
                    # Unexpected failures name only their type and stay retryable.
                    with patch('agents.local_model.complete', side_effect=TimeoutError()):
                        timed_out = rpc('linkedin_pdf_review', upload)
                    self.assertEqual(timed_out['status'], 'failed')
                    self.assertIn('could not finish (TimeoutError)', timed_out['message'])
                    # Invalid uploads create no run and never reach the model.
                    with patch('agents.local_model.complete') as model:
                        self.assertIn('error', rpc('linkedin_pdf_review', {**upload, 'name': 'Profile.docx'}))
                        model.assert_not_called()
                    client.register_user('linkedin-other', 'Synthetic-password-456')
                    self.assertIn('error', rpc('agent_run', {'id': run_id}))
                    client.set_auth_token(owner)
                    self.assertEqual(rpc('agent_run', {'id': run_id})['status'], 'completed')
                finally:
                    client.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
