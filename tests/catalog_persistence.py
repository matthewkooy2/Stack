"""Persist a real application and an interrupted page, restart, then verify."""
import json,sys,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_api import account,rpc,request
from discovery.normalize import digest,normalize
from scripts.catalog import call
p=Path('.jac/catalog-persistence.json')
if sys.argv[1]=='prepare':
    username,password,token=account();label='Persistence'+uuid.uuid4().hex[:10];url='https://example.com/'+label;source='career:'+digest(url)
    rpc(token,'import_job_url',url=url);w=call('discovery_claim',preferred_id=source)
    job=normalize({'title':label+' Electrician','company':'Temporary restart test','url':url,'country':'US'},w['config'])
    call('discovery_complete',id=source,lease=w['lease'],result={'jobs':[job],'checkpoint':{'offset':17},'complete':False})
    state=rpc(token,'swipe',job_id=job['id'],action='apply');app=next(a for a in state['applications'] if a['job_id']==job['id'])
    rpc(token,'save_application',id=app['id'],notes='Notes survive restart');rpc(token,'save_search',query='Electrician',filters={'country':'US'})
    p.touch(mode=0o600);p.write_text(json.dumps({'username':username,'password':password,'source':source,'job':job['id'],'app':app['id']}))
    print('Prepared real application, search, and interrupted collection checkpoint.')
else:
    d=json.loads(p.read_text());_,r=request('/user/login',{'identity':{'type':'username','value':d['username']},'credential':{'type':'password','password':d['password']}});token=r['data']['token']
    state=rpc(token,'bootstrap');app=next(a for a in state['applications'] if a['id']==d['app'])
    assert app['status']=='Ready to apply' and app['notes']=='Notes survive restart' and not app['demo']
    assert state['saved_search']['query']=='Electrician'
    assert rpc(token,'get_job',id=d['job'])['id']==d['job']
    call('discovery_manage',id=d['source'],action='retry');w=call('discovery_claim',preferred_id=d['source']);assert w['checkpoint']=={'offset':17}
    call('discovery_manage',id=d['source'],action='purge');p.unlink()
    print('PASS real application, saved search, catalog ID, and page checkpoint after restart.')
