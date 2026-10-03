"""User-requested LinkedIn profile capture. Login stays in an ephemeral browser."""
import re;
import time;
import from urllib.parse { urlsplit, unquote }
with entry {
    SECTIONS = (
        'intro',
        'about',
        'experience',
        'education',
        'skills',
        'projects',
        'certifications',
        'featured',
        'recommendations'
    );
    LIMITATIONS = 'Only visible profile text was captured. Unread sections may be hidden, collapsed, or unavailable; '
    'they are not confirmed missing. Photos, banners, private recruiter settings, search ranking, '
    'and recruiter response rates were not evaluated.';
}

"""Accept an explicit profile only, never an arbitrary browser destination."""
def profile_url(value: str) -> str {
    try {
        url = urlsplit(str(value).strip());
        if (
            (url.scheme != 'https')
            or (url.hostname not in ('linkedin.com', 'www.linkedin.com'))
            or url.username
            or url.password
            or (url.port not in (None, 443))
            or not re.fullmatch(r'/in/[A-Za-z0-9_%\-]+/?', url.path)
            or not re.fullmatch(r'[\w-]+', unquote(url.path)[4:].rstrip('/'))
        ) {
            raise ValueError();
        }
    } except ValueError {
        raise ValueError(
            'Enter your LinkedIn profile URL: https://www.linkedin.com/in/your-name/'
        ) from None;
    }
    return ('https://www.linkedin.com' + url.path.rstrip('/') + '/');
}
def browser_request_allowed(url: any, navigation: any = False) -> any {
    try {
        parsed = urlsplit(url);
        host = parsed.hostname or '';
        return (
            (parsed.scheme == 'https')
            and not parsed.username
            and not parsed.password
            and (parsed.port in (None, 443))
            and (
                (host == 'linkedin.com')
                or host.endswith('.linkedin.com')
                or (
                    not navigation
                    and ((host == 'licdn.com') or host.endswith('.licdn.com'))
                )
            )
        );
    } except ValueError {
        return False;
    }
}
with entry {
    CAPTURE_JS = r'''() => {
 const main = document.querySelector('main, [role="main"]');
 if (!main) return {};
 const visible = e => e && e.getBoundingClientRect().width && e.getBoundingClientRect().height;
 const card = e => {
   const found = e?.closest('section, .artdeco-card, [data-view-name="profile-top-card"]');
   if (found && found !== main && main.contains(found)) return found;
   const parent = e?.parentElement;
   return parent?.parentElement !== main ? parent?.parentElement : parent;
 };
 const text = e => {
   if (!visible(e) || e === main) return '';
   const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);
   const parts=[];let node;
   while((node=walker.nextNode())) {
    const parent=node.parentElement;
    if(!parent || parent.closest('input,textarea,select,script,style,nav,aside,[role="dialog"],.msg-overlay-container,[aria-hidden="true"]')) continue;
    const style=getComputedStyle(parent);
    if(style.visibility==='hidden' || !parent.getClientRects().length) continue;
    parts.push(node.textContent);
   }
   return parts.join(' ').replace(/\s+/g,' ').trim().slice(0,6000);
 };
 const headings=[...main.querySelectorAll('h1,h2,[role="heading"]')].filter(visible);
 const heading=headings.find(e=>e.matches('h1,[aria-level="1"]')) || headings[0];
 const labels={about:'About',experience:'Experience',education:'Education',skills:'Skills',projects:'Projects',
   certifications:'Licenses & certifications',featured:'Featured',recommendations:'Recommendations'};
 const out={};
 if (heading && !Object.values(labels).includes(heading.textContent.trim())) {
   const intro=text(card(heading)); if(intro) out.intro=intro;
 }
 const ids={about:'about',experience:'experience',education:'education',skills:'skills',projects:'projects',
   certifications:'licenses_and_certifications',featured:'featured',recommendations:'recommendations'};
 for(const [key,id] of Object.entries(ids)) {
   const marker=main.querySelector('[id="'+id+'"]') || headings.find(e=>e.textContent.trim()===labels[key]);
   const value=text(card(marker)); if(value) out[key]=value;
 }
 return out;
}''';
    EXPAND_JS = r'''() => {
 const main=document.querySelector('main, [role="main"]'); if(!main) return;
 let count=0;
 for(const section of main.querySelectorAll('section,.artdeco-card')) {
  if(!section.querySelector('#about,#experience,#education,#skills,#projects,#licenses_and_certifications,#featured,#recommendations,h2')) continue;
  for(const button of section.querySelectorAll('button')) {
   if(count<3 && /^(…?\s*see more|show more)$/i.test(button.innerText.trim()) && button.getBoundingClientRect().height) {
    button.click();count++;
   }
  }
 }
}''';
}

def snapshot(url: any, sections: any) -> any {
    clean = {};
    remaining = 24000;
    for key in SECTIONS {
        value = str(sections.get(key, '')).strip()[:min(6000, remaining)];
        if value {
            clean[key] = value;
            remaining -= len(value);
        }
    }
    if not clean.get('intro') {
        raise ValueError(
            'The profile header could not be read. Open your profile in the browser and resume.'
        );
    }
    return {
        'url': profile_url(url),
        'captured_at': time.time(),
        'sections': clean,
        'unread_sections': [
            key
            for key in SECTIONS
            if (key not in clean)
        ],
        'limitations': LIMITATIONS,
        'summary': ('Captured ' + str(len(clean)) + ' visible profile sections.')
    };
}
def needs_login(
    message: any = 'Sign in if LinkedIn asks, confirm this is your profile, then choose “Analyze my profile”.'
) -> any {
    return {
        'needs_input': True,
        'message': message,
        'requests': [
            {
                'key': 'browser',
                'label': 'Open the same browser session. Enter login and verification codes there, never in task answers.'
            }
        ]
    };
}
def scan(pool: any, owner: any, run: any, context: any) -> any {
    url = profile_url(context['linkedin_url']);
    key = (owner, run);
    value = pool.sessions.get(key);
    if (value is None) {
        browser_context = pool.browser.new_context(
            accept_downloads=False,
            service_workers='block',
            viewport={'width': 430, 'height': 780}
        );
        import from discovery.transport { public_url }
        def route(route: any) -> any {
            request = route.request;
            try {
                if not browser_request_allowed(
                    request.url, request.is_navigation_request()
                ) {
                    route.abort();
                    return;
                }
                public_url(request.url);
                route.continue_();
            } except Exception {
                route.abort();
            }
        }
        browser_context.route('**/*', route);
        if hasattr(browser_context, 'route_web_socket') {
            browser_context.route_web_socket('**/*', lambda (ws: any) { ws.close(); });
        }
        page = browser_context.new_page();
        page.set_default_timeout(2000);
        page.set_default_navigation_timeout(5000);
        value = {
            'page': page,
            'context': browser_context,
            'adapter': 'linkedin',
            'touched': time.time(),
            'url': url
        };
        pool.sessions[key] = value;
        try {
            pool.guard();
            page.goto(
                'https://www.linkedin.com/login',
                wait_until='domcontentloaded',
                timeout=5000
            );
        } except Exception {
            return needs_login(
                'LinkedIn did not finish loading. Open the browser, refresh the profile, and try again.'
            );
        }
        pool.guard();
        pool.publish(owner, run);
        return needs_login();
    }
    if ((value.get('adapter') != 'linkedin') or (value.get('url') != url)) {
        raise ValueError('This browser session does not match the requested profile.');
    }
    page = value['page'];
    value['touched'] = time.time();
    if not `any(
        ((c.get('name') == 'li_at') and c.get('value'))
        for c in value['context'].cookies('https://www.linkedin.com')
    ) {
        return needs_login(
            'Sign in to LinkedIn in the agent browser below, then confirm this is your profile.'
        );
    }
    try {
        current = profile_url(page.url);
    } except ValueError {
        current = '';
    }
    if (current != url) {
        pool.guard();
        page.goto(url, wait_until='domcontentloaded', timeout=5000);
    }
    try {
        current = profile_url(page.url);
    } except ValueError {
        return needs_login(
            'Finish LinkedIn sign-in or its verification challenge in the browser, then resume.'
        );
    }
    if (
        (current != url)
        or page.locator('input[type="password"], iframe[src*="captcha"]').count()
    ) {
        return needs_login(
            'Finish LinkedIn sign-in or its verification challenge in the browser, then resume.'
        );
    }
    value['progress'] = 'Opening your profile';
    pool.guard();
    page.evaluate('window.scrollTo(0, 0)');
    pool.guard();
    pool.publish(owner, run);
    hydrated=False;
    for attempt in range(15) {
        pool.guard();
        try {
            page.wait_for_function(('() => Boolean((' + CAPTURE_JS + ')().intro)'),timeout=1000);
            hydrated=True;break;
        } except Exception { ; }
    }
    if not hydrated {
        return needs_login('LinkedIn has not loaded a readable profile yet. Check the browser below, open your profile, then retry analysis.');
    }
    sections = {};
    for index in range(16) {
        value['progress'] = f'Reading profile · {(index + 1)} of 16';
        try {
            if (profile_url(page.url) != url) {
                return needs_login(
                    'LinkedIn left the requested profile. Open your profile and retry analysis.'
                );
            }
        } except ValueError {
            return needs_login(
                'LinkedIn redirected away from your profile. Finish any verification, then retry analysis.'
            );
        }
        pool.guard();
        page.evaluate(EXPAND_JS);
        for (name, text) in page.evaluate(CAPTURE_JS).items() {
            if (len(text) > len(sections.get(name, ''))) {
                sections[name] = text;
            }
        }
        pool.guard();
        page.mouse.wheel(0, 650);
        pool.guard();
        for slice_index in range(3) { pool.guard();page.wait_for_timeout(250); }
        pool.guard();
        pool.publish(owner, run);
    }
    try {
        artifact = snapshot(url, sections);
    } except ValueError as exc {
        return needs_login(str(exc));
    }
    pool.close(owner, run);
    return {'artifact': artifact};
}
"""Each weakness must cite a captured section, not an inferred missing section."""
def validate_review(data: any, capture: any, sources: any) -> any {
    findings = data.get('findings');
    if (not isinstance(findings, `list) or (len(findings) > 12)) {
        raise ValueError('Use at most twelve evidence-backed findings.');
    }
    for finding in findings {
        section = finding.get('section');
        quote = finding.get('quote');
        if (
            (section not in capture.get('sections', {}))
            or not isinstance(quote, str)
            or not quote.strip()
            or (quote not in capture['sections'][section])
            or (finding.get('priority') not in ('high', 'medium', 'low'))
            or `any(
                (not isinstance(finding.get(k), str) or not finding[k].strip())
                for k in ('weakness', 'why_it_matters', 'recommendation')
            )
        ) {
            raise ValueError('A profile finding has no matching captured evidence.');
        }
    }
    for rewrite in data.get('rewrites', []) {
        if (
            (rewrite.get('section') not in ('headline', 'about', 'experience'))
            or not rewrite.get('text')
        ) {
            raise ValueError('Invalid profile rewrite.');
        }
        evidence = rewrite.get('evidence', []);
        if (
            not evidence
            or `any(
                not e.get('source', '').startswith(('linkedin:', 'fact:'))
                for e in evidence
            )
        ) {
            raise ValueError('A rewrite must cite the facts it uses.');
        }
        import from agents.contracts { validate_evidence }
        validate_evidence(evidence, sources);
    }
    data['findings'] = sorted(
        findings,
        key=lambda (item: any) { ('high', 'medium', 'low').index(item['priority']); }
    );
    data['unread_sections'] = capture.get('unread_sections', []);
    data['limitations'] = capture['limitations'];
    data['profile_url'] = capture['url'];
    data['captured_at'] = capture['captured_at'];
    return data;
}
