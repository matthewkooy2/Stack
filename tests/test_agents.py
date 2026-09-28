"""Offline agent contracts; no paid calls, submissions, or external messages."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from agents import contracts, google, prep, sandbox
from agents.browser import field_key


class Contracts(unittest.TestCase):
    def policy(self):
        return contracts.validate_policy({'enabled': True, 'expires_at': time.time()+3600,
            'actions': ['submit_application', 'model'], 'domains': ['jobs.lever.co'], 'daily_limits': {'submit_application': 2}})

    def test_disabled_by_default(self):
        with self.assertRaises(ValueError):
            contracts.authorize(contracts.default_policy(), 'model')

    def test_exact_domain_and_expiry(self):
        p=self.policy();contracts.authorize(p,'submit_application','https://jobs.lever.co/example')
        for url in ('https://jobs.lever.co.attacker.test/job','https://evil.test/job'):
            with self.assertRaises(ValueError):contracts.authorize(p,'submit_application',url)
        with self.assertRaises(ValueError):contracts.authorize(p,'model',now=time.time()+7200)

    def test_wildcards_and_invalid_limits(self):
        for changes in ({'domains':['*']},{'daily_limits':{'send_email':-1}},{'expires_at':float('nan')},{'followup_limit':100}):
            with self.assertRaises(ValueError):contracts.validate_policy({**self.policy(),**changes})

    def test_unconfirmed_facts_not_answers(self):
        rows=contracts.validate_facts([{'key':'phone','value':'123','verified':False},{'key':'name','value':'Alice','verified':True}])
        self.assertEqual(contracts.answers(rows),{'name':'Alice'})

    def test_source_quote_validation(self):
        contracts.validate_evidence([{'source':'a','quote':'built systems'}],{'a':'I built systems.'})
        with self.assertRaises(ValueError):contracts.validate_evidence([{'source':'a','quote':'managed 50 people'}],{'a':'I built systems.'})

    def test_budget_unset(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ,{'STACK_AGENT_CONFIG':d+'/missing.json'}):
            with self.assertRaises(ValueError):contracts.reserve_cents({})

    def test_budget_reservation_counts_payload(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'config.json';path.write_text(json.dumps({'monthly_cents':100,'user_monthly_cents':50,'model':'test','input_cents_per_million':100,'output_cents_per_million':500,'max_output_tokens':500}))
            with patch.dict(os.environ,{'STACK_AGENT_CONFIG':str(path)}):
                self.assertGreater(contracts.reserve_cents({'a':'x'*50000}),contracts.reserve_cents({}))

    def test_adapter_destinations(self):
        self.assertEqual(contracts.adapter_for('https://jobs.lever.co/acme/id'),'lever')
        self.assertEqual(contracts.adapter_for('https://jobs.lever.co.bad.test/acme/id'),'')
        self.assertEqual(contracts.adapter_for('http://jobs.lever.co/acme/id'),'')

    def test_form_unknown_answers_never_guessed(self):
        self.assertEqual(field_key({'label':'Email *'}),'email')
        key=field_key({'label':'Are you authorized to work in Canada?'})
        self.assertTrue(key.startswith('answer:'));self.assertNotEqual(key,'work_authorization')

    def test_two_sum_checks_indices_and_alternative_solutions(self):
        good=prep.evaluate_outputs('two-sum',[[1,0],[0,1],[],[0,2],[]]);self.assertEqual(good['passed'],5)
        bad=prep.evaluate_outputs('two-sum',[[0,0],[True,1],[],[0,2],[]]);self.assertEqual(bad['passed'],3)

    def test_bool_is_not_arbitrary_truthy(self):
        result=prep.evaluate_outputs('brackets',[1,False,True,False,False]);self.assertEqual(result['passed'],4)

    def test_public_problems_hide_tests(self):
        self.assertTrue(all('tests' not in p for p in prep.catalog()))
        self.assertEqual(prep.problem('two-sum')['languages'],['python','cpp'])

    def test_sandbox_requires_pinned_image_and_isolation(self):
        with patch.dict(os.environ,{'STACK_SANDBOX_IMAGE':''}):
            with self.assertRaises(ValueError):sandbox.container_command('/tmp/task','name')
        with patch.dict(os.environ,{'STACK_SANDBOX_IMAGE':'stack@sha256:'+'a'*64}):
            args=sandbox.container_command('/tmp/task','name')
            for flag in ('--runtime=runsc','--network=none','--read-only','--user=65534:65534','--cap-drop=ALL'):
                self.assertIn(flag,args)
            self.assertNotIn('OPENAI_API_KEY',' '.join(args));self.assertNotIn('/var/run/docker.sock',' '.join(args))

    def test_google_ambiguous_company_does_not_update(self):
        msg={'id':'m1','payload':{'headers':[{'name':'Subject','value':'Acme: thank you for applying'}]},'internalDate':'1234'}
        apps=[{'id':'a1','job':{'company':'Acme','title':'Engineer'}},{'id':'a2','job':{'company':'Acme','title':'Designer'}}]
        self.assertTrue(google.classify(msg,apps)['ambiguous'])

    def test_google_clear_confirmation(self):
        msg={'id':'m1','payload':{'headers':[{'name':'Subject','value':'Acme Engineer: thank you for applying'}]},'internalDate':'1234'}
        result=google.classify(msg,[{'id':'a1','job':{'company':'Acme','title':'Engineer'}}])
        self.assertFalse(result['ambiguous']);self.assertEqual(result['status'],'Submitted')

    def test_contact_requires_valid_recipient(self):
        with self.assertRaises(ValueError):contracts.validate_contact({'name':'A','email':'A\nB@example.com'})

    def test_calendar_only_accepts_complete_utc_invites(self):
        import base64
        def payload(text):return {'mimeType':'text/calendar','body':{'data':base64.urlsafe_b64encode(text.encode()).decode()}}
        text='UID:test\nDTSTART:20261002T160000Z\nDTEND:20261002T170000Z\nSUMMARY:Interview'
        self.assertEqual(google.calendar_attachment(payload(text))['start']['dateTime'],'2026-10-02T16:00:00+00:00')
        self.assertEqual(google.calendar_attachment(payload(text.replace('DTSTART:', 'DTSTART;TZID=America/Detroit:'))),{})

    def test_initial_mail_sync_uses_cursor_before_scan(self):
        paths=[]
        def request(tokens,path,body=None):
            paths.append(path)
            if path=='profile':return {'historyId':'100'}
            if path.startswith('messages?'):return {'messages':[]}
            raise AssertionError(path)
        with patch.object(google,'request',request):
            result=google.synchronize({}, {}, [{'job':{'company':'Acme'}}], [])
        self.assertEqual(result['checkpoint']['history_id'],'100')
        self.assertEqual(paths[0],'profile')

    def test_gateway_hides_operator_and_graph_routes(self):
        from agents.gateway import PERSONAL
        self.assertNotIn('agent_claim',PERSONAL)
        self.assertNotIn('agent_invite',PERSONAL)
        self.assertNotIn('agent_worker_connection',PERSONAL)

    def test_output_flood_is_terminated(self):
        import sys
        with self.assertRaisesRegex(ValueError,'output limit'):
            sandbox.bounded_process([sys.executable,'-c','print("x"*10000)'],limit=100)


if __name__=='__main__':unittest.main(verbosity=2)
