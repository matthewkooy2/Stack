"""Live browser sessions for LinkedIn review, isolated by account and run."""
import base64;
import secrets;
import os;
import time;
import threading;
import from pathlib { Path }
import from urllib.parse { urlsplit }
import from agents.contracts { digest }
with entry {
    HANDOFF_KEYS = {
        'Tab': 'Tab', 'Enter': 'Enter', 'Backspace': 'Backspace',
        'Delete': 'Delete', 'SelectAll': 'ControlOrMeta+A'
    };
    # Enter advances within the focused form, then activates its submit action.
    ENTER_FORM_JS = r'''() => {
 if (!document.hasFocus()) return false;
 const active = document.activeElement, form = active?.form;
 if (!form || !active.matches('input,select,textarea')) return false;
 const available = e => !e.matches(':disabled') && e.getAttribute('aria-disabled') !== 'true'
   && !e.closest('[inert]') && e.getClientRects().length > 0
   && getComputedStyle(e).visibility !== 'hidden';
 const fields = [...form.elements].filter(e => e.matches('input,select,textarea')
   && !['hidden','button','submit','reset','image'].includes(e.type)
   && e.tabIndex >= 0 && available(e));
 fields.sort((a,b) => (a.tabIndex > 0 ? a.tabIndex : Infinity) - (b.tabIndex > 0 ? b.tabIndex : Infinity));
 const index = fields.indexOf(active);
 if (index < 0) return false;
 if (fields[index + 1]) { fields[index + 1].focus(); return true; }
 const buttons = [...form.elements].filter(e => e.matches('button,input') && ['submit','image'].includes(e.type));
 if (buttons.length) {
   const button = buttons.find(available);
   if (button) button.click();
 } else HTMLFormElement.prototype.requestSubmit.call(form);
 return true;
}''';
}
"""Latest live frame only, in memory, scoped to the account and task."""
class BrowserFrames {
    def init(self: BrowserFrames) -> any {
        self.lock = threading.Lock();
        self.values = {};
    }
    def put(self: BrowserFrames, key: any, frame: any) -> any {
        with self.lock {
            self.values[key] = {**frame,'sequence':self.values.get(key,{}).get('sequence',0)+1};
        }
    }
    def get(self: BrowserFrames, key: any) -> any {
        with self.lock {
            return self.values.get(key, {'pending': True});
        }
    }
    def observe(self: BrowserFrames, key: any) -> any {
        with self.lock {
            if key in self.values { self.values[key]={**self.values[key],'observed_at':time.time()}; }
        }
    }
    def remove(self: BrowserFrames, key: any) -> any {
        with self.lock {
            self.values.pop(key, None);
        }
    }
}
class BrowserPool {
    def init(self: BrowserPool) -> any {
        import from playwright.sync_api { sync_playwright }
        self.driver = sync_playwright().start();
        self.browser = self.driver.chromium.launch(
            headless=True, chromium_sandbox=True
        );
        self.sessions = {};
        self.frames = BrowserFrames();
        self.control = None;
        self.operation_guard = None;
    }
    def guard(self: BrowserPool) -> any {
        if getattr(self,'operation_guard',None) { self.operation_guard(); }
    }
    def stream_setup(self: BrowserPool, owner: any, run: any) -> any {
        value=self.sessions.get((owner,run));control=getattr(self,'control',None);
        if not value or not control { return; }
        watching=control.watching((owner,run));
        if value.get('cdp') and not watching {
            cdp=value.pop('cdp');
            try { cdp.send('Page.stopScreencast'); } except Exception { ; }
            try { cdp.detach(); } except Exception { ; }
            return;
        }
        if not watching or value.get('cdp') or value.get('capture_fallback') { return; }
        cdp=None;
        try {
            cdp=value['context'].new_cdp_session(value['page']);
            def captured(event: any) -> None {
                try {
                    if self.sessions.get((owner,run)) is value and control.watching((owner,run)) and control.state((owner,run))['mode'] not in ['stopping','stopped'] {
                        self.frames.put((owner,run),self.frame_data(owner,run,event['data'],'screencast'));
                    }
                } except Exception { value['capture_fallback']=True; }
                finally {
                    try { cdp.send('Page.screencastFrameAck',{'sessionId':event['sessionId']}); } except Exception { ; }
                }
            }
            cdp.on('Page.screencastFrame',captured);
            cdp.send('Page.startScreencast',{'format':'jpeg','quality':65,'everyNthFrame':1});
            value['cdp']=cdp;
        } except Exception {
            value['capture_fallback']=True;
            if cdp { try { cdp.detach(); } except Exception { ; } }
        }
    }
    def frame_data(self: BrowserPool, owner: any, run: any, image: any, transport: str) -> any {
        value=self.sessions[(owner,run)];page=value['page'];url=urlsplit(page.url);
        return {'image':image,'capture_id':value.setdefault('capture_id',secrets.token_hex(12)),**(page.viewport_size or {'width':1100,'height':800}),
            'url':url._replace(query='',fragment='').geturl(),'private_login':value.get('adapter')=='linkedin',
            'captured_at':time.time(),'observed_at':time.time(),'progress':value.get('progress',''),'capture':transport};
    }
    def viewer_tick(self: BrowserPool) -> any {
        control: any = getattr(self,'control',None);
        if not control { return; }
        for key in control.pending_stops() { self.close(*key);control.end(key); }
        for (owner,run) in `list(self.sessions) {
            if control.state((owner,run))['mode'] in ['stopping','stopped'] {
                self.close(owner,run);control.end((owner,run));continue;
            }
            self.stream_setup(owner,run);
            value=self.sessions.get((owner,run));
            if value and control.watching((owner,run)) {
                try {
                    if value.get('capture_fallback') { self.publish(owner,run); }
                    else { value['page'].wait_for_timeout(1);self.frames.observe((owner,run)); }
                } except Exception { value['capture_fallback']=True; }
            }
        }
    }
    def publish(self: BrowserPool, owner: any, run: any) -> any {
        self.guard();self.stream_setup(owner,run);
        page=self.sessions[(owner,run)]['page'];
        self.frames.put((owner,run),self.frame_data(owner,run,base64.b64encode(page.screenshot(`type='jpeg',quality=65)).decode(),'snapshot'));
        return self.frames.get((owner,run));
    }
    def path(self: BrowserPool, owner: any, run: any) -> any {
        return (
            Path(os.environ.get('STACK_BROWSER_STORAGE', '/tmp/stack-browser-sessions'))
            / digest(owner)
            / (digest(run) + '.enc')
        );
    }
    def close(self: BrowserPool, owner: any, run: any) -> any {
        self.frames.remove((owner, run));
        value = self.sessions.pop((owner, run), None);
        if value {
            if value.get('cdp') {
                try { value['cdp'].detach(); } except Exception { ; }
            }
            value['context'].close();
        }
        return {'closed': True};
    }
    def linkedin_scan(self: BrowserPool, owner: any, run: any, context: any) -> any {
        import from agents.linkedin { scan }
        return scan(self, owner, run, context);
    }
    def browser_autofill(self: BrowserPool, owner: any, run: any, context: any) -> any {
        import from agents.autofill { fill_page }
        return fill_page(self, owner, run, context);
    }
    def purge(self: BrowserPool, owner: any) -> any {
        for key in `list(self.sessions) {
            if (key[0] == owner) {
                self.close(*key);
            }
        }
        directory = self.path(owner, '').parent;
        if directory.exists() {
            for path in directory.glob('*.enc') {
                path.unlink();
            }
        }
        return {'purged': True};
    }
    def handoff(self: BrowserPool, owner: any, run: any, event: any) -> any {
        value = self.sessions.get((owner, run));
        control=getattr(self,'control',None);
        if control and control.state((owner,run)).get('relaxed') and not value { return self.frames.get((owner,run)); }
        if value and value.get('adapter')=='linkedin' {
            page=value['page'];kind=event.get('type','snapshot');
            if kind=='click' { page.mouse.click(event['x'],event['y']); }
            elif kind=='text' { page.keyboard.insert_text(str(event.get('text',''))); }
            elif kind=='key' {
                handled=False;
                if event['key']=='Enter' {
                    for frame in page.frames { if frame.evaluate(ENTER_FORM_JS) { handled=True;break; } }
                }
                if not handled { page.keyboard.press('Shift+Tab' if event['key']=='Tab' and event.get('shift',False) else HANDOFF_KEYS[event['key']]); }
            } elif kind=='scroll' { page.mouse.wheel(0,event['dy']); }
            elif kind in ['reload','login'] { page.goto(value['url'] if kind=='reload' else 'https://www.linkedin.com/login',wait_until='domcontentloaded'); }
            value['touched']=time.time();return self.publish(owner,run);
        }
        if not value {
            raise ValueError('Browser session unavailable. Resume the run to open it.');
        }
        page = value['page'];
        kind = event.get('type', 'snapshot');
        if (kind == 'click') {
            (x, y) = (event.get('x', -1), event.get('y', -1));
            viewport = page.viewport_size or {'width': 1100, 'height': 800};
            if (
                not (0 <= x < viewport['width']) or not (0 <= y < viewport['height'])
            ) {
                raise ValueError('Click is outside the browser viewport.');
            }
            self.guard();
            page.mouse.click(x, y);
        } elif kind == 'upload_resume' {
            import from agents.autofill { upload_resume }
            return upload_resume(self,owner,run,event);
        } elif (kind == 'text') {
            self.guard();
            text = str(event.get('text', ''))[:8000];
            if event.get('paste', False) or ('\n' in text) or ('\r' in text) {
                page.keyboard.insert_text(text);
            } else {
                page.keyboard.type(text);
            }
        } elif ((kind == 'key') and (event.get('key') in HANDOFF_KEYS)) {
            self.guard();
            handled = False;
            if event['key'] == 'Enter' {
                for frame in page.frames {
                    self.guard();
                    if frame.evaluate(ENTER_FORM_JS) { handled = True; break; }
                }
            }
            if not handled {
                page.keyboard.press('Shift+Tab' if event['key'] == 'Tab' and event.get('shift', False) else HANDOFF_KEYS[event['key']]);
            }
        } elif (kind == 'scroll') {
            self.guard();
            page.mouse.wheel(0, max(-700, min(700, int(event.get('dy', 0)))));
        } elif (kind != 'snapshot') {
            raise ValueError('Unknown browser input.');
        }
        value['touched'] = time.time();
        return self.publish(owner, run);
    }
    def expire(self: BrowserPool) -> any {
        control: any = getattr(self,'control',None);
        for (key, value) in `list(self.sessions.items()) {
            if value.get('adapter')=='linkedin' { continue; }
            if (value['touched'] < (time.time() - 3600)) and not (control and control.watching(key)) {
                self.close(*key);
            }
        }
    }
}
