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
        self.assertEqual(corrected['questions'][1]['kind'],'experience')
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

if __name__=='__main__': unittest.main(verbosity=2)
