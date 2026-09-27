"""Run prepare, restart the API, then verify. Credentials stay in ignored .jac/."""
import base64
import json
from pathlib import Path
import sys
import time
from test_api import account, rpc, request, pdf_bytes

fixture=Path('.jac/persistence-test.json')
if sys.argv[1]=='prepare':
    username,password,token=account()
    rpc(token,'bootstrap')
    rpc(token,'save_profile',name='Restart test',role='Entry-level SWE',location='US',mode='Any',notifications=True)
    rpc(token,'swipe',job_id='j3',action='apply')
    state=rpc(token,'upload_resume',name='persistence.pdf',content=base64.b64encode(pdf_bytes()).decode())
    c=state['contacts'][0]
    rpc(token,'save_contact',id=c['id'],saved=True,draft='A persisted draft',notes='A persisted note')
    state=rpc(token,'save_reminder',id='',target_type='contact',target_id=c['id'],title='Survives restart',due_at=time.time()+86400)
    fixture.touch(mode=0o600)
    fixture.write_text(json.dumps({'username':username,'password':password,'state':state}))
    print('Prepared private persistence fixture; restart the API before verify.')
elif sys.argv[1]=='verify':
    saved=json.loads(fixture.read_text())
    _,result=request('/user/login',{'identity':{'type':'username','value':saved['username']},'credential':{'type':'password','password':saved['password']}})
    token=result['data']['token'];state=rpc(token,'bootstrap');before=saved['state']
    for key in ['user_id','profile','decisions','contacts','resumes','reminders','selected_resume']:assert state[key]==before[key],key
    app=next(a for a in state['applications'] if a['job_id']=='j3')
    assert app['status']=='Submitted',app['status']
    assert base64.b64decode(rpc(token,'read_resume',id=state['resumes'][0]['id'])['content'])==pdf_bytes()
    fixture.unlink()
    print('PASS persistence: sign-in, profile, decisions, demo progress, contacts, reminders and private PDF after server restart.')
else:raise SystemExit('Use prepare or verify')
