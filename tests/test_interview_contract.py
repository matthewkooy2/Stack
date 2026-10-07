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
        self.turn = {'question':flow.QUESTIONS[1], 'focus_quote':'SQL query plan',
            'strength':flow.STRENGTHS[0], 'improvement':flow.IMPROVEMENTS[1],
            'evidence':[{'source':'answer:1', 'quote':'SQL query plan', 'claim':'Reviewed answer excerpt'}]}

    def test_supported_schema_and_valid_turn(self):
        supported = {'type','properties','required','additionalProperties','items','enum','minimum','maximum','maxItems'}
        def visit(schema):
            self.assertTrue(set(schema) <= supported)
            for child in schema.get('properties',{}).values(): visit(child)
            if 'items' in schema: visit(schema['items'])
        visit(flow.TURN_SCHEMA);visit(flow.COACH_SCHEMA)
        flow.validate('interview_turn',self.turn,self.context)
        question=flow.followup(self.turn,self.data)
        self.assertIn(self.turn['focus_quote'],question)
        self.assertIn(self.data['job']['description'],question)

    def test_fabricated_prose_with_real_citation_is_rejected_in_every_field(self):
        for field in ('strength','improvement','question'):
            with self.subTest(field=field):
                artifact=copy.deepcopy(self.turn)
                artifact[field]='You were CEO and grew revenue by ten million dollars.'
                with self.assertRaises(ValueError): flow.validate('interview_turn',artifact,self.context)
        self.data['turns'].append({'answer':'I explained the write overhead.'})
        context=flow.context(self.data,2,True)
        coach={'summary':flow.SUMMARY,'strengths':[{'criterion':'Verification','source':'answer:1','quote':'SQL query plan'}],
            'rubric':[{'criterion':criterion,'score':2,'feedback':flow.IMPROVEMENTS[i%3]} for i,criterion in enumerate(flow.CRITERIA)],
            'next_exercises':[flow.EXERCISES[0]],'followup_questions':list(flow.QUESTIONS[:2]),
            'evidence':[self.turn['evidence'][0],{'source':'answer:2','quote':'write overhead','claim':'Reviewed answer excerpt'}]}
        flow.validate('interview_coach',coach,context)
        for field in ('summary','strengths','next_exercises','followup_questions','rubric','evidence'):
            with self.subTest(field=field):
                artifact=copy.deepcopy(coach)
                if field=='summary': artifact[field]='You generated millions in revenue.'
                elif field=='rubric': artifact[field][0]['feedback']='Your CEO experience is impressive.'
                elif field=='strengths': artifact[field][0]['quote']='I was CEO.'
                elif field=='evidence': artifact[field][0]['claim']='You were CEO.'
                else: artifact[field][0]='Discuss your CEO experience.'
                with self.assertRaises(ValueError): flow.validate('interview_coach',artifact,context)
        for field,value in (('rubric',coach['rubric'][:1]),('followup_questions',[flow.QUESTIONS[0]]*2)):
            with self.assertRaises(ValueError): flow.validate('interview_coach',{**coach,field:value},context)

    def test_bounds_and_foreign_or_empty_quotes(self):
        for change in ({'focus_quote':''},{'focus_quote':'x'*1501},{'evidence':[]},
                       {'evidence':[{'source':'listing','quote':'SQL','claim':'Reviewed answer excerpt'}]},
                       {'evidence':[{'source':'answer:1','quote':'Invented result','claim':'Reviewed answer excerpt'}]}):
            with self.subTest(change=change):
                with self.assertRaises(ValueError): flow.validate('interview_turn',{**self.turn,**change},self.context)

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

if __name__=='__main__': unittest.main(verbosity=2)
