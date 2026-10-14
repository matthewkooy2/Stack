"""Synthetic hosted-ATS fixtures only; no employer contact, credentials or submission."""
import json
import base64
import unittest
from agents import autofill


URLS = {
    'greenhouse':'https://boards.greenhouse.io/fixture/jobs/123',
    'lever':'https://jobs.lever.co/fixture/123/apply',
    'ashby':'https://jobs.ashbyhq.com/fixture/123/application',
    'workday':'https://fixture.wd5.myworkdayjobs.com/en-US/Careers/job/Test/Fixture_123/apply',
}
FIXTURES = {
    'greenhouse': '<form id="application_form"><label>First Name *<input id="first_name"></label><label>Last Name<input id="last_name"></label><label>Email<input id="email" type="email"></label></form>',
    'lever': '<form class="application-form"><label>Full name<input name="name"></label><label>Email<input name="email" type="email"></label><label>LinkedIn URL<input name="urls[linkedin]"></label></form>',
    'ashby': '<form><label>Full Name<input name="_systemfield_name"></label><label>Email<input name="_systemfield_email" type="email"></label><label>Phone<input name="_systemfield_phone"></label></form>',
    'workday': '<main><div data-automation-id="formField"><label>First Name<input data-automation-id="legalNameSection_firstName"></label></div><div data-automation-id="formField"><label>Last Name<input data-automation-id="legalNameSection_lastName"></label></div><div data-automation-id="formField"><label>Email Address<input type="email" data-automation-id="email"></label></div></main>',
}
VALUES = dict(first_name='Synthetic',last_name='Candidate',name='Synthetic Candidate',email='synthetic@example.test',phone='5550100000',linkedin='https://example.test/profile')


def facts(values=VALUES):
    return [dict(key=k,value=v,verified=True) for k,v in values.items()]


class Contracts(unittest.TestCase):
    def test_hosted_urls_and_tenant_boundaries(self):
        for family,url in URLS.items():
            target=autofill.application_url(url)
            self.assertEqual(target['family'],family)
            self.assertTrue(autofill.request_allowed(url,True,target))
            for blocked in ('https://127.0.0.1/x','https://user:secret@'+target['host']+'/x',
                            'https://'+target['host']+'.evil.test/x','http://'+target['host']+'/x'):
                self.assertFalse(autofill.request_allowed(blocked,False,target))
        target=autofill.application_url(URLS['workday'])
        self.assertFalse(autofill.request_allowed('https://other.wd5.myworkdayjobs.com/job/x',True,target))
        self.assertFalse(autofill.request_allowed('https://other.wd5.myworkdayjobs.com/job/x',False,target))
        for url in ('https://company.test/jobs/a','https://wd5.myworkdayjobs.com/job/a','https://fixture.wd5.myworkdayjobs.com/login',
                    'https://jobs.lever.co:8443/a','https://jobs.lever.co/','https://jobs.ashbyhq.com.evil.test/a'):
            with self.assertRaises(ValueError):autofill.application_url(url)

    def test_only_confirmed_unambiguous_saved_values(self):
        self.assertEqual(autofill.saved_values([dict(key='email',value='private',verified=False)]),{})
        self.assertEqual(autofill.saved_values(facts({'email':'a'})+facts({'email':'b'})),{})

    def test_authorization_sponsorship_and_exact_questions_stay_distinct(self):
        field=dict(label='Are you legally authorized to work in the United States?',kind='select',disabled=False)
        self.assertEqual(autofill.match_field(field,'greenhouse',{'work_authorization':'Yes','sponsorship':'No'}),'work_authorization')
        field['label']='Do you require sponsorship?'
        self.assertEqual(autofill.match_field(field,'greenhouse',{'work_authorization':'Yes','sponsorship':'No'}),'sponsorship')
        field.update(label='Are you authorized to work in Canada?',autocomplete='email',id='email')
        self.assertIsNone(autofill.match_field(field,'greenhouse',VALUES))
        saved={autofill.answer_key(field['label']):'No'}
        self.assertEqual(autofill.match_field(field,'greenhouse',saved),autofill.answer_key(field['label']))

    def test_ambiguous_options_and_consents_remain_manual(self):
        self.assertIsNone(autofill.selected_option([dict(value='a',label='Yes'),dict(value='b',label='Yes')],'Yes'))
        self.assertIsNone(autofill.selected_option([dict(value='a',label='Yes, with conditions')],'Yes'))
        for label in ('Password','Verification code','I agree to terms','Electronic signature'):
            field=dict(label=label,kind='text',disabled=False)
            self.assertIsNone(autofill.match_field(field,'lever',{autofill.answer_key(label):'saved'}))


class Pool:
    def __init__(self,browser):
        self.browser=browser;self.sessions={};self.guard_calls=0;self.operation_stage='operation'
    def guard(self):self.guard_calls+=1
    def publish(self,owner,run):return {}
    def close(self):
        for session in self.sessions.values():session['context'].close()


class FormDOM(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from playwright.sync_api import sync_playwright
        cls.driver=sync_playwright().start();cls.browser=cls.driver.chromium.launch(headless=True)
    @classmethod
    def tearDownClass(cls):cls.browser.close();cls.driver.stop()

    def fixture(self,family,html):
        pool=Pool(self.browser)
        context=self.browser.new_context()
        context.route('**/*',lambda route:route.fulfill(content_type='text/html',body=html))
        page=context.new_page();page.goto(URLS[family])
        pool.sessions[('owner','run')]=dict(page=page,context=context,adapter='autofill',url=URLS[family],target=autofill.application_url(URLS[family]),touched=0)
        self.addCleanup(pool.close)
        return pool,page

    def fill(self,pool,family,values=VALUES,owner='owner',run='run'):
        return autofill.fill_page(pool,owner,run,dict(application_url=URLS[family],facts=facts(values)))

    def test_four_ats_visible_text_variants_fill_and_never_submit(self):
        for family,html in FIXTURES.items():
            with self.subTest(family=family):
                pool,page=self.fixture(family,html+'<script>window.sent=0;document.addEventListener("submit",e=>{e.preventDefault();sent++})</script>')
                result=self.fill(pool,family)
                self.assertEqual(result['artifact']['filled'],3)
                self.assertTrue(result['needs_input']);self.assertEqual(page.evaluate('sent'),0)
                self.assertNotIn('synthetic@example.test',json.dumps(result))

    def test_existing_values_uploads_custom_widgets_and_unknown_answers(self):
        html='''<form><label>Email<input type=email value="existing@example.test"></label>
          <label>Phone<input></label><label>Resume<input type=file></label>
          <label>Why this role?<textarea required></textarea></label>
          <label>Country<input role=combobox></label><label>I agree to terms<input type=checkbox></label></form>'''
        pool,page=self.fixture('workday',html);result=self.fill(pool,'workday')
        self.assertEqual(page.locator('input[type=email]').input_value(),'existing@example.test')
        self.assertEqual(result['artifact']['filled'],1)
        self.assertIn(dict(key=autofill.answer_key('Why this role?'),label='Why this role?'),result['requests'])
        self.assertEqual(page.locator('input[type=file]').evaluate('(e)=>e.files.length'),0)
        self.assertFalse(page.locator('input[type=checkbox]').is_checked())

    def test_exact_saved_text_and_native_dropdown_values(self):
        html='''<form><label>Why this role?<textarea></textarea></label><label>Do you require sponsorship?
           <select><option value="">Choose</option><option value="y">Yes</option><option value="n">No</option></select></label></form>'''
        pool,page=self.fixture('greenhouse',html)
        result=self.fill(pool,'greenhouse',{autofill.answer_key('Why this role?'):'My synthetic answer','sponsorship':'No'})
        self.assertEqual(result['artifact']['filled'],2)
        self.assertEqual(page.locator('textarea').input_value(),'My synthetic answer')
        self.assertEqual(page.locator('select').input_value(),'n')

    def test_dependent_dropdown_options_cannot_reverse_saved_answer(self):
        html='''<form><label>Email<input id=email type=email oninput="document.querySelector('#s option[value=n]').textContent='Yes'"></label>
          <label for=s>Sponsorship</label><select id=s><option value="">Choose</option><option value=n>No</option></select></form>'''
        pool,page=self.fixture('greenhouse',html)
        result=self.fill(pool,'greenhouse',{'email':'fixture@example.test','sponsorship':'No'})
        self.assertEqual(page.locator('select').input_value(),'')
        self.assertEqual(result['artifact']['filled'],1)

    def test_later_fields_clearing_earlier_values_are_reported_unverified(self):
        pool,page=self.fixture('lever','''<form><label>Email<input id=email></label><label>Phone
            <input oninput="document.querySelector('#email').value=''"></label></form>''')
        result=self.fill(pool,'lever')
        self.assertEqual(result['artifact']['fields'][0]['status'],'unverified')
        self.assertEqual(result['artifact']['filled'],1)

    def test_login_appearing_mid_pass_stops_further_filling(self):
        pool,page=self.fixture('lever','''<form><label>Full Name<input oninput="document.querySelector('#otp').type='password'"></label>
            <input id=otp type=hidden><label>Email<input></label></form>''')
        result=self.fill(pool,'lever')
        self.assertEqual(page.locator('input').nth(2).input_value(),'')
        self.assertIn('Sign in',result['message'])

    def test_later_field_identity_mutation_is_not_reported_filled(self):
        pool,page=self.fixture('lever','''<form><label for=email id=label>Email</label><input id=email>
            <label>Phone<input oninput="document.querySelector('#label').textContent='Previous employer'"></label></form>''')
        result=self.fill(pool,'lever')
        self.assertEqual(result['artifact']['fields'][0]['status'],'unverified')
        self.assertEqual(result['artifact']['filled'],1)

    def test_identifier_fallback_for_all_four_ats_and_hidden_disabled_controls(self):
        for family,identifier in [('greenhouse','id="first_name"'),('lever','name="email"'),
                                  ('ashby','name="_systemfield_email"'),('workday','data-automation-id="legalNameSection_firstName"')]:
            with self.subTest(family=family):
                pool,page=self.fixture(family,'<form><input '+identifier+'><label>Phone<input disabled></label><label>Email<input style="display:none"></label></form>')
                result=self.fill(pool,family)
                self.assertEqual(result['artifact']['filled'],1)
                self.assertEqual(page.locator('input[disabled]').input_value(),'')

    def test_explicit_resume_upload_checks_session_target_and_preserves_existing_files(self):
        pool,page=self.fixture('greenhouse','<form><label>Resume<input type=file></label></form>')
        result=self.fill(pool,'greenhouse');token=result['artifact']['fields'][0]['upload_token']
        event=dict(upload_token=token,document=dict(name='fixture.pdf',content=base64.b64encode(b'%PDF-fixture').decode()))
        with self.assertRaisesRegex(ValueError,'active application browser'):
            autofill.upload_resume(pool,'other','run',event)
        autofill.upload_resume(pool,'owner','run',event)
        self.assertEqual(page.locator('input').evaluate('(e)=>e.files[0].name'),'fixture.pdf')
        result=self.fill(pool,'greenhouse');event['upload_token']=result['artifact']['fields'][0]['upload_token']
        with self.assertRaisesRegex(ValueError,'already selected'):
            autofill.upload_resume(pool,'owner','run',event)

    def test_upload_target_invalidated_by_user_navigation(self):
        pool,page=self.fixture('workday','<form><label>Resume<input type=file></label></form>')
        result=self.fill(pool,'workday');token=result['artifact']['fields'][0]['upload_token']
        page.set_content('<form><label>Cover letter<input type=file></label></form>')
        with self.assertRaises(ValueError):
            autofill.upload_resume(pool,'owner','run',dict(upload_token=token,document={}))

    def test_login_and_mfa_never_fill_email_or_save_credentials(self):
        for control in ('<input type=password>','<input autocomplete=one-time-code>'):
            pool,page=self.fixture('workday','<form><label>Email<input type=email></label>'+control+'</form>')
            result=self.fill(pool,'workday');self.assertEqual(result['artifact']['filled'],0)
            self.assertEqual(page.locator('input[type=email]').input_value(),'')
            self.assertEqual(len(result['requests']),1)

    def test_same_session_after_user_navigation_and_user_edits(self):
        pool,page=self.fixture('workday',FIXTURES['workday']);self.fill(pool,'workday')
        context=pool.sessions[('owner','run')]['context']
        page.set_content('<form><label>Phone<input></label><label>Email<input value="user@example.test"></label></form>')
        result=self.fill(pool,'workday')
        self.assertIs(pool.sessions[('owner','run')]['context'],context)
        self.assertEqual(result['artifact']['filled'],1)
        self.assertEqual(page.locator('input').nth(1).input_value(),'user@example.test')

    def test_repeated_records_and_non_form_inputs_are_not_guessed(self):
        pool,page=self.fixture('lever','<input aria-label="Email"><form><label>First Name<input></label><label>First Name<input></label></form>')
        result=self.fill(pool,'lever');self.assertEqual(result['artifact']['filled'],0)
        self.assertEqual(page.locator('input').nth(0).input_value(),'')

    def test_changed_field_and_invalid_values_are_not_reported_successful(self):
        pool,page=self.fixture('ashby','<form><label>Email<input type=email required></label></form>')
        result=self.fill(pool,'ashby',{'email':'not-an-email'})
        self.assertEqual(result['artifact']['filled'],0)
        self.assertEqual(result['artifact']['fields'][0]['status'],'unverified')

    def test_other_owner_cannot_reuse_session_and_destination_changes_are_rejected(self):
        pool,page=self.fixture('lever',FIXTURES['lever'])
        self.assertNotIn(('other','run'),pool.sessions)
        with self.assertRaisesRegex(ValueError,'different task destination'):
            autofill.fill_page(pool,'owner','run',dict(application_url='https://jobs.lever.co/other/new',facts=facts()))
        self.assertEqual(page.locator('input').nth(0).input_value(),'')


if __name__ == '__main__':unittest.main()
