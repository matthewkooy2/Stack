"""Persist a real application and a swept listing, restart, then verify."""
import json,sys,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from test_api import account,rpc,request
from discovery.normalize import normalize
from catalog_fixture import career
from scripts.catalog import call
p=Path('.jac/catalog-persistence.json')
if sys.argv[1]=='prepare':
    username,password,token=account();label='Persistence'+uuid.uuid4().hex[:10];url='https://example.com/'+label;config=career(url);source=config['id']
    run=call('jobs_sweep_begin',only=[config])['run']
    job=normalize({'title':label+' Electrician','company':'Temporary restart test','url':url,'country':'US'},config)
    call('jobs_sweep_source',run=run,id=source,jobs=[job],complete=True)
    while not call('jobs_sweep_finish',run=run)['done']:pass
    state=rpc(token,'swipe',job_id=job['id'],action='apply');app=next(a for a in state['applications'] if a['job_id']==job['id'])
    rpc(token,'save_application',id=app['id'],notes='Notes survive restart');rpc(token,'save_search',query='Electrician',filters={'country':'US'})
    p.touch(mode=0o600);p.write_text(json.dumps({'username':username,'password':password,'source':source,'job':job['id'],'app':app['id']}))
    print('Prepared real application, search, and swept listing.')
else:
    d=json.loads(p.read_text());_,r=request('/user/login',{'identity':{'type':'username','value':d['username']},'credential':{'type':'password','password':d['password']}});token=r['data']['token']
    state=rpc(token,'bootstrap');app=next(a for a in state['applications'] if a['id']==d['app'])
    assert app['status']=='Ready to apply' and app['notes']=='Notes survive restart' and not app['demo']
    assert state['saved_search']['query']=='Electrician'
    assert rpc(token,'get_job',id=d['job'])['id']==d['job']
    assert rpc(token,'job_feed')['computed_at']
    call('discovery_manage',id=d['source'],action='purge');p.unlink()
    print('PASS real application, saved search, catalog ID, and stored matches after restart.')
