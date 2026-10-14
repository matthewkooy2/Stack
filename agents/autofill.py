"""Saved-answer filling only. No model calls, passwords, navigation or submission."""
import hashlib
import base64
import re
import secrets
import time
from urllib.parse import urlsplit


HOSTS = {
    'greenhouse': ('boards.greenhouse.io', 'job-boards.greenhouse.io', 'boards.eu.greenhouse.io'),
    'ashby': ('jobs.ashbyhq.com',),
    'lever': ('jobs.lever.co', 'jobs.eu.lever.co'),
}
ALIASES = {
    'first_name': ('first name', 'given name', 'legal first name'),
    'last_name': ('last name', 'family name', 'surname', 'legal last name'),
    'name': ('name', 'full name', 'legal name'),
    'email': ('email', 'email address'),
    'phone': ('phone', 'phone number', 'mobile phone', 'mobile phone number'),
    'location': ('location', 'current location'),
    'city': ('city', 'current city'),
    'country': ('country', 'country of residence'),
    'postal_code': ('postal code', 'zip code'),
    'address_line_1': ('address line 1', 'street address'),
    'linkedin': ('linkedin', 'linkedin profile', 'linkedin url', 'linkedin profile url'),
    'website': ('website', 'personal website', 'portfolio', 'portfolio url'),
    'work_authorization': ('work authorization', 'are you legally authorized to work in the united states',
                           'are you authorized to work in the united states'),
    'sponsorship': ('sponsorship', 'do you require sponsorship',
                    'will you now or in the future require sponsorship for employment visa status'),
    'salary': ('salary expectations', 'desired salary'),
    'availability': ('available start date', 'when can you start'),
    'relocation': ('are you willing to relocate', 'willing to relocate'),
}
# Stable identifiers for the tested ATS controls; labels still take precedence.
IDENTIFIERS = {
    'greenhouse': {'first_name': 'first_name', 'last_name': 'last_name', 'email': 'email', 'phone': 'phone'},
    'lever': {'name': 'name', 'email': 'email', 'phone': 'phone', 'urls[linkedin]': 'linkedin', 'urls[portfolio]': 'website'},
    'ashby': {'_systemfield_name': 'name', '_systemfield_email': 'email', '_systemfield_phone': 'phone'},
    'workday': {'legalNameSection_firstName': 'first_name', 'legalNameSection_lastName': 'last_name',
                'email': 'email', 'phone-number': 'phone'},
}
AUTOCOMPLETE = {'given-name': 'first_name', 'family-name': 'last_name', 'name': 'name', 'email': 'email', 'tel': 'phone'}


def normalize(value):
    return re.sub(r'\s+', ' ', re.sub(r'[^\w\s]', ' ', str(value).casefold())).strip()


def answer_key(label):
    return 'answer:' + hashlib.sha256(normalize(label).encode()).hexdigest()[:24]


def application_url(value):
    """Hosted ATS pages only, never employer-controlled arbitrary destinations."""
    try:
        parsed = urlsplit(str(value).strip())
        host = parsed.hostname or ''
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
            raise ValueError()
        for family, hosts in HOSTS.items():
            if host in hosts and parsed.path not in ('', '/'):
                return dict(url=parsed._replace(fragment='').geturl(), family=family, host=host)
        if re.fullmatch(r'[a-z0-9-]+\.wd[0-9]+\.myworkdayjobs\.com', host) and '/job/' in parsed.path:
            return dict(url=parsed._replace(fragment='').geturl(), family='workday', host=host)
    except (ValueError, TypeError):
        pass
    raise ValueError('Autofill supports hosted Greenhouse, Ashby, Lever and tenant Workday job URLs. Open custom employer pages yourself.')


def request_allowed(url, navigation, target):
    try:
        parsed = urlsplit(url)
        host = parsed.hostname or ''
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443):
            return False
        if navigation:
            # Tenant/family boundary applies to every frame and redirect, including user navigation.
            return host == target['host'] or host in HOSTS.get(target['family'], ())
        resources = {
            'greenhouse': ('greenhouse.io', 'greenhouse-hosted-production.s3.amazonaws.com'),
            'ashby': ('ashbyhq.com',),
            'lever': ('lever.co',),
            'workday': ('myworkdaycdn.com',),
        }[target['family']]
        return host == target['host'] or any(host == domain or host.endswith('.' + domain) for domain in resources)
    except (ValueError, TypeError):
        return False


EXTRACT_JS = r'''prefix => {
 const visible = e => !!(e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
 const controls = [...document.querySelectorAll('form input,form textarea,form select,form [role="combobox"], [data-automation-id="formField"] input,[data-automation-id="formField"] textarea,[data-automation-id="formField"] select,[data-automation-id="formField"] [role="combobox"]')].filter(visible);
 if ([...document.querySelectorAll('input[type="password"],input[autocomplete="one-time-code"]')].some(visible)) return {login:true,fields:[]};
 const clean = s => (s || '').replace(/\s+/g,' ').trim().slice(0,400);
 const labelText = e => {
   if (!e) return ''; const copy=e.cloneNode(true);
   copy.querySelectorAll('input,select,textarea,button,[role="combobox"]').forEach(c=>c.remove());
   return copy.textContent;
 };
 const label = e => {
   const labelled = (e.getAttribute('aria-labelledby') || '').split(' ').map(id=>document.getElementById(id)?.textContent).join(' ');
   const group = e.closest('fieldset,[data-automation-id="formField"]');
   return clean(e.getAttribute('aria-label') || labelled.trim() || [...(e.labels || [])].map(labelText).join(' ') ||
     labelText(group?.querySelector('legend,label')) || e.placeholder || '');
 };
 const fields = controls.slice(0,150).map((e,i) => {
   const token=prefix+'-'+i;e.setAttribute('data-stack-autofill',token);
   const kind=e.tagName==='SELECT'?'select':e.tagName==='TEXTAREA'?'textarea':e.getAttribute('role')==='combobox'?'combobox':(e.type || 'text');
   return {token,kind,label:label(e),id:e.id,name:e.getAttribute('name') || '',automation:e.getAttribute('data-automation-id') || '',
     autocomplete:e.getAttribute('autocomplete') || '',required:e.required || e.getAttribute('aria-required')==='true',
     disabled:e.disabled || e.readOnly || e.getAttribute('aria-disabled')==='true',
     has_value:kind==='checkbox'||kind==='radio'?e.checked:kind==='select'?!!e.value:kind==='combobox'?!!(e.value || e.getAttribute('aria-valuetext')):!!e.value,
     options:kind==='select'?[...e.options].filter(o=>!o.disabled).map(o=>({value:o.value,label:clean(o.textContent)})):[],
     option_label:kind==='radio'?clean([... (e.labels || [])].map(l=>l.textContent).join(' ')):'',
     signature:JSON.stringify([e.tagName,e.type,e.id,e.getAttribute('name'),label(e)])};
 });
 return {login:false,fields,truncated:controls.length>150};
}'''


def saved_values(facts):
    """Conflicting duplicate keys are unavailable. Never derive names or personal facts."""
    values = {}
    conflicts = set()
    for fact in facts:
        if fact.get('verified') is not True:
            continue
        key, value = fact.get('key', ''), fact.get('value', '')
        if not isinstance(key, str) or not isinstance(value, str) or not value.strip() or len(value) > 8000:
            continue
        if key in values and values[key] != value:
            conflicts.add(key)
        values[key] = value
    return {k: v for k, v in values.items() if k not in conflicts}


def match_field(field, family, values):
    label = normalize(field['label'])
    if private_or_consent(field):
        return None
    if field['kind'] in ('password', 'hidden', 'submit', 'button', 'file', 'checkbox', 'radio') or field['disabled']:
        return None
    exact = answer_key(label) if label else ''
    if exact in values:
        return exact
    aliases = [key for key, names in ALIASES.items() if label in names]
    if len(aliases) == 1:
        return aliases[0] if aliases[0] in values else None
    # A meaningful unknown question must never be overridden by autocomplete or a misleading ID.
    if label:
        return None
    keys = {IDENTIFIERS[family].get(field.get(k, '')) for k in ('id', 'name', 'automation')}
    keys.discard(None)
    if len(keys) == 1:
        key = keys.pop()
        return key if key in values else None
    key = AUTOCOMPLETE.get(field.get('autocomplete', ''))
    return key if not keys and key in values else None


def private_or_consent(field):
    return field.get('autocomplete') == 'one-time-code' or any(word in normalize(field['label']).split() for word in
        ('password', 'consent', 'agree', 'certify', 'signature', 'terms', 'verification', 'otp', 'passcode', 'pin'))


def challenge_resource(url):
    """Known challenge resources only; never a general-purpose navigation escape."""
    try:
        p = urlsplit(url)
        return p.scheme == 'https' and not p.username and not p.password and p.port in (None, 443) and (
            p.hostname in ('www.google.com', 'www.gstatic.com') and p.path.startswith('/recaptcha/') or
            p.hostname in ('hcaptcha.com', 'newassets.hcaptcha.com', 'imgs.hcaptcha.com', 'api.hcaptcha.com'))
    except (ValueError, TypeError):
        return False


def selected_option(options, value):
    matches = [o for o in options if normalize(o['label']) == normalize(value)]
    return matches[0]['value'] if len(matches) == 1 else None


def fill_page(pool, owner, run, context):
    target = application_url(context['application_url'])
    key = (owner, run)
    session = pool.sessions.get(key)
    if session is None:
        pool.guard()
        pool.operation_stage = 'create_session'
        browser_context = pool.browser.new_context(accept_downloads=False, service_workers='block', viewport={'width':430,'height':780})
        def route(request_route):
            request = request_route.request
            navigation = request.is_navigation_request()
            challenge = challenge_resource(request.url) and (not navigation or request.frame.parent_frame is not None)
            if request_allowed(request.url, navigation, target) or challenge:
                request_route.continue_()
            else:
                request_route.abort()
        browser_context.route('**/*', route)
        if hasattr(browser_context, 'route_web_socket'):
            browser_context.route_web_socket('**/*', lambda ws: ws.close())
        page = browser_context.new_page()
        page.set_default_timeout(2000)
        page.set_default_navigation_timeout(10000)
        session = {'page':page, 'context':browser_context, 'adapter':'autofill', 'url':target['url'], 'target':target, 'touched':time.time()}
        pool.sessions[key] = session
        pool.operation_stage = 'open_application'
        page.goto(target['url'], wait_until='domcontentloaded')
    if session.get('adapter') != 'autofill' or session.get('url') != target['url']:
        raise ValueError('Browser session belongs to a different task destination.')
    page = session['page']
    if not request_allowed(page.url, True, target):
        raise ValueError('The current page is outside the selected ATS.')
    values = saved_values(context.get('facts', []))
    report, requests, fields = [], [], []
    login, truncated = False, False
    session['upload_targets'] = {}
    for frame in page.frames:
        if not request_allowed(frame.url, True, target):
            continue
        pool.guard()
        pool.operation_stage = 'read_form'
        snapshot = frame.evaluate(EXTRACT_JS, secrets.token_hex(10))
        login = login or snapshot['login']
        truncated = truncated or snapshot.get('truncated', False)
        fields.extend((frame, f) for f in snapshot['fields'])
    # A login form in any ATS frame blocks filling the whole page, including email fields.
    if login:
        fields = []
    candidates = [(frame, f, match_field(f, target['family'], values)) for frame, f in fields]
    # Repeated canonical fields often belong to multiple employment/education records: do not guess.
    counts = {}
    for _, f, source in candidates:
        if source:
            counts[source] = counts.get(source, 0) + 1
    written = []
    for frame, field, source in candidates:
        pool.guard()
        # Login or MFA can appear as a consequence of a previous field's change handler.
        if any(f.locator('input[type="password"]:visible,input[autocomplete="one-time-code"]:visible').count() for f in page.frames if request_allowed(f.url, True, target)):
            login = True
            break
        entry = {'label':field['label'] or field['name'] or field['automation'] or field['kind'], 'status':'manual', 'required':bool(field['required'])}
        locator = frame.locator('[data-stack-autofill="' + field['token'] + '"]')
        if field['has_value']:
            entry['status'] = 'preserved'
        elif source and counts[source] == 1:
            pool.operation_stage = 'fill_field'
            try:
                valid = locator.evaluate(r'''(e,signature) => {
                  const clean=s=>(s||'').replace(/\s+/g,' ').trim().slice(0,400);
                  const labelText=e=>{if(!e)return '';const copy=e.cloneNode(true);copy.querySelectorAll('input,select,textarea,button,[role="combobox"]').forEach(c=>c.remove());return copy.textContent;};
                  const labelled=(e.getAttribute('aria-labelledby')||'').split(' ').map(id=>document.getElementById(id)?.textContent).join(' ');
                  const group=e.closest('fieldset,[data-automation-id="formField"]');
                  const label=clean(e.getAttribute('aria-label')||labelled.trim()||[...(e.labels||[])].map(labelText).join(' ')||labelText(group?.querySelector('legend,label'))||e.placeholder||'');
                  return JSON.stringify([e.tagName,e.type,e.id,e.getAttribute('name'),label])===signature && !e.value && !e.disabled && !e.readOnly;
                }''', field['signature'])
                if not valid:
                    entry['status'] = 'changed'
                elif field['kind'] == 'select':
                    options = locator.evaluate('(e)=>[...e.options].filter(o=>!o.disabled).map(o=>({value:o.value,label:o.textContent.trim()}))')
                    option = selected_option(options, values[source])
                    if option is not None:
                        locator.select_option(option)
                        current = locator.evaluate('(e)=>({value:e.value,label:e.selectedOptions[0]?.textContent.trim(),valid:e.checkValidity()})')
                        entry['status'] = 'filled' if current['value'] == option and normalize(current['label']) == normalize(values[source]) and current['valid'] else 'unverified'
                elif field['kind'] in ('text', 'textarea', 'email', 'tel', 'url', 'number', 'date'):
                    locator.fill(values[source])
                    entry['status'] = 'filled' if locator.input_value() == values[source] and locator.evaluate('(e)=>e.checkValidity()') else 'unverified'
                # Custom comboboxes stay manual until a widget variant has a tested adapter.
                entry['source_key'] = source
            except Exception:
                # Never expose exception text, page data or the saved value.
                entry['status'] = 'unverified'
            pool.guard()
        if entry['status'] == 'manual' and field['label'] and field['kind'] in ('text', 'textarea', 'email', 'tel', 'url', 'number', 'date', 'select') and not source and not field['disabled'] and not private_or_consent(field):
            answer = answer_key(field['label'])
            if not any(q['key'] == answer for q in requests):
                requests.append({'key':answer, 'label':field['label']})
        report.append(entry)
        if entry['status']=='filled':
            written.append((locator,field,values[source],entry))
        if field['kind']=='file' and not field['disabled'] and re.search(r'\b(resume|cv)\b', normalize(field['label'] or field['id'] or field['name'])):
            session['upload_targets'][field['token']] = (frame, field)
            entry['upload_token'] = field['token']
    # Later change handlers can clear or reinterpret previously filled controls.
    for locator, field, expected, entry in written:
        pool.guard()
        try:
            unchanged=locator.evaluate(r'''(e,signature) => {
              const clean=s=>(s||'').replace(/\s+/g,' ').trim().slice(0,400);
              const labelText=e=>{if(!e)return '';const copy=e.cloneNode(true);copy.querySelectorAll('input,select,textarea,button,[role="combobox"]').forEach(c=>c.remove());return copy.textContent;};
              const labelled=(e.getAttribute('aria-labelledby')||'').split(' ').map(id=>document.getElementById(id)?.textContent).join(' ');
              const group=e.closest('fieldset,[data-automation-id="formField"]');
              const label=clean(e.getAttribute('aria-label')||labelled.trim()||[...(e.labels||[])].map(labelText).join(' ')||labelText(group?.querySelector('legend,label'))||e.placeholder||'');
              return JSON.stringify([e.tagName,e.type,e.id,e.getAttribute('name'),label])===signature;
            }''',field['signature'])
            if field['kind']=='select':
                current=locator.evaluate('(e)=>({label:e.selectedOptions[0]?.textContent.trim(),valid:e.checkValidity()})')
                verified=normalize(current['label'])==normalize(expected) and current['valid']
            else:
                verified=locator.input_value()==expected and locator.evaluate('(e)=>e.checkValidity()')
            if not unchanged or not verified:
                entry['status']='unverified'
        except Exception:
            entry['status']='unverified'
    session['touched'] = time.time()
    session['progress'] = str(sum(f['status']=='filled' for f in report)) + ' fields filled; review in the browser'
    pool.publish(owner, run)
    message = 'Autofill paused. Take control to review, answer remaining fields, and submit yourself. Resume autofill after moving to another step.'
    if login:
        message = 'Sign in or finish verification yourself in the browser, then resume autofill. Passwords are never saved as answers.'
    if not report and not login:
        message = 'No supported visible controls found. Take control to open the application form or complete this variant yourself.'
    return {'needs_input':True, 'message':message, 'requests':[{'key':'browser','label':message}] + requests,
            'artifact':{'family':target['family'], 'fields':report, 'filled':sum(f['status']=='filled' for f in report), 'truncated':truncated, 'submission':'user_only'}}


def upload_resume(pool, owner, run, event):
    """Explicit sequenced user action; file bytes are supplied only by the owning API."""
    session = pool.sessions.get((owner,run))
    if not session or session.get('adapter') != 'autofill':
        raise ValueError('Resume upload needs this task\'s active application browser.')
    target = session.get('upload_targets',{}).get(event.get('upload_token'))
    if not target:
        raise ValueError('This file control changed. Resume autofill to inspect the current page first.')
    frame, field = target
    if not request_allowed(frame.url, True, session['target']):
        raise ValueError('File control is outside this application session.')
    pool.guard()
    locator = frame.locator('[data-stack-autofill="'+field['token']+'"]')
    if locator.count()!=1 or locator.get_attribute('type')!='file' or locator.is_disabled():
        raise ValueError('File control is unavailable. Resume autofill to inspect this page again.')
    # A later user navigation or changed label must invalidate an earlier upload target.
    snapshot = frame.evaluate(EXTRACT_JS, secrets.token_hex(10))
    matching = [f for f in snapshot['fields'] if f['signature']==field['signature'] and f['kind']=='file']
    if snapshot['login'] or len(matching)!=1:
        raise ValueError('File control changed or sign-in is required.')
    locator = frame.locator('[data-stack-autofill="'+matching[0]['token']+'"]')
    if locator.evaluate('(e)=>e.files.length'):
        raise ValueError('A file is already selected. Remove it yourself before attaching another.')
    document = event.get('document',{})
    name = str(document.get('name','')).replace('\\','/').split('/')[-1]
    mime = 'application/pdf' if name.lower().endswith('.pdf') else 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' if name.lower().endswith('.docx') else ''
    raw = base64.b64decode(document.get('content',''),validate=True)
    if not mime or not 0<len(raw)<=8*1024*1024:
        raise ValueError('Attach a PDF or DOCX resume of at most 8 MB.')
    pool.guard()
    locator.set_input_files({'name':name, 'mimeType':mime, 'buffer':raw})
    verified = locator.evaluate('(e)=>[...e.files].map(f=>({name:f.name,size:f.size}))')
    if verified != [{'name':name,'size':len(raw)}]:
        raise ValueError('The selected file could not be confirmed. Review it in the browser.')
    session['upload_targets'] = {}
    session['touched'] = time.time()
    return pool.publish(owner,run)
