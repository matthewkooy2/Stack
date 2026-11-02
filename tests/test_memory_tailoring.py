"""Memory-grounded tailoring without a model: guards, coverage, review and account checks.

Run: jac run --no-serve tests/test_memory_tailoring.py"""
import copy
import itertools
import random
import re
import unittest

import agents.memory_access as memory_access
import agents.memory_tailoring as mt
import agents.record_resume as record_resume
import agents.interview as interview
from tests.memory_tailoring_cases import RESUME, JOB, bank_views, resume_view, violations

LOCAL = {'provider': 'lmstudio', 'model': 'fixture', 'local_model_context_tokens': 65536, 'max_output_tokens': 1536}


def snapshot(owner='owner', extra=()):
    return memory_access.collect(owner, [resume_view()] + bank_views() + list(extra),
                                 [{'key': 'name', 'value': 'Jordan Rivera', 'verified': True, 'source': 'Profile'},
                                  {'key': 'salary', 'value': 'Unverified guess', 'verified': False}], [])


def prepared():
    return {**record_resume.prepare({'records': RESUME, 'template': 'classic', 'upload_digest': 'u', 'revision': 3})}


def handles(text):
    """Entry name -> prompt handle, read from rendered memory."""
    out = {}
    for h, header in re.findall(r'^## (E\d+) · [^·]+ · (.+)$', text, re.M):
        out[header.split(' · ')[0].split(' (part')[0]] = h
    return out


class Model:
    """Scripted stand-in: a good compose answer with deliberate violations mixed in."""

    def __init__(self, verify='supported', screen=None, fail_first=None):
        self.calls, self.verify, self.screen, self.fail_first = [], verify, screen, fail_first

    def __call__(self, step, context, c):
        self.calls.append((step, context))
        if self.fail_first and len(self.calls) == 1:
            raise ValueError(self.fail_first)
        if step == 'tailor_screen':
            h = handles(context['memory'])
            return {'artifact': {'entries': self.screen(h) if self.screen else
                                 [{'entry': x, 'relevance': 80, 'lines': [], 'reason': 'fits'} for x in h.values()]}}
        if step == 'tailor_verify':
            return {'artifact': {'results': [{'id': x['id'], 'verdict': self.verify(x) if callable(self.verify) else self.verify,
                                              'problem': ''} for x in context['candidates']]}}
        h = handles(context['memory'])
        project, intern = h.get('Transit delay dashboard'), h.get('Data Intern, City of Detroit')
        sections = [{'heading': 'Experience', 'items': [
            {'entry': 'R.e0', 'reason': 'SQL and reporting', 'lines': [
                {'text': 'Reduced invoice matching errors by 18% by writing SQL checks against the billing database.', 'cites': ['R.r5']},
                {'text': 'Built weekly Excel reports tracking carrier on-time rates for 6 regional managers.', 'cites': ['R.r4']},
                {'text': 'Built Power BI dashboards on carrier on-time rates for 6 regional managers.', 'cites': ['R.r4']},
                {'text': 'Led a team of 6 regional managers.', 'cites': ['R.r4']}]}]}]
        if intern:
            sections[0]['items'].append({'entry': intern, 'reason': 'Python geocoding', 'lines': [
                {'text': 'Geocoded 12,000 resident service requests in Python to map response times by neighborhood.', 'cites': [intern + '.r0']},
                {'text': 'Presented neighborhood findings to stakeholders.', 'cites': [intern + '.r1']},
                {'text': 'Cleaned bus GPS data with pandas.', 'cites': [(project or intern) + '.r0']}]})
        if project:
            sections.insert(0, {'heading': 'Projects', 'items': [{'entry': project, 'reason': 'Tableau and Python', 'lines': [
                {'text': 'Cleaned two years of public bus GPS data with Python and pandas.', 'cites': [project + '.r0']},
                {'text': 'Published a Tableau dashboard of hourly route delays that drew 300 views in its first month.', 'cites': [project + '.r1']},
                {'text': 'Deployed the dashboard to production.', 'cites': [project + '.r2']}]}]})
        sections.append({'heading': 'Education', 'items': [{'entry': 'R.e2', 'reason': 'Degree', 'lines': [
            {'text': 'B.S. Statistics, Wayne State University, 2022', 'cites': ['R.r11']}]}]})
        cert = h.get('Tableau Desktop Specialist')
        if cert:
            sections.append({'heading': 'Certifications', 'items': [{'entry': cert, 'reason': 'Dashboard tool', 'lines': []}]})
        skill_cites = ['R.r13'] + [h[n] + '.name' for n in ('Python', 'Tableau') if n in h]
        sections.append({'heading': 'Skills', 'items': [
            {'entry': 'SKILLS', 'reason': 'Listing skills', 'lines': [
                {'text': 'SQL, Python, Tableau, Excel', 'cites': skill_cites},
                {'text': 'SQL, Python, Tableau, Power BI', 'cites': skill_cites}]}]})
        left = [{'entry': x, 'reason': 'Unrelated to data work'} for name, x in h.items() if name.startswith('Gleaners')]
        return {'artifact': {'summary': 'Leads with Python, SQL and Tableau evidence.', 'sections': sections, 'left_out': left}}


def run(model, c=LOCAL, snap=None, served=None):
    return mt.run(prepared(), snap or snapshot(), JOB, c, model, served, 'target')


def all_text(proposal):
    return [line['text'] for s in proposal['sections'] for i in s['items'] for line in i['lines']]


class Guards(unittest.TestCase):
    def test_line_checks(self):
        src = ['Reduced invoice matching errors by 18% by writing SQL checks against the billing database.']
        self.assertEqual(mt.check_line(src[0], src, ''), '')
        self.assertEqual(mt.check_line('Cut invoice matching errors 18% with SQL checks on billing data.', src, ''), '')
        self.assertIn('numbers', mt.check_line('Reduced invoice errors by 25% with SQL checks.', src, ''))
        self.assertIn('named something', mt.check_line('Reduced invoice matching errors by 18% with Power BI checks.', src, ''))
        self.assertIn('named something', mt.check_line('Python checks reduced invoice matching errors by 18%.', src, ''))
        self.assertIn('scope', mt.check_line('Led SQL checks that reduced invoice matching errors by 18%.', src, ''))
        self.assertIn('negation', mt.check_line('Deployed it to production from a scheduled notebook.',
                                                ['I did not deploy it to production; it runs from a scheduled notebook.'], ''))
        self.assertIn('scope', mt.check_line('Led neighborhood findings for the analytics team.',
                                             ["Presented the neighborhood findings to the department's analytics lead."], ''))
        self.assertIn('longer', mt.check_line('Reduced invoice matching errors by 18% by writing SQL checks against the billing database '
                                              'every single week for every regional office and their many vendors and carriers.', src, ''))
        self.assertTrue(mt.check_line('SQL, Python, Power BI', ['Excel, SQL, customer service', 'Python'], '', True))
        self.assertIn('skills', mt.check_line('SQL, Python, machine learning', ['Excel, SQL, customer service', 'Python'], '', True))
        self.assertIn('skills', mt.check_line('Python (daily use)', ['Python', 'Proficiency: Intermediate'], '', True))
        self.assertEqual(mt.check_line('Python (Intermediate), SQL', ['Python', 'Proficiency: Intermediate', 'Excel, SQL'], '', True), '')
        # A one-letter tool must match as a word, not as a letter inside another word.
        self.assertIn('named something', mt.check_line('Built reports in R.', ['Built weekly reports.'], ''))

    def test_header_never_invents_present(self):
        snap = snapshot()
        intern = next(e for e in snap['entries'] if e['name'] == 'Data Intern, City of Detroit')
        self.assertEqual(intern['header'], 'Data Intern, City of Detroit · Data Intern · City of Detroit Office of Innovation · Detroit, MI · Jun 2021 – Aug 2021')
        volunteer = next(e for e in snap['entries'] if e['type'] == 'volunteering')
        self.assertTrue(volunteer['header'].endswith('Sep 2020'))
        self.assertNotIn('Present', volunteer['header'])


class Collect(unittest.TestCase):
    def test_full_memory_drafts_excluded_and_owner_bound(self):
        snap = snapshot()
        keys = {e['key'] for e in snap['entries']}
        self.assertEqual(keys, {'resume:target', 'fact:name'} | {'bank:b' + str(n) for n in range(6)})
        self.assertEqual({x['key'] for x in snap['excluded']}, {'bank:b6', 'fact:salary'})
        self.assertIs(memory_access.validate(snap, 'owner'), snap)
        with self.assertRaises(ValueError):
            memory_access.validate(snap, 'someone-else')
        tampered = copy.deepcopy(snap)
        tampered['entries'][1]['lines'][1]['text'] += ' Led the team.'
        with self.assertRaises(ValueError):
            memory_access.validate(tampered, 'owner')

    def test_interview_facts_bounded_and_reported(self):
        memory = memory_access.interview_facts(snapshot(), JOB, 6000, ('resume:target',))
        self.assertEqual({c['key'] for c in memory['coverage']}, {'bank:b0', 'bank:b1', 'bank:b5'})
        self.assertTrue(all(c['included'] for c in memory['coverage']))
        data = interview.create(JOB, [], 'app', 'target', RESUME, memory['facts'])
        kinds = [q['kind'] for q in data['questions']]
        self.assertEqual(kinds, ['experience', 'project', 'behavioral'])
        # The base resume still comes first; memory adds the project the resume lacks.
        self.assertIn('Lakeshore', data['questions'][0]['question'])
        self.assertIn('Transit delay dashboard', data['questions'][1]['question'])
        small = memory_access.interview_facts(snapshot(), JOB, 200, ('resume:target',))
        self.assertTrue(any(not c['included'] for c in small['coverage']))


class Tailoring(unittest.TestCase):
    def test_single_call_reads_everything_and_blocks_invention(self):
        model = Model(verify=lambda x: 'unsupported' if 'stakeholders' in x['text'] else 'supported')
        proposal = run(model)
        self.assertEqual([s for s, _ in model.calls], ['tailor_compose', 'tailor_verify'])
        prompt = model.calls[0][1]['memory']
        for e in snapshot()['entries']:
            if e['key'] != 'resume:target':
                for line in e['lines']:
                    self.assertIn(line['text'], prompt)
        self.assertNotIn('neural network', prompt)
        self.assertNotIn('Unverified guess', prompt)
        text = all_text(proposal)
        joined = ' '.join(text)
        for bad in ('Power BI', 'Led a team', 'Deployed', 'stakeholders'):
            self.assertNotIn(bad, joined)
        # A rejected rewrite of a resume line already covered adds no duplicate; an unsupported
        # memory line is left out with a note instead of being printed unreviewed.
        self.assertEqual(sum('carrier on-time rates' in t for t in text), 1)
        self.assertFalse(any('analytics lead' in t for t in text))
        self.assertTrue(any('Verification found' in n and 'Data Intern' in n for n in proposal['notes']))
        self.assertIn('Published a Tableau dashboard of hourly route delays that drew 300 views in its first month.', text)
        # A cross-entry citation is refused, so project facts stay with the project.
        intern = next(i for s in proposal['sections'] for i in s['items'] if i['name'] == 'Data Intern, City of Detroit')
        self.assertFalse(any('bus GPS' in line['text'] for line in intern['lines']))
        self.assertEqual(sum('SQL, Python, Tableau' in t for t in text), 1)
        self.assertTrue(any('Power BI' in n for n in proposal['notes']))
        coverage = {c['key']: c for c in proposal['coverage']['entries']}
        self.assertEqual(coverage['bank:b0']['status'], 'used')
        self.assertEqual(coverage['bank:b3']['status'], 'used')  # Python, cited by the skills line
        self.assertEqual(coverage['bank:b5']['status'], 'left_out')
        self.assertEqual(coverage['bank:b5']['reason'], 'Unrelated to data work')
        self.assertEqual(proposal['coverage']['mode'], 'single')
        self.assertTrue(all('compose' in c['reviewed_by'] for c in coverage.values()))
        self.assertEqual({x['key'] for x in proposal['coverage']['excluded']}, {'bank:b6', 'fact:salary'})

    def test_review_rejections_and_no_silent_loss(self):
        p = prepared()
        artifact = mt.tailor(p, run(Model()))
        self.assertEqual(violations(artifact['records']), [])
        ids = {c['id']: c for c in artifact['changes']}
        kinds = {c['kind'] for c in artifact['changes']}
        self.assertTrue({'add', 'rewrite', 'omit', 'order'} <= kinds, kinds)
        self.assertIn('omit:R.e1', ids)  # the sales role
        self.assertIn('omit:R.r6', ids)  # vendor emails
        texts = [r['text'] for r in artifact['records']]
        self.assertEqual(texts[:2], ['Jordan Rivera', 'Detroit, MI · jordan.rivera@example.com · (555) 010-4477'])
        self.assertIn('Operations Analyst, Lakeshore Logistics, Jun 2022 – Present', texts)
        # Reject everything: the original resume comes back, in its order.
        original = mt.apply(p, artifact['plan'], set(ids))
        self.assertEqual([r['text'] for r in original], [r['text'] for r in RESUME])
        self.assertEqual([r['kind'] for r in original], [r['kind'] for r in RESUME])
        # Any combination keeps every base line unless its omission was approved.
        base = mt._base_lines(mt.segment(p['records']))
        rng = random.Random(7)
        lines = [(i, l) for s in artifact['plan']['sections'] for i in s['items'] for l in i['lines']]
        for _ in range(300):
            rejected = {x for x in ids if rng.random() < 0.5}
            out = {r['text'] for r in mt.apply(p, artifact['plan'], rejected)}
            for line in base:
                if line['text'] in out:
                    continue
                approved = ({'omit:' + line['uid'], 'omit:' + line['entry']} & set(artifact['plan']['omits'])) - rejected
                # Otherwise an accepted rewrite of this line must be printed in its place.
                reworded = [l for i, l in lines if line['uid'] in l['cites'] and 'rewrite:' + l['uid'] not in rejected
                            and 'add:' + i['key'] not in rejected and l['text'] in out]
                self.assertTrue(approved or reworded, (line, sorted(rejected)))
        added = mt.apply(p, artifact['plan'], {'add:bank:b0'})
        self.assertFalse(any('GPS' in r['text'] for r in added))

    def test_finalize_rechecks_sources(self):
        p, snap = prepared(), snapshot()
        artifact = mt.tailor(p, run(Model(), snap=snap))
        artifact['rejected'] = ['omit:R.e1']
        final = mt.finalize(p, snap, artifact)['tailor']
        self.assertTrue(final['final'])
        self.assertIn('Trained 4 new associates on the point-of-sale system.', [r['text'] for r in final['records']])
        self.assertEqual(record_resume.check_documents(*[__import__('base64').b64decode(final[k]['content']) for k in ('pdf', 'docx')], final['records'])['ok'], True)
        self.assertIn('memory_coverage', final['change_record'])
        changed = copy.deepcopy(bank_views())
        changed[0]['records'][1]['text'] = 'Published a Tableau dashboard of route delays by hour that got 3,000 views.'
        edited = memory_access.collect('owner', [resume_view()] + changed, [], [])
        with self.assertRaisesRegex(ValueError, 'memory bank changed'):
            mt.finalize(p, edited, artifact)
        tampered = copy.deepcopy(artifact)
        tampered['plan']['sections'][0]['items'][0]['lines'][0]['text'] = 'Published a Tableau dashboard with 9,000 views.'
        with self.assertRaises(ValueError):
            mt.finalize(p, snap, tampered)
        foreign = copy.deepcopy(artifact)
        foreign['rejected'] = ['not-a-change']
        with self.assertRaises(ValueError):
            mt.finalize(p, snap, foreign)

    def test_oversized_memory_is_screened_not_truncated(self):
        many = [{'id': 'x' + str(n), 'name': 'Warehouse shift report ' + str(n), 'kind': 'experience_bank', 'confirmed': True,
                 'revision': 1, 'entry_type': 'project', 'fields': {'technologies': 'Excel'}, 'source': 'notes',
                 'records': [{'id': 'r' + str(k), 'kind': 'bullet', 'text': 'Counted pallets in aisle %d of warehouse %d by hand.' % (k, n)}
                             for k in range(12)]} for n in range(60)]
        huge = {'id': 'big', 'name': 'Long volunteer log', 'kind': 'experience_bank', 'confirmed': True, 'revision': 1,
                'entry_type': 'other', 'fields': {}, 'source': 'log',
                'records': [{'id': 'r' + str(k), 'kind': 'bullet', 'text': 'Shift %d: stocked shelves and greeted visitors at the pantry.' % k}
                            for k in range(220)]}
        snap = snapshot(extra=many + [huge])
        c = {**LOCAL, 'local_model_context_tokens': 16384}
        skipped = set()

        def screen(h):
            out = []
            for name, x in h.items():
                if name == 'Warehouse shift report 3' and x not in skipped:
                    skipped.add(x)  # skipped once, so the retry pass must ask again
                    continue
                if name == 'Warehouse shift report 7':
                    continue  # never rated
                out.append({'entry': x, 'relevance': 90 if name in ('Transit delay dashboard', 'Data Intern, City of Detroit',
                            'Tableau Desktop Specialist', 'Python', 'Tableau') else 5, 'lines': [], 'reason': 'rated'})
            return out
        model = Model(screen=screen)
        proposal = run(model, c, snap)
        steps = [s for s, _ in model.calls]
        self.assertGreater(steps.count('tailor_screen'), 3)
        self.assertEqual(proposal['coverage']['mode'], 'screened')
        coverage = {x['key']: x for x in proposal['coverage']['entries']}
        self.assertEqual(len(coverage), len(snap['entries']) - 1)
        for key, x in coverage.items():
            self.assertTrue(x['reviewed_by'] or not x['rated'], key)
        self.assertTrue(any(r.startswith('screen retry') for r in coverage['bank:x3']['reviewed_by']))
        self.assertFalse(coverage['bank:x7']['rated'])
        self.assertEqual(coverage['bank:x10']['status'], 'screened_out')
        self.assertEqual(coverage['bank:b0']['status'], 'used')
        self.assertTrue(any('not rated' in n for n in proposal['notes']))
        # The 220-line log was split into parts; every part was read.
        parts = [ctx['memory'] for s, ctx in model.calls if s == 'tailor_screen' and 'Long volunteer log' in ctx['memory']]
        self.assertGreater(len(parts), 1)
        for k in range(220):
            self.assertTrue(any('Shift %d:' % k in p for p in parts), k)
        for s, ctx in model.calls:
            self.assertLessEqual(mt.request_size(s, ctx, c), 16384)

    def test_server_context_smaller_than_config_retries_smaller(self):
        model = Model(fail_first=mt.CONTEXT_ERROR + ' Increase the configured context and load the model with that context before retrying.')
        proposal = run(model)
        self.assertIn('context retry', proposal['coverage']['calls'])
        self.assertLess(proposal['coverage']['context_tokens'], 65536)
        served = run(Model(), served=20000)
        self.assertEqual(served['coverage']['context_tokens'], 20000)
        with self.assertRaisesRegex(ValueError, 'Increase the model context'):
            run(Model(), {**LOCAL, 'local_model_context_tokens': 4096})

    def test_unverified_rewrites_revert(self):
        proposal = run(Model(verify='unsupported'))
        for s in proposal['sections']:
            for i in s['items']:
                for line in i['lines']:
                    self.assertEqual(line['status'], 'verbatim', line)
        model = Model()
        model.verify = lambda x: (_ for _ in ()).throw(ValueError('down'))
        proposal = run(model)
        self.assertTrue(any('could not verify' in n for n in proposal['notes']))


if __name__ == '__main__':
    unittest.main()
