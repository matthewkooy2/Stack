"""Public app links and the browser-to-iPhone sign-in handoff. No credentials or sessions in URLs."""
from html import escape
from http.cookies import SimpleCookie, CookieError
import json
import os
import re
from urllib.parse import parse_qs, urlencode, urlsplit

SCHEME = 'com.matthewkooy.stack'
COOKIE = 'stack_native_signin'
DESTINATIONS = {'jobs', 'applications', 'resume', 'network', 'prep'}
APP_ID = '38BZ2B7677.com.matthewkooy.stack'


def native_start(path: str) -> tuple[str, str]:
    """Accept only an identity-only Google URL returning to this configured gateway."""
    if len(path) > 8192:
        raise ValueError('Invalid sign-in URL')
    query = parse_qs(urlsplit(path).query, keep_blank_values=True, max_num_fields=2)
    if set(query) != {'url'} or len(query['url']) != 1:
        raise ValueError('Invalid sign-in URL')
    provider = urlsplit(query['url'][0])
    args = parse_qs(provider.query, keep_blank_values=True, max_num_fields=30)
    origin = urlsplit(os.environ.get('STACK_SSO_CALLBACK_URL', ''))
    callback = urlsplit(args.get('redirect_uri', [''])[0])
    if (provider.scheme != 'https' or provider.netloc != 'accounts.google.com'
            or provider.path != '/o/oauth2/v2/auth' or provider.fragment
            or any(len(value) != 1 for value in args.values())
            or set(args.get('scope', [''])[0].split()) != {'openid', 'email', 'profile'}
            or args.get('code_challenge_method') != ['S256']
            or args.get('response_type') != ['code']
            or not re.fullmatch(r'[A-Za-z0-9_-]{43}', args.get('state', [''])[0])
            or origin.scheme != 'https' or not origin.netloc
            or callback.scheme != origin.scheme or callback.netloc != origin.netloc
            or callback.path != '/sso/google/callback' or callback.query or callback.fragment):
        raise ValueError('Invalid sign-in URL')
    cookie = f'{COOKIE}={args["state"][0]}; Max-Age=600; Path=/sso/google/callback; Secure; HttpOnly; SameSite=Lax'
    return query['url'][0], cookie


def native_return(cookie_header: str, state: str) -> str:
    """Only a sheet that started this state gets an automatic app redirect; older clients keep a page."""
    try:
        cookies = SimpleCookie()
        cookies.load(cookie_header)
        if (re.fullmatch(r'[A-Za-z0-9_-]{43}', state)
                and COOKIE in cookies and cookies[COOKIE].value == state):
            return f'{SCHEME}://auth/google?' + urlencode({'state': state})
    except CookieError:
        pass
    return ''


def association() -> bytes:
    # Limit opening to explicit /open links. Never intercept Google's server callback.
    return json.dumps({'applinks': {'details': [{'appIDs': [APP_ID],
        'components': [{'/': '/open'}, {'/': '/open/*'}]}]}}).encode()


def banner() -> str:
    # Populate after verifying the App Store record. A TestFlight-only app won't display Apple's banner.
    app_id = os.environ.get('STACK_APP_STORE_ID', '6820196890')
    configured = urlsplit(os.environ.get('STACK_SSO_HOST') or os.environ.get('STACK_SSO_CALLBACK_URL', ''))
    if (not re.fullmatch(r'\d{6,15}', app_id) or configured.scheme != 'https'
            or not configured.hostname or configured.username or configured.password):
        return ''
    origin = f'{configured.scheme}://{configured.netloc}'
    return f'<meta name="apple-itunes-app" content="app-id={app_id}, app-argument={escape(origin, quote=True)}/open">'


def page(success: bool | None = None, destination: str = '', home: bool = False) -> bytes:
    """Accessible fallback for ordinary browsers and old installed clients; no provider data echoed."""
    if destination not in DESTINATIONS:
        destination = ''
    title = 'Pick up in Stack.' if success is None else ('You’re signed in.' if success else 'Let’s try that again.')
    detail = ('Open Stack on your iPhone to continue.' if success is None else
              'Your iPhone app is ready. Continue in Stack.' if success else
              'Google sign-in didn’t finish. Open Stack to try again.')
    if home:
        title = 'Your next chapter.'
        detail = 'Find jobs, shape your resume and practice for interviews. Stack brings your career tools together on your iPhone and the web.'
    href = f'{SCHEME}://open' + (f'/{destination}' if destination else '')
    page_title = 'Stack · Your next chapter' if home else 'Continue in Stack'
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light"><title>{page_title}</title>{banner()}
<style>*{{box-sizing:border-box}}body{{margin:0;background:#f5f3f0;color:#111;font-family:-apple-system,BlinkMacSystemFont,sans-serif;min-height:100svh;display:grid;place-items:center;padding:32px 24px}}main{{width:100%;max-width:420px}}.brand{{font-size:20px;font-weight:800;letter-spacing:-.6px;margin:0 0 64px}}h1{{font-size:clamp(36px,10vw,48px);line-height:1.06;letter-spacing:-2px;margin:0 0 18px;font-weight:800}}p{{font-size:17px;line-height:1.5;color:#5e5c58;margin:0 0 36px}}a{{display:flex;align-items:center;justify-content:center;min-height:58px;border-radius:16px;background:#2563ff;color:white;text-decoration:none;font-size:17px;font-weight:600;padding:16px}}a:focus-visible{{outline:3px solid #111;outline-offset:5px}}.secondary{{background:transparent;color:#5e5c58;font-size:15px;margin-top:12px}}</style>
</head><body><main><div class="brand">Stack</div><h1>{title}</h1><p>{detail}</p>
<a href="{href}">Continue in Stack</a><a class="secondary" href="/">Continue on the web</a>
<a class="secondary" href="/privacy">Privacy</a>
</main></body></html>'''.encode()


def privacy_page() -> bytes:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Stack · Privacy</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; background: #f5f3f0; color: #111; font: 17px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; }
    main { max-width: 720px; margin: auto; padding: 56px 24px 80px; }
    a { color: #2563ff; text-underline-offset: 4px; }
    h1 { font-size: 44px; line-height: 1.1; letter-spacing: -2px; margin: 48px 0 20px; }
    h2 { font-size: 22px; line-height: 1.3; margin-top: 32px; }
    p, li { color: #5e5c58; }
    a:focus-visible { outline: 3px solid #2563ff; outline-offset: 4px; }
  </style>
</head>
<body><main>
  <a href="/">Stack</a>
  <h1>Your information in Stack.</h1>
  <p>Last updated November 2, 2026. Stack is a personal career and interview-preparation project operated by Matthew Kooy. This page describes the information its features use, including its Google connections.</p>
  <h2>Signing in</h2>
  <p>Google sign-in requests your basic identity: your Google account identifier, email address and profile information. Stack uses this information to create or find your Stack account. Signing in does not grant Stack access to Gmail or Google Calendar. Apple sign-in uses your Apple account identifier and the email address Apple shares with Stack.</p>
  <h2>Information you add</h2>
  <p>Stack stores the profile, career preferences, resumes, saved jobs, applications, contacts, notes and reminders you add. Interview practice can include audio recordings, transcripts and coaching. This information is used to provide the features you choose. Account data and uploaded files are stored on Stack’s backend; the iPhone app also keeps session credentials and local caches or drafts.</p>
  <h2>Optional Google connections</h2>
  <p>Gmail and Google Calendar are separate, optional connections. When you choose to connect them, the Google consent screen lists the permissions requested. These features can read relevant messages, draft or send email, and read or create calendar events according to the permissions you grant and actions or agent policies you authorize. Google connection credentials are stored by Stack to maintain the connection. You can disconnect a service in Stack or revoke access in your Google account settings.</p>
  <h2>Processing your requests</h2>
  <p>Resume and interview features send the material needed for your request to the model or transcription service configured for Stack. Depending on that configuration, processing can occur locally or through an external provider. Connected job, browser and email services receive the information needed for the actions you request. Avoid adding information you do not want processed by these features.</p>
  <h2>Your controls</h2>
  <p>You can edit your saved information and use Stack’s account export and deletion controls. Account deletion removes active account data and files; it does not promise immediate erasure from every operational log or existing backup. Signing out clears the app’s active session. For questions or help with access, export or deletion, contact <a href="mailto:kooymatthew@gmail.com">kooymatthew@gmail.com</a>.</p>
  <p><a href="/open">Continue in Stack</a></p>
</main></body>
</html>
""".encode()
