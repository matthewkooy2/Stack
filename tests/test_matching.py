"""Matching contracts across professions and career stages. No network or server."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from discovery.normalize import normalize
from discovery.matching import criteria, evaluate, facts, parse_places, parse_user_location, role_match, parse_roles

SOURCE = {'id': 'test', 'name': 'Example', 'adapter': 'career'}


def job(title, **raw):
    j = normalize({'title': title, 'company': raw.pop('company', 'Example Co'), 'url': 'https://example.com/' + title.replace(' ', '-'), 'country': 'US', **raw}, SOURCE)
    j['facts'] = facts(j)
    return j


def check(j, key, **profile):
    c = criteria(profile)
    result = evaluate(j, c)
    found = [x for x in result['checks'] if x['key'] == key]
    return (found[0]['status'] if found else 'n/a'), result


class Roles(unittest.TestCase):
    def matched(self, title, role):
        return role_match(title, parse_roles(role))['status'] == 'match'

    def test_word_boundaries_and_acronyms(self):
        self.assertTrue(self.matched('School Nurse (RN)', 'RN'))
        self.assertTrue(self.matched('Registered Nurse - Med/Surg', 'RN'))
        self.assertFalse(self.matched('Senior Machine Learning Engineer', 'RN'))
        self.assertFalse(self.matched('Internal Audit Lead', 'Intern'))
        self.assertTrue(self.matched('Software Engineer Intern', 'Software engineering internship'))

    def test_related_titles_stay_within_the_occupation(self):
        self.assertTrue(self.matched('Charge Nurse, ICU', 'Registered nurse'))
        self.assertTrue(self.matched('Staff Nurse - Emergency Department', 'Registered nurse'))
        self.assertFalse(self.matched('Licensed Practical Nurse', 'Registered nurse'))
        self.assertFalse(self.matched('Nurse Practitioner', 'Registered nurse'))
        self.assertFalse(self.matched('Delivery Driver', 'Bus driver'))
        self.assertFalse(self.matched('Teacher Recruitment Specialist', 'Teacher'))
        self.assertFalse(self.matched('Nurse Recruiter', 'Nurse'))
        self.assertTrue(self.matched('Business Intelligence Analyst', 'Data analyst'))

    def test_multiple_roles_and_qualifiers(self):
        roles = parse_roles('Line cook, prep cook or dishwasher')
        self.assertEqual([r['text'] for r in roles], ['Line cook', 'prep cook', 'dishwasher'])
        self.assertTrue(self.matched('Prep Cook', 'Line cook, prep cook'))
        senior = parse_roles('Senior product manager')[0]
        self.assertEqual((senior['core'], senior['levels']), ('product manager', ['Senior']))
        self.assertEqual(parse_roles('Part-time barista')[0]['types'], ['Part-time'])


class Locations(unittest.TestCase):
    def test_parsing(self):
        self.assertEqual(parse_places('Dallas, Texas, us')[0], [{'city': 'dallas', 'state': 'TX'}])
        self.assertEqual(parse_places('San Francisco, CA; New York, NY')[0], [{'city': 'san francisco', 'state': 'CA'}, {'city': 'new york', 'state': 'NY'}])
        self.assertEqual(parse_places('Brooklyn, NY')[0], [{'city': 'new york', 'state': 'NY'}])
        self.assertEqual(parse_user_location('Texas'), {'city': '', 'state': 'TX'})
        self.assertIsNone(parse_user_location('United States'))

    def test_state_city_and_same_named_cities(self):
        self.assertEqual(check(job('Nurse', location='Houston, TX'), 'location', location='Texas')[0], 'match')
        self.assertEqual(check(job('Nurse', location='Chicago, IL'), 'location', location='CA')[0], 'conflict')
        self.assertEqual(check(job('Driver', location='Arlington, TX'), 'location', location='Arlington, VA')[0], 'conflict')
        self.assertEqual(check(job('Nurse'), 'location', location='Detroit, MI')[0], 'unknown')

    def test_remote_eligibility(self):
        west = job('Engineer', location='Remote - California, Oregon, Washington', mode='Remote')
        self.assertEqual(check(west, 'location', location='San Diego, CA', modes=['Remote'])[0], 'match')
        self.assertEqual(check(west, 'location', location='Austin, TX', modes=['Remote'])[0], 'conflict')
        # Location-bound users accept US-remote jobs unless they rule out remote work.
        us = job('Accountant', location='Remote - US', mode='Remote')
        self.assertEqual(check(us, 'location', location='New York, NY')[0], 'match')
        self.assertEqual(check(us, 'modes', location='New York, NY', modes=['On-site'])[0], 'conflict')


class ListingFacts(unittest.TestCase):
    def test_pay(self):
        pay = facts(job('Cook', description='Pay range: $38 - $52 per hour.'))['pay']
        self.assertEqual((pay['min'], pay['max'], pay['unit'], pay['source']), (38.0, 52.0, 'hour', 'Pay stated in the listing text'))
        self.assertIsNone(facts(job('Engineer', description='We raised $120M in Series B funding. Great pay and a 401(k).'))['pay'])
        start = facts(job('Nurse', description='Starting pay is $39 per hour.'))['pay']
        self.assertEqual((start['min'], start['max']), (39.0, None))
        self.assertIsNone(facts(job('Nurse', compensation={'min': 80000, 'max': 95000, 'unit': 'year', 'currency': 'USD', 'estimated': True}))['pay'])
        hourly = job('Nurse', compensation={'min': 35, 'max': 42, 'unit': 'hour', 'currency': 'USD'})
        self.assertEqual(check(hourly, 'salary', salary_min=80000, salary_period='year')[0], 'match')
        self.assertEqual(check(hourly, 'salary', salary_min=90000, salary_period='year')[0], 'conflict')
        self.assertEqual(check(job('Nurse'), 'salary', salary_min=20, salary_period='hour')[0], 'unknown')

    def test_employment_type(self):
        self.assertEqual(normalize({'title': 'X', 'company': 'Y', 'url': 'https://e.com/x', 'employment_type': 'Full-Time'}, SOURCE)['employment_type'], 'Full-time')
        self.assertEqual(facts(job('Line Cook - Part Time', employment_type='Full-time'))['employment'], ['Full-time', 'Part-time'])
        permanent = job('Accountant', employment_type='Permanent')
        self.assertEqual(check(permanent, 'employment_types', employment_types=['Full-time'])[0], 'unknown')
        self.assertEqual(check(permanent, 'employment_types', employment_types=['Contract'])[0], 'conflict')

    def test_levels(self):
        for title, level in [('Registered Nurse - Oakland Senior Living', ''), ('Staff Nurse', ''), ('Staff Accountant', ''), ('Staff Software Engineer', 'Senior'),
                             ('Software Engineer II', 'Mid-level'), ('Electrician l', 'Entry-level'), ('Lead Teacher', 'Mid-level'), ('Director of Nursing', 'Leadership'),
                             ('Journeyman Electrician', 'Mid-level'), ('Master Electrician', 'Senior'), ('Data Science Intern', 'Internship')]:
            self.assertEqual(facts(job(title))['level'], level, title)

    def test_real_listing_formats(self):
        # Found in catalog listings: pay on the line after its heading, curly apostrophes,
        # offices listed next to a US-remote scope, and "mentor entry-level engineers".
        pay = facts(job('PM', description='For pay transparency purposes, the base salary range for this full-time position is:\n$240,000—$300,000 USD'))['pay']
        self.assertEqual((pay['min'], pay['max'], pay['unit']), (240000.0, 300000.0, 'year'))
        self.assertEqual(facts(job('Teacher', description='Bachelor’s degree (required)'))['education']['name'], "Bachelor's")
        self.assertIsNone(facts(job('Counselor', description='We support high school students applying to college.'))['education'])
        offices = job('Staff PM', location='Seattle, San Francisco, New York, US - Remote', mode='Remote')
        self.assertEqual(check(offices, 'location', location='Denver, CO', modes=['Remote'])[0], 'match')
        self.assertEqual(facts(job('Transit Design Manager', description='Mentor entry-level engineers.'))['level'], '')
        self.assertEqual(facts(job('Assistant Principal of Operations'))['level'], 'Leadership')
        self.assertEqual(facts(job('PM', description='Minimum 5+ years managing complex programs.'))['years']['min'], 5)
        self.assertTrue(facts(job('Senior PM - Remote (U.S.)', mode='Remote'))['remote_scope']['us'])

    def test_years_and_education(self):
        self.assertEqual(facts(job('Analyst', description='Requirements\n3+ years of SQL experience.'))['years'] | {'quote': ''}, {'min': 3, 'required': True, 'quote': ''})
        self.assertFalse(facts(job('Analyst', description='2+ years of Tableau experience preferred.'))['years']['required'])
        self.assertEqual(facts(job('Analyst', description="5 years of experience, or 3 years of experience with a Master's degree."))['years']['min'], 3)
        self.assertEqual(facts(job('Apprentice', description='No experience required.'))['years']['min'], 0)
        self.assertIsNone(facts(job('Engineer', description='Founded 20 years ago, we have served clients.'))['years'])
        equivalent = job('Engineer', description="Bachelor's degree in Computer Science or equivalent practical experience.")
        self.assertEqual(check(equivalent, 'education', education='High school')[0], 'partial')
        self.assertEqual(check(job('NP', description="Master's degree required."), 'education', education="Bachelor's")[0], 'conflict')


class Evaluation(unittest.TestCase):
    def test_stage_and_experience(self):
        senior = job('Senior Accountant', description='5+ years of accounting experience required.')
        self.assertTrue(evaluate(senior, criteria({'roles': 'accountant', 'stage': 'Student'}))['excluded'])
        self.assertFalse(evaluate(senior, criteria({'roles': 'accountant', 'stage': 'Experienced', 'years': 6}))['excluded'])
        stretch = evaluate(senior, criteria({'roles': 'accountant', 'stage': 'Experienced', 'years': 4}))
        self.assertFalse(stretch['excluded']);self.assertTrue(stretch['caveats'])
        # Career changers are not filtered out of entry-level roles by total years.
        entry = job('Junior Data Analyst', description='0-1 years of experience.')
        self.assertEqual(evaluate(entry, criteria({'roles': 'data analyst', 'stage': 'Career changer', 'years': 0}))['verdict'], 'match')
        # Experienced people may still see entry-level roles; they rank lower and say why.
        overqualified = evaluate(entry, criteria({'roles': 'data analyst', 'stage': 'Experienced', 'years': 10}))
        self.assertFalse(overqualified['excluded']);self.assertIn('overqualified', ' '.join(overqualified['caveats']))

    def test_soft_preferences_rank_but_do_not_exclude(self):
        contract = job('Registered Nurse', employment_type='Contract', location='Detroit, MI')
        required = criteria({'roles': 'nurse', 'employment_types': ['Full-time']})
        soft = criteria({'roles': 'nurse', 'employment_types': ['Full-time'], 'soft': ['employment_types']})
        self.assertTrue(evaluate(contract, required)['excluded'])
        result = evaluate(contract, soft)
        self.assertFalse(result['excluded']);self.assertLess(result['score'], evaluate(job('Registered Nurse', employment_type='Full-time'), soft)['score'])

    def test_exclusions(self):
        self.assertTrue(evaluate(job('Engineer', company='Acme Staffing'), criteria({'exclude_companies': ['acme staffing']}))['excluded'])
        self.assertTrue(evaluate(job('Engineer', description='A crypto trading platform.'), criteria({'exclude_terms': ['crypto']}))['excluded'])
        self.assertFalse(evaluate(job('Engineer', company='Acmeville Health'), criteria({'exclude_companies': ['Acme']}))['excluded'])

    def test_search_overrides_are_tracked(self):
        c = criteria({'roles': 'nurse', 'location': 'Detroit, MI', 'modes': ['Remote']}, 'teacher', {'location': 'Boston, MA'})
        self.assertEqual((c['roles'], c['sources']['roles'], c['location'], c['sources']['location'], c['modes'], c['sources']['modes']),
                         ('teacher', 'search', 'Boston, MA', 'search', ['Remote'], 'profile'))
        c = criteria({'roles': 'Senior engineer', 'stage': 'Student'})
        self.assertTrue(c['notices'])

    def test_labeled_evaluation_has_no_regressions(self):
        import matching_eval
        before, after = matching_eval.main()
        self.assertEqual(len(after['unsuitable_admitted']), 0)
        self.assertEqual(len(after['unknown_claimed_confirmed']), 0)
        self.assertEqual(len(after['unknown_excluded']), 0)
        # Known limitation: no metro areas (Southfield is a Detroit suburb).
        self.assertEqual([(r['persona'], r['listing']) for r in after['suitable_excluded']], [('new_grad_rn', 'L19')])
        _, heldout = matching_eval.main('heldout')
        for key in ('unsuitable_admitted', 'suitable_excluded', 'unknown_excluded', 'unknown_claimed_confirmed'):
            self.assertEqual(heldout[key], [], key)


class ScopedSoftwareSearch(unittest.TestCase):
    def test_stated_level_is_independent_of_other_unknown_details(self):
        filters = {'levels': ['Entry-level'], 'confirmed_level': True, 'modes': ['Remote']}
        c = criteria({}, 'Software engineer', filters)
        junior = job('Junior Software Engineer')
        result = evaluate(junior, c)
        self.assertFalse(result['excluded'])
        self.assertEqual(result['verdict'], 'uncertain')  # Work arrangement remains unknown.
        for title in ('Fry Cook', 'Senior Software Engineer', 'Software Engineer Intern', 'Software Engineer'):
            self.assertTrue(evaluate(job(title), c)['excluded'], title)
        permissive = criteria({}, 'Software engineer', {**filters, 'confirmed_level': False})
        self.assertFalse(evaluate(job('Software Engineer'), permissive)['excluded'])

    def test_junior_title_never_confirms_graduation_year(self):
        junior = job('Junior Software Engineer', description='New graduates welcome.')
        filters = {'levels': ['Entry-level'], 'confirmed_level': True}
        profile = {'graduation_month': '2027-05'}
        self.assertFalse(evaluate(junior, criteria(profile, 'Software engineer', filters))['excluded'])
        self.assertTrue(evaluate(junior, criteria(profile, 'Software engineer', {**filters, 'timeline': 'confirmed'}))['excluded'])
        missing_date = criteria({}, 'Software engineer', {**filters, 'timeline': 'confirmed'})
        self.assertTrue(missing_date['notices'])
        self.assertTrue(evaluate(junior, missing_date)['excluded'])


if __name__ == '__main__':
    unittest.main(verbosity=1)
