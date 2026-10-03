"""Opt-in real Chromium test using only an in-memory form and fresh context.

Requires separately approved Playwright 1.58.0 installation. No network, account,
credentials, saved browser profile, Docker, or deployed service is used.
"""
import base64
import os
import json
from pathlib import Path
import time
from agents.browser import BrowserPool, BrowserFrames
from agents.browser_service import BrowserHost
from playwright.sync_api import sync_playwright

KEY=('synthetic-capture-owner','synthetic-capture-run')


def factory():
    pool=BrowserPool.__new__(BrowserPool)
    pool.driver=sync_playwright().start()
    # Chromium cannot initialize a nested seatbelt inside sandbox-exec on this Mac.
    # The opt-in wrapper verifies outbound IP denial before enabling this test-only flag.
    options=dict(headless=True,chromium_sandbox=os.environ.get('STACK_BROWSER_TEST_OUTER_SANDBOX')!='1')
    if os.environ.get('STACK_BROWSER_TEST_CHANNEL'):
        options['channel']=os.environ['STACK_BROWSER_TEST_CHANNEL']
    pool.browser=pool.driver.chromium.launch(**options)
    pool.frames=BrowserFrames();pool.sessions={};pool.control=None;pool.operation_guard=None
    context=pool.browser.new_context(viewport=dict(width=600,height=400),accept_downloads=False)
    pool.blocked_requests=[]
    def blocked(route):
        pool.blocked_requests.append(route.request.url);route.abort()
    context.route('**/*',blocked)
    page=context.new_page();page.set_default_timeout(2000)
    page.set_content('<input id="answer" style="position:absolute;left:20px;top:20px;width:200px;height:40px"><div id="state" style="position:absolute;top:100px">Synthetic fixture</div><img src="https://synthetic-network.invalid/blocked.png">',wait_until='domcontentloaded')
    # The existing private-login adapter skips disk checkpointing. This fixture never logs in.
    pool.sessions[KEY]=dict(context=context,page=page,touched=time.time(),adapter='linkedin')
    return pool


def run():
    host=BrowserHost(factory)
    try:
        host.control.watch(KEY,1)
        capture_started=time.monotonic();deadline=capture_started+5
        while time.monotonic()<deadline:
            host.tick()
            if host.pool.frames.get(KEY).get('capture')=='screencast':break
            time.sleep(.05)
        frame=host.pool.frames.get(KEY)
        assert frame.get('capture')=='screencast', 'Real CDP frame was not received'
        jpeg=base64.b64decode(frame['image']);assert jpeg.startswith(b'\xff\xd8'), 'Expected a JPEG frame'
        report=dict(browser_version=host.pool.browser.version,viewport=[frame['width'],frame['height']],first_capture=frame['capture'],first_jpeg_bytes=len(jpeg),first_frame_ms=round((time.monotonic()-capture_started)*1000,1))
        assert host.pool.blocked_requests==['https://synthetic-network.invalid/blocked.png'],host.pool.blocked_requests
        report['blocked_page_requests']=host.pool.blocked_requests
        if os.environ.get('STACK_VIEWER_CAPTURE_REPORT'):
            Path(os.environ['STACK_VIEWER_CAPTURE_REPORT']).with_suffix('.jpg').write_bytes(jpeg)
        state=host.dispatch('/control',dict(owner=KEY[0],id=KEY[1],action='take',generation=0,instance=host.control.instance,controller='viewer-real-local-fixture'))
        assert state['mode']=='user'
        for index,event in enumerate([dict(type='click',x=70,y=40),dict(type='text',text='Synthetic input')],1):
            result=host.dispatch('/handoff',dict(owner=KEY[0],id=KEY[1],event={**event,**{k:state[k] for k in ['generation','instance','controller']},'sequence':index}))
            assert result.get('image') and not result.get('interrupted'),result
        value=host.executor.submit(lambda:host.pool.sessions[KEY]['page'].locator('#answer').input_value()).result()
        assert value=='Synthetic input'
        report['verified_dom_input']=value
        previous=host.pool.frames.get(KEY).get('sequence',0)
        host.executor.submit(lambda:host.pool.sessions[KEY]['page'].evaluate("document.body.style.backgroundColor='rgb(220,240,255)'")).result()
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            host.tick();updated=host.pool.frames.get(KEY)
            if updated.get('capture')=='screencast' and updated.get('sequence',0)>previous:break
            time.sleep(.05)
        assert updated.get('capture')=='screencast' and updated.get('sequence',0)>previous,'No CDP update after page changed'
        report['updated_screencast_sequence']=updated['sequence']
        host.control.watch(KEY,-1);host.tick()
        assert 'cdp' not in host.pool.sessions[KEY], 'Last viewer must detach capture'
        report['capture_detached_after_disconnect']=True
        resumed=host.dispatch('/control',dict(owner=KEY[0],id=KEY[1],action='resume',generation=1,instance=state['instance'],controller=state['controller']))
        assert resumed['mode']=='agent'
        report['resume_generation']=resumed['generation']
        host.dispatch('/control',dict(owner=KEY[0],id=KEY[1],action='stop'));host.tick()
        assert KEY not in host.pool.sessions and host.control.state(KEY)['mode']=='stopped'
        report['stopped_and_context_closed']=True
        report['outer_network_sandbox']=os.environ.get('STACK_BROWSER_TEST_OUTER_SANDBOX')=='1'
        report['chromium_inner_sandbox']=not report['outer_network_sandbox']
        if os.environ.get('STACK_VIEWER_CAPTURE_REPORT'):
            Path(os.environ['STACK_VIEWER_CAPTURE_REPORT']).write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))
        print('Real local CDP capture, ordered input, disconnect, resume and stop passed.')
    finally:
        def cleanup():
            host.pool.close(*KEY);host.pool.browser.close();host.pool.driver.stop()
        host.executor.submit(cleanup).result();host.executor.shutdown()

if __name__=='__main__':run()
