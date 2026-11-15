"""Fast grounding and transcript invariants, independent of the Jac runtime."""
import copy
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'agents' / 'interview.py'
if not path.exists():
    path = Path(__file__).with_name('interview.py')
spec = importlib.util.spec_from_file_location('interview_contract', path)
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.data = flow.create({'description':'Build SQL tools and verify tradeoffs'}, [], 'a', '')
        self.data['turns'] = [{'answer':'I inspected a SQL query plan.', 'question':self.data['questions'][0]}]
        self.context = flow.context(self.data, 1)
    def test_unconventional_text_applies_and_stale_revisions_do_not(self):
        for text in ('plain prose', '{broken', '<script>alert(1)</script>', 'unsupported claims', 'partial:'):
            artifact={'text':text,'summary':text}
            for step in flow.STEPS:
                updated=flow.apply(self.data,1,step,artifact,self.context)
                self.assertEqual(updated['coaching'] if step=='interview_coach' else updated['analysis']['1'],artifact)
                with self.assertRaises(ValueError): flow.apply(self.data,2,step,artifact,self.context)
        question=flow.followup({'text':'arbitrary output'},self.data)
        self.assertIn(self.data['turns'][0]['answer'],question)

    def test_correction_drops_unanswered_generation_preserves_history_and_input(self):
        followup={'kind':'followup','question':'Old generated question'}
        self.data['questions'].insert(1,followup)
        corrected=flow.correct(self.data,0,'I read a query plan; the result is unknown.')
        self.assertEqual(corrected['questions'][1]['kind'],'project')
        self.assertEqual(self.data['turns'][0]['answer'],'I inspected a SQL query plan.')
        self.data['turns'].append({'answer':'I explained the overhead.','question':followup})
        self.data['questions'].insert(2,copy.deepcopy(followup))
        corrected=flow.correct(self.data,0,'Correction')
        self.assertEqual(corrected['questions'][1],followup)
        self.assertEqual(corrected['turns'][1]['question'],followup)
        self.assertTrue(all(q['kind']!='followup' for q in corrected['questions'][2:]))
        self.assertFalse(corrected['analysis']);self.assertFalse(corrected['coaching']);self.assertFalse(corrected['pending'])

    def test_old_client_display_aliases_keep_complete_raw_text_without_mutating_storage(self):
        for text in ('plain prose', '{broken', '<script>alert(1)</script>', 'unsupported claims', 'partial:'):
            self.data['analysis']={'1':{'text':text,'summary':text}}
            self.data['coaching']={'text':text,'summary':text}
            presented=flow.client_data(self.data)
            self.assertEqual(presented['analysis']['1']['improvement'],text)
            self.assertEqual(presented['analysis']['1']['focus_quote'],'')
            final=presented['coaching']
            self.assertEqual(final['summary'],text)
            self.assertEqual(final['rubric'],{})
            for key in ('strengths','next_exercises','followup_questions','evidence'):self.assertEqual(final[key],[])
            self.assertEqual(self.data['analysis']['1'],{'text':text,'summary':text})
            self.assertEqual(self.data['coaching'],{'text':text,'summary':text})

RESUME = 'resume.r1.'
DETAILS = [{'key':RESUME+'profile.name','value':'Sam Synthetic','verified':True,'resume_id':'r1'},
           {'key':RESUME+'profile.email','value':'sam@example.com','verified':True,'resume_id':'r1'},
           {'key':RESUME+'educations.0','value':'School: State University','verified':True,'resume_id':'r1'},
           {'key':RESUME+'workExperiences.0','value':'Company: Synthetic Labs\nJob title: Data Intern\nDescriptions: Built SQL reports','verified':True,'resume_id':'r1'},
           {'key':RESUME+'projects.0','value':'Project: Course Tracker\nDescriptions: Indexed a SQLite database','verified':True,'resume_id':'r1'},
           {'key':'resume.r2.projects.0','value':'Project: Other resume','verified':True,'resume_id':'r2'}]
LISTING = {'title':'Data Engineer','description':'Build SQL pipelines in Python. Design tests for data quality. Collaborate with analysts and communicate tradeoffs.'}

class MvpQuestionTests(unittest.TestCase):
    """#133: behavioral, project and experience questions from the saved job and the selected resume."""
    def test_questions_cover_experience_project_and_behavioral_from_job_and_resume(self):
        data = flow.create(LISTING, DETAILS, 'a', 'r1')
        self.assertEqual([q['kind'] for q in data['questions']], ['experience', 'project', 'behavioral'])
        experience, project, behavioral = data['questions']
        self.assertIn('Data Intern at Synthetic Labs', experience['question'])
        self.assertIn('Build SQL pipelines in Python', experience['question'])
        self.assertEqual([e['source'] for e in experience['evidence']], ['listing', 'fact:'+RESUME+'workExperiences.0'])
        self.assertIn('"Course Tracker"', project['question'])
        self.assertIn('Design tests for data quality', project['question'])
        self.assertIn('Collaborate with analysts', behavioral['question'])
        # Profile and education facts and another resume never become interview questions.
        text = ' '.join(q['question'] for q in data['questions'])
        for absent in ('Sam Synthetic', 'sam@example.com', 'State University', 'Other resume'):
            self.assertNotIn(absent, text)
        self.assertNotIn('resume.r2.projects.0', [f['key'] for f in data['facts']])

    def test_listing_only_and_reviewed_records_fallbacks(self):
        data = flow.create(LISTING, [], 'a', '')
        self.assertEqual([q['kind'] for q in data['questions']], ['experience', 'project', 'behavioral'])
        self.assertTrue(all(e['source'] == 'listing' for q in data['questions'] for e in q['evidence']))
        records = [{'id':'r0','kind':'title','text':'Sam Synthetic'},{'id':'r1','kind':'heading','text':'Experience'},
                   {'id':'r2','kind':'paragraph','text':'Synthetic Labs | Data Intern | 2025'},{'id':'r3','kind':'bullet','text':'Built SQL reports'},
                   {'id':'r4','kind':'heading','text':'Projects'},{'id':'r5','kind':'paragraph','text':'Course Tracker'},
                   {'id':'r6','kind':'bullet','text':'Indexed a SQLite database'}]
        data = flow.create(LISTING, [], 'a', 'r9', records)
        self.assertIn('Synthetic Labs | Data Intern | 2025', data['questions'][0]['question'])
        self.assertIn('Course Tracker', data['questions'][1]['question'])
        self.assertEqual(data['facts'][0]['value'], 'Synthetic Labs | Data Intern | 2025\nBuilt SQL reports')
        self.assertNotIn('Sam Synthetic', ' '.join(f['value'] for f in data['facts']))
        # Confirmed facts take precedence over records.
        self.assertIn('Data Intern at Synthetic Labs', flow.create(LISTING, DETAILS, 'a', 'r1', records)['questions'][0]['question'])

class MvpSessionTests(unittest.TestCase):
    def setUp(self):
        self.data = flow.create(LISTING, DETAILS, 'a', 'r1')
        self.data['turns'] = [{'question':q, 'answer':'Answer %d' % (i + 1)} for i, q in enumerate(self.data['questions'][:2])]
        self.data['analysis'] = {'1': {'text':'one'}, '2': {'text':'two'}}

    def test_retry_coaches_the_retried_answer_and_keeps_other_results(self):
        corrected = flow.correct(self.data, 0, 'Answer 1, retried')
        self.assertEqual(corrected['turns'][0]['previous'], ['Answer 1'])
        self.assertEqual(corrected['analysis'], {'2': {'text':'two'}})
        self.assertEqual(flow.target(corrected), 0)
        context = flow.context(corrected, 3, False, 0)
        self.assertEqual([t['answer'] for t in context['interview']['turns']], ['Answer 1, retried'])
        self.assertEqual(context['interview']['answer_sources'], {'answer:1': 'Answer 1, retried'})
        applied = flow.apply(corrected, 3, 'interview_turn', {'text':'new'}, context)
        self.assertEqual(applied['analysis'], {'1': {'text':'new'}, '2': {'text':'two'}})
        # A context queued before this change (no turn) still targets the latest answer.
        legacy = {**context, 'interview': {k: v for k, v in context['interview'].items() if k != 'turn'}}
        self.assertEqual(flow.apply(corrected, 3, 'interview_turn', {'text':'x'}, legacy)['analysis']['2'], {'text':'x'})

    def test_shortened_final_context_has_only_given_answers_and_empty_is_refused(self):
        self.data['turns'] = self.data['turns'][:1]
        context = flow.context(self.data, 1, True)
        self.assertEqual(len(context['interview']['turns']), 1)
        self.assertEqual(context['interview']['unanswered'], 2)
        self.assertEqual(list(context['interview']['answer_sources']), ['answer:1'])
        self.data['turns'] = []
        with self.assertRaises(ValueError): flow.apply(self.data, 1, 'interview_coach', {'text':'invented'}, {'session_revision':1})

    def test_structured_aliases_keep_structured_fields(self):
        item = {'verdict':'Good start.', 'scores':[{'name':'Specificity','score':2,'why':'w'}], 'strengths':['Named the tool.'],
                'weaknesses':['No result.'], 'work_on':'State the result.', 'follow_ups':['What changed?'], 'example':'',
                'summary':'Good start.', 'text':'Good start.', 'format':'structured'}
        self.data['analysis'] = {'1': dict(item)}
        self.data['coaching'] = dict(item)
        out = flow.client_data(self.data)
        self.assertEqual((out['analysis']['1']['strength'], out['analysis']['1']['improvement']), ('Named the tool.', 'State the result.'))
        self.assertEqual(out['coaching']['strengths'], ['Named the tool.'])
        self.assertEqual(out['coaching']['summary'], 'Good start.')
        self.assertEqual(out['coaching']['followup_questions'], ['What changed?'])
        self.assertEqual(self.data['coaching'], item)

if __name__=='__main__': unittest.main(verbosity=2)
