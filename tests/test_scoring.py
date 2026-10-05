"""Resume scoring: the skills vocabulary, listing requirements, job match and resume quality."""
import unittest
from datetime import date
from agents import scoring, skills

NOW = date(2026, 9, 29)
JOB = {'title': 'Backend Software Engineer', 'description': '\n'.join([
    'Acme builds logistics software for an animation studio and a medical imaging lab.',
    'What you will do:',
    '- Design REST APIs and data pipelines in Python.',
    '- Take part in code reviews.',
    "What we're looking for:",
    "- Bachelor's degree in Computer Science or equivalent experience.",
    '- 2+ years of experience building backend services.',
    '- Proficiency in Java, Go, or Rust.',
    '- Experience with PostgreSQL and Docker.',
    '- Strong communication skills.',
    'Nice to have:',
    '- Kubernetes experience.',
    'Benefits:',
    '- 401(k) matching and Python training budget.',
    'Must be authorized to work in the United States.'])}


def outline(bullets=None, skill_lines=None, heading='Harbor Logistics | Software Engineer | Remote | June 2023 – Present', education="Great Lakes University | Bachelor of Science in Computer Science | May 2023"):
    bullets = bullets if bullets is not None else [
        'Built REST APIs in Python serving 1,200+ monthly users.',
        'Reduced PostgreSQL query latency by 40% with batched reads.',
        'Shipped Docker-based deploys 10 times per week.']
    out = [{'id': 's0', 'title': 'Education', 'lines': [], 'entries': [{'id': 's0.e0', 'heading': education, 'movable': True, 'bullets': []}]},
           {'id': 's1', 'title': 'Experience', 'lines': [], 'entries': [
               {'id': 's1.e0', 'heading': heading, 'movable': True, 'bullets': [{'id': 's1.e0.b' + str(i), 'text': t} for i, t in enumerate(bullets)]}]}]
    if skill_lines:
        out.append({'id': 's2', 'title': 'Skills', 'entries': [], 'lines': [{'id': 's2.l' + str(i), 'label': 'Languages', 'text': t} for i, t in enumerate(skill_lines)]})
    return out


class Vocabulary(unittest.TestCase):
    def test_aliases_joined_words_and_ordinary_words(self):
        text = 'Python, R and JS; Postgres or PostgreSQL; k8s, CI/CD, REST APIs, C++, C#, Supabase/PostgreSQL, React-based, Amazon Web Services.'
        self.assertEqual(skills.names(text), {'Python', 'R', 'JavaScript', 'PostgreSQL', 'Kubernetes', 'CI/CD', 'REST APIs', 'C++', 'C#', 'Supabase', 'React', 'AWS'})
        # Ordinary words are not products: "Excel in", "act as owners", "animation studio", "fast-paced", "the rest".
        self.assertEqual(skills.names('Excel in a fast-paced team. We act as owners of an animation studio and the rest. Use Excel and Rust.'), {'Excel', 'Rust'})


class Requirements(unittest.TestCase):
    def test_sections_weights_alternatives_and_boilerplate(self):
        need = scoring.job_requirements(JOB)
        by = {s['term']: s for s in need['skills']}
        self.assertEqual(by['Java, Go or Rust']['alternatives'], ['Java', 'Go', 'Rust'])
        self.assertTrue(by['PostgreSQL']['required'] and by['Docker']['required'])
        self.assertEqual(by['Kubernetes']['weight'], 1.5)
        self.assertFalse(by['REST APIs']['required'])
        # Company blurb and benefits are not requirements.
        self.assertFalse({'Animation', 'Imaging'} & set(by))
        self.assertEqual(by['Python']['weight'], 1.0)
        self.assertEqual(need['years']['min'], 2)
        self.assertEqual(need['education']['level'], 3)
        self.assertIn('communication', need['soft'])
        self.assertFalse([k for k in need['keywords'] if 'united' in k['term'] or '401' in k['term']])


class Match(unittest.TestCase):
    def score(self, **kw):
        return scoring.match(outline(**kw), JOB, now=NOW)

    def test_demonstrated_beats_listed_and_alternatives_need_one(self):
        base = self.score()
        self.assertEqual({m['term'] for m in base['missing']}, {'Backend development', 'Java, Go or Rust', 'Kubernetes', 'Code review', 'Data pipelines'})
        with_go = self.score(skill_lines=['Go'])
        shown_go = self.score(bullets=outline()[1]['entries'][0]['bullets'] and [b['text'] for b in outline()[1]['entries'][0]['bullets']] + ['Rewrote a billing service in Go, cutting p99 latency by 30%.'])
        self.assertLess(base['score'], with_go['score'])
        self.assertLess(with_go['score'], shown_go['score'])
        via = next(m for m in with_go['matched'] if m['term'] == 'Java, Go or Rust')
        self.assertEqual((via['where'], via['via']), ('skills line', 'Go'))

    def test_stuffing_earns_nothing_and_is_flagged(self):
        twice = self.score(skill_lines=['Kubernetes', 'Kubernetes'])
        stuffed = self.score(skill_lines=['Kubernetes'] * 6)
        self.assertEqual(twice['score'], stuffed['score'])
        self.assertEqual(stuffed['stuffed'], [{'term': 'Kubernetes', 'count': 6}])

    def test_missing_is_supported_only_by_verified_facts(self):
        facts = [{'key': 'answer:k8s', 'value': 'Ran Kubernetes clusters at school', 'verified': True}, {'key': 'x', 'value': 'Rust', 'verified': False}]
        missing = {m['term']: m['supported'] for m in scoring.match(outline(), JOB, facts, NOW)['missing']}
        self.assertTrue(missing['Kubernetes'])
        self.assertFalse(missing['Java, Go or Rust'])

    def test_title_education_experience_and_other_text(self):
        result = self.score()
        parts = {c['key']: c['score'] for c in result['components']}
        self.assertEqual((parts['education'], parts['experience']), (100, 100))
        self.assertGreater(parts['title'], 50)
        junior = self.score(heading='Harbor Logistics | Software Engineer Intern | Remote | June 2026 – Present', education='Great Lakes | Associate of Science | 2026')
        parts = {c['key']: c['score'] for c in junior['components']}
        self.assertEqual(parts['education'], 75)
        self.assertLess(parts['experience'], 20)
        # Coursework outside bullets counts, a little less than a bullet.
        elsewhere = scoring.match(outline(), JOB, now=NOW, text='Relevant coursework: code review practices, Kubernetes')
        self.assertEqual({m['term']: m['where'] for m in elsewhere['matched']}['Kubernetes'], 'elsewhere')

    def test_no_requirements_leaves_components_out(self):
        result = scoring.match(outline(), {'title': 'Engineer', 'description': 'Build things.'}, now=NOW)
        self.assertEqual({c['key'] for c in result['components']}, {'title'})


class Quality(unittest.TestCase):
    def quality(self, bullets):
        return scoring.quality(outline(bullets=bullets))

    def parts(self, bullets):
        return {c['key']: c['score'] for c in self.quality(bullets)['components']}

    def test_metrics_verbs_and_tense(self):
        good = ['Built a queue that cut latency 40%.', 'Led a 4-person team shipping 12 releases.', 'Reduced costs by $2K per month.']
        weak = ['Responsible for the queue and its latency.', 'Helped the team with various releases.', 'Worked on costs for the department.']
        self.assertEqual(self.parts(good)['metrics'], 100)
        self.assertEqual(self.parts(weak)['metrics'], 0)
        self.assertGreater(self.parts(good)['verbs'], self.parts(weak)['verbs'])
        issues = {i['kind'] for i in self.quality(weak)['issues']}
        self.assertTrue({'metric', 'weak_verb', 'clarity'} <= issues)
        past = scoring.quality(outline(bullets=['Build a queue that cuts latency 40%.'], heading='Old Co | Engineer | 2020 – 2022'))
        self.assertEqual([i['kind'] for i in past['issues'] if i['kind'] == 'tense'], ['tense'])
        current = scoring.quality(outline(bullets=['Build a queue that cuts latency 40%.']))
        self.assertFalse([i for i in current['issues'] if i['kind'] == 'tense'])

    def test_repetition_and_length(self):
        repeated = ['Built a queue with 3 workers.', 'Built a cache for 2 services.', 'Built an API for 5 teams.', 'Built a CLI for 9 users.']
        varied = ['Built a queue with 3 workers.', 'Designed a cache for 2 services.', 'Shipped an API for 5 teams.', 'Automated a CLI for 9 users.']
        self.assertLess(self.parts(repeated)['repetition'], self.parts(varied)['repetition'])
        long = ['Built ' + ' '.join(['a'] * 40) + ' queue with 3 workers.']
        self.assertTrue([i for i in self.quality(long)['issues'] if i['kind'] == 'length'])

    def test_parser_check_is_a_component_only_when_given(self):
        self.assertNotIn('parsing', self.parts(['Built a queue with 3 workers.']))
        with_parse = scoring.quality(outline(), parse={'passed': 9, 'total': 10})
        self.assertEqual({c['key']: c['score'] for c in with_parse['components']}['parsing'], 90)



if __name__ == '__main__':
    unittest.main()
