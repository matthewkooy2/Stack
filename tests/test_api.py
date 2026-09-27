"""Black-box checks against the local Jac server. Creates isolated test accounts."""
import base64
import concurrent.futures
import json
import os
import time
import unittest
import urllib.request
import urllib.error
import uuid

BASE = os.environ.get('STACK_API_URL', 'http://127.0.0.1:8000')

def request(path, body=None, token=None, method='POST'):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path, data=json.dumps(body or {}).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status,json.load(r)
    except urllib.error.HTTPError as e:
        with e: return e.code,json.load(e)

def rpc(token,endpoint,**args):
    status,data=request('/function/'+endpoint,args,token)
    assert status==200,(status,data)
    assert data.get('ok'),data
    return data['data']['result']

def account():
    user='test_'+uuid.uuid4().hex[:14]; password=uuid.uuid4().hex
    code,result=request('/user/register',{'identities':[{'type':'username','value':user}], 'credential':{'type':'password','password':password}})
    assert code in (200,201),code
    return user,password,result['data']['token']

def pdf_bytes():
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R >>',b'<< /Length 0 >>\nstream\n\nendstream']
    out=b'%PDF-1.4\n'; offsets=[0]
    for i,obj in enumerate(objects,1): offsets.append(len(out));out+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    xref=len(out);out+=b'xref\n0 5\n0000000000 65535 f \n'
    for pos in offsets[1:]:out+=f'{pos:010} 00000 n \n'.encode()
    return out+f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()

class StackAPI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.user,cls.password,cls.a=account(); _,_,cls.b=account()
        cls.initial=rpc(cls.a,'bootstrap');rpc(cls.b,'bootstrap')
    def test_01_auth_and_isolation(self):
        self.assertEqual(request('/function/bootstrap')[0],401)
        code,result=request('/user/login',{'identity':{'type':'username','value':self.user},'credential':{'type':'password','password':'incorrect'}})
        self.assertFalse(result.get('ok'));self.assertGreaterEqual(code,400)
        a=rpc(self.a,'save_profile',name='Test Alice',role='Entry-level SWE',location='Remote',mode='Remote',notifications=True)
        self.assertEqual(a['profile']['name'],'Test Alice')
        b=rpc(self.b,'bootstrap');self.assertNotEqual(a['user_id'],b['user_id']);self.assertEqual(b['profile']['name'],'')
        self.assertEqual(len(a['contacts']),4); self.assertEqual(len(rpc(self.a,'bootstrap')['contacts']),4)
    def test_02_swipe_idempotence_and_progress(self):
        rpc(self.a,'swipe',job_id='j1',action='apply')
        rpc(self.a,'swipe',job_id='j1',action='apply')
        a=rpc(self.a,'bootstrap');self.assertEqual(len([x for x in a['applications'] if x['job_id']=='j1']),1)
        self.assertFalse([x for x in rpc(self.b,'bootstrap')['applications'] if x['job_id']=='j1'])
        app=next(x for x in a['applications'] if x['job_id']=='j1')
        self.assertIn(app['status'],['Queued','Preparing','Submitted'])
        self.assertIn('error',rpc(self.b,'save_application',id=app['id'],notes='not mine'))
        rpc(self.a,'save_application',id=app['id'],notes='Saved notes')
        self.assertEqual(next(x for x in rpc(self.a,'bootstrap')['applications'] if x['id']==app['id'])['notes'],'Saved notes')
    def test_03_parallel_swipes(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _:rpc(self.a,'swipe',job_id='j2',action='apply'), range(4)))
        self.assertEqual(len([x for x in rpc(self.a,'bootstrap')['applications'] if x['job_id']=='j2']),1)
    def test_04_contacts(self):
        c=self.initial['contacts'][0]
        rpc(self.a,'save_contact',id=c['id'],saved=True,draft='Hello, world',notes='Talk about hiring')
        updated=next(x for x in rpc(self.a,'bootstrap')['contacts'] if x['id']==c['id'])
        self.assertTrue(updated['saved']);self.assertEqual(updated['draft'],'Hello, world')
        self.assertIn('error',rpc(self.b,'save_contact',id=c['id'],saved=True,draft='bad',notes='bad'))
    def test_05_pdf_validation_and_ownership(self):
        self.assertIn('error',rpc(self.a,'upload_resume',name='bad.pdf',content=base64.b64encode(b'not a PDF').decode()))
        self.assertIn('error',rpc(self.a,'upload_resume',name='broken.pdf',content=base64.b64encode(b'%PDF-1.4\nnot valid').decode()))
        self.assertIn('error',rpc(self.a,'upload_resume',name='large.pdf',content='A'*13981020))
        raw=pdf_bytes();a=rpc(self.a,'upload_resume',name='resume.pdf',content=base64.b64encode(raw).decode())
        r=a['resumes'][-1];self.assertEqual(a['selected_resume'],r['id'])
        app=next(x for x in a['applications'] if x['job_id']=='j1')
        selected=rpc(self.a,'select_application_resume',id=app['id'],resume_id=r['id'])
        self.assertEqual(next(x for x in selected['applications'] if x['id']==app['id'])['resume_id'],r['id'])
        foreign=rpc(self.b,'swipe',job_id='j3',action='apply')['applications'][0]
        self.assertIn('error',rpc(self.b,'select_application_resume',id=foreign['id'],resume_id=r['id']))
        self.assertEqual(base64.b64decode(rpc(self.a,'read_resume',id=r['id'])['content']),raw)
        self.assertIn('error',rpc(self.b,'read_resume',id=r['id']))
        self.assertIn('error',rpc(self.b,'change_resume',id=r['id'],action='delete'))
        renamed=rpc(self.a,'change_resume',id=r['id'],action='rename',name='My resume.pdf')
        self.assertEqual(renamed['resumes'][-1]['name'],'My resume.pdf')
        deleted=rpc(self.a,'change_resume',id=r['id'],action='delete')
        self.assertNotIn(r['id'],[x['id'] for x in deleted['resumes']]);self.assertEqual(deleted['selected_resume'],'')
        self.assertIn('error',rpc(self.a,'read_resume',id=r['id']))
    def test_06_reminder_lifecycle(self):
        target=self.initial['contacts'][0]['id']
        self.assertIn('error',rpc(self.a,'save_reminder',id='',target_type='contact',target_id=target,title='Past',due_at=time.time()-1))
        self.assertIn('error',rpc(self.b,'save_reminder',id='',target_type='contact',target_id=target,title='Foreign',due_at=time.time()+3600))
        a=rpc(self.a,'save_reminder',id='',target_type='contact',target_id=target,title='Follow up',due_at=time.time()+3600)
        r=a['reminders'][-1]
        self.assertIn('error',rpc(self.b,'change_reminder',id=r['id'],action='delete'))
        a=rpc(self.a,'save_reminder',id=r['id'],target_type='contact',target_id=target,title='Updated',due_at=time.time()+7200)
        self.assertEqual(a['reminders'][-1]['title'],'Updated')
        self.assertTrue(rpc(self.a,'change_reminder',id=r['id'],action='complete')['reminders'][-1]['done'])
        self.assertFalse(rpc(self.a,'change_reminder',id=r['id'],action='delete')['reminders'])
    def test_07_parallel_initialization(self):
        _,_,token=account()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _:rpc(token,'bootstrap'),range(4)))
        state=rpc(token,'bootstrap')
        self.assertEqual(len(state['contacts']),4)
        self.assertEqual(len(state['applications']),0)
        self.assertEqual(len(state['decisions']),0)
    def test_08_signin_restores(self):
        _,r=request('/user/login',{'identity':{'type':'username','value':self.user},'credential':{'type':'password','password':self.password}})
        self.assertEqual(rpc(r['data']['token'],'bootstrap')['profile']['name'],'Test Alice')

if __name__=='__main__':unittest.main(verbosity=2)
