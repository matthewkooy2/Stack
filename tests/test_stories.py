"""Fixed fictional histories and hostile model contract checks, no inference."""
import copy
import json
from pathlib import Path
import unittest
from agents.stories import validate, corrected, missing, empty, model_source

FIXTURE = json.loads((Path(__file__).parent/'fixtures/behavioral-stories.json').read_text())

def proposal(event, key='fixture'):
    return {'fields': {k: {'source': key, 'quote': v} for k,v in event['fields'].items()},
            'topics': event['topics'], 'evidence': []}

class Stories(unittest.TestCase):
    def test_fixed_histories_ground_every_displayed_claim(self):
        for event in FIXTURE['events']:
            source={'key':'fixture','text':event['text']}
            value=validate(proposal(event),source)
            for claim in value['evidence']:
                self.assertIn(claim['quote'],source['text'])
            if event['id'] in ('sparse','disagreement'):
                self.assertIn('result',[q['field'] for q in missing(value)])
        self.assertNotEqual(FIXTURE['events'][0]['fields']['personal'],FIXTURE['events'][0]['fields']['team'])

    def test_rejects_unsupported_claims_sources_and_actor_promotions(self):
        event=FIXTURE['events'][0];source={'key':'fixture','text':event['text']}
        for field,quote,key in [('result','Reduced errors by 95%.','fixture'),
                                ('personal',event['fields']['team'],'fixture'),
                                ('team',event['fields']['personal'],'fixture'),
                                ('action',event['fields']['action'],'other-account')]:
            value=proposal(event);value['fields'][field]={'quote':quote,'source':key}
            with self.assertRaises(ValueError):validate(value,source)
        value=proposal(event);value['fields']['result']={'source':'fixture','quote':'   '}
        with self.assertRaises(ValueError):validate(value,source)
        value=proposal(event);value['fields']['invented']='anything'
        with self.assertRaises(ValueError):validate(value,source)

    def test_user_corrections_have_explicit_provenance_and_do_not_mutate_original(self):
        original=empty({'key':'fixture'})
        saved=corrected(original,{'result':'Outcome is still unknown.','personal':'I only wrote tests.'},1)
        self.assertEqual(original['fields']['result']['quote'],'')
        self.assertEqual(saved['fields']['result']['source'],'user-confirmed:1:result')
        self.assertIn('result',[q['field'] for q in missing(saved)])
        for changes in ({'outcome':'x'},{'result':123},{'result':' '*3},{}):
            with self.assertRaises(ValueError):corrected(saved,changes,2)

    def test_team_possessives_unknown_outcomes_and_unselected_text(self):
        source={'key':'fixture','text':'My team shipped the change. The release has not happened, so I do not know the outcome.',
                'full_text':'Other unrelated event.', 'original_transcript':'Obsolete uncorrected claim.'}
        value=empty(source);value['fields']['personal']['quote']='My team shipped the change.'
        with self.assertRaises(ValueError):validate(value,source)
        value['fields']['personal']['quote']='';value['fields']['team']['quote']='My team shipped the change.'
        value['fields']['result']['quote']='The release has not happened, so I do not know the outcome.'
        value=validate(value,source)
        self.assertIn('result',[q['field'] for q in missing(value)])
        self.assertEqual(model_source(source),{'key':'fixture','text':source['text']})
        teammates={'key':'fixture','text':'Teammates reviewed the test and shipped the change.'}
        value=empty(teammates);value['fields']['team']['quote']=teammates['text']
        self.assertEqual(validate(value,teammates)['fields']['team']['quote'],teammates['text'])

if __name__=='__main__':unittest.main()
