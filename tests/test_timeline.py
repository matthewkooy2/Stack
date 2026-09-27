"""Safety-sensitive timeline classification: unsupported wording must stay uncertain."""
import unittest
from datetime import date
from discovery.timeline import analyze, assess, timeline_includes, validate_month

P={'graduation_month':'2027-05','available_from':'2027-06'}
def listing(text, **extras):
    j={'title':'Software Engineer','description':text,**extras};j['timeline_analysis']=analyze(j);return j

def result(text, **extras):return assess(listing(text,**extras),P)

class TimelineTests(unittest.TestCase):
 def test_matching_window_with_evidence(self):
    text='Must be graduating between December 2026 and June 2027.'
    r=result(text);self.assertEqual(r['status'],'match');self.assertEqual(r['evidence'][0]['quote'],text)
 def test_explicit_mismatch(self):
    self.assertEqual(result('Graduation date between January 2026 and December 2026.')['status'],'incompatible')
 def test_year_window(self):
    self.assertEqual(result('Candidates graduating in 2027.')['status'],'match')
    self.assertEqual(result('Candidates graduating in 2026.')['status'],'incompatible')
 def test_iso_window(self):
    self.assertEqual(result('Graduation date between 2026-12 and 2027-06.')['status'],'match')
 def test_title_is_not_eligibility(self):
    self.assertEqual(result('Bachelor degree required.',title='2027 New Grad Engineer')['status'],'unclear')
 def test_degree_by_start_not_already_graduated(self):
    self.assertEqual(result('Bachelor degree required by start date.')['status'],'unclear')
    self.assertEqual(result('Must have graduated between December 2026 and June 2027.')['status'],'match')
 def test_explicit_already_graduated(self):
    future=f'{date.today().year+2}-05'
    r=assess(listing('Applicants must have already graduated.'),{'graduation_month':future})
    self.assertEqual(r['status'],'incompatible')
 def test_alternatives_and_negation(self):
    for text in ('Graduating in 2026 or 2027.', 'Graduating in 2026 preferred.', 'Graduating in 2027 is not required.', 'Must have already graduated or have equivalent experience.'):
     self.assertEqual(result(text)['status'],'unclear',text)
 def test_partial_content(self):
    self.assertEqual(result('Graduating in 2026.',snippet=True)['status'],'unclear')
 def test_conflicting_windows(self):
    self.assertEqual(result('Graduating in 2026. Graduating in 2027.')['status'],'unclear')
 def test_shared_year_and_unsupported_boundaries_stay_unclear(self):
    for text in ('Graduating between May and August 2027.', 'Graduating before May 2027.', 'Graduating by May 15, 2027.', 'Graduating in Spring 2027.'):
     self.assertEqual(result(text)['status'],'unclear',text)
 def test_start_date(self):
    self.assertEqual(result('Graduating in 2027. Start date: January 2027.')['status'],'incompatible')
    self.assertEqual(result('Graduating in 2027. Start date: June 2027.')['status'],'match')
    self.assertEqual(assess(listing('Graduating in 2027. Start date: June 2027.'),{'graduation_month':'2027-05'})['status'],'unclear')
 def test_internship_availability_and_return_to_school(self):
    self.assertEqual(result('Graduating in 2027. Start date: January 2027.',title='Software Intern')['status'],'match')
    self.assertEqual(result('Must return to school after the internship.',title='Software Intern')['status'],'unclear')
    self.assertEqual(result('Must return to school after the internship. Internship ends August 2027.',title='Software Intern')['status'],'incompatible')
 def test_program_year_is_not_graduation_year(self):
    self.assertEqual(result('New graduates welcome in 2027.')['status'],'unclear')
    self.assertEqual(result('Our graduate program was established in 2026.')['status'],'unclear')
    self.assertEqual(result('Graduating in 2027. Start date: 2027.')['status'],'unclear')
 def test_current_enrollment_does_not_establish_cohort(self):
    self.assertEqual(result('Must be currently enrolled in university.')['status'],'unclear')
 def test_no_profile_and_filters(self):
    r=assess(listing('Graduating in 2027.'),{})
    self.assertEqual(r['status'],'unset');self.assertTrue(timeline_includes(r,'compatible'));self.assertFalse(timeline_includes(r,'confirmed'))
    r=result('Graduating in 2026.');self.assertFalse(timeline_includes(r,'compatible'));self.assertTrue(timeline_includes(r,'all'))
 def test_content_fingerprint_and_reuse(self):
    j=listing('Graduating in 2027.');self.assertIs(analyze(j),j['timeline_analysis'])
    j['description']='Graduating in 2026.';new=analyze(j)
    self.assertNotEqual(new['fingerprint'],j['timeline_analysis']['fingerprint'])
 def test_encoded_html_and_unrelated_degree_alternatives(self):
    j=listing('&lt;li&gt;Currently enrolled in Computer Science or a related field with an expected graduation date&lt;strong&gt; between December 2027 and November 2028&lt;/strong&gt;.&lt;/li&gt;')
    self.assertEqual(assess(j,P)['status'],'incompatible')
    self.assertNotIn('<li>',j['timeline_analysis']['evidence'][0]['quote'])
 def test_validation(self):
    for invalid in ('May 2027','2027-13','27-05',True):
     with self.assertRaises(ValueError):validate_month(invalid)
    self.assertEqual(validate_month('2027-05'),'2027-05');self.assertEqual(validate_month(''),'')

if __name__=='__main__':unittest.main()
