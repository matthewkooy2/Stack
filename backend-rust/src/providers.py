"""Adapter for the released fixed-origin provider transports. Codes and tokens use stdin."""
import json
from pathlib import Path
import secrets
import sys
root=Path(sys.argv[1]).resolve()
sys.path[:0]=[str(root),str(root/'score-docs')]

def perform(a):
    if a['op']=='validate_page':
        from agents.mail_scan import validate_discovery
        page=a['page']
        events=page.get('events',[])
        if (type(page.get('done')) is not bool or type(page.get('scanned')) is not int or not 0<=page['scanned']<=1 or
            not isinstance(events,list) or len(events)>1 or not isinstance(page.get('scan_cursor'),str) or (not page['done'] and not page['scan_cursor'])):
            raise ValueError('Gmail returned an invalid scan page. Start a new scan.')
        for e in events:
            if not str(e.get('key','')) or not a['context']['since']<=float(e.get('at',-1))<=a['context']['until']:
                raise ValueError('Gmail returned a message outside the scan dates.')
            if e.get('discovery'):
                d=e['discovery']
                checked=validate_discovery({**d,'decision':'confirmed' if d.get('confirmed') else 'uncertain'},str(e.get('excerpt','')))
                e.update(discovery=checked,ambiguous=not checked['confirmed'],status=checked['status'],quote=checked['quote'])
        return {'events':events}
    if a['op']=='match_application':
        from agents.mail_scan import identity,snapshot
        d=a['discovery']
        company,title,ref=d['company'],d['title'],d.get('reference','')
        target=identity(company,title,ref)
        matching=[]
        for item in a['items']:
            entry=identity(item.get('company') or '',item.get('title') or '',item.get('reference') or '')
            if entry[:2]==target[:2] and not (entry[2] and target[2] and entry[2]!=target[2]):
                matching.append(item['id'])
        if len(matching)>1: return {'conflict':True}
        if matching: return {'id':matching[0]}
        return {'snapshot':snapshot(company,title,ref,a['thread'])}
    from agents import security
    if a['op']=='deliver':
        from agents import notifications
        return {'worked':process(a['path'],notifications,security.unseal)}
    if a['op']=='seal_push':
        return {'sealed':security.seal({'token':a['device']})}
    from agents import google
    if a['op']=='revoke':
        google.revoke(security.unseal(a['sealed']))
        return {'revoked':True}
    if a['op']=='refresh':
        tokens=google.refreshed(security.unseal(a['sealed']))
        return {'sealed':security.seal(tokens),'tokens':{'access_token':tokens['access_token'],'expires_at':tokens.get('expires_at',0)}}
    if a['op']=='google_start':
        verifier=secrets.token_urlsafe(48)
        sealed=security.seal({'verifier':verifier})
        return {'sealed':sealed,'url':google.authorization_url(a['state'],verifier,a['capabilities'])}
    if a['op']=='google_finish':
        try:
            tokens=google.exchange(a['code'],security.unseal(a['sealed'])['verifier'])
            sealed=security.seal(tokens)
        except Exception:
            raise ValueError('Google authorization failed. Start a new connection.') from None
        scopes=str(tokens.get('scope','')).split()
        if any(google.SCOPES[cap] not in scopes for cap in a['capabilities']):
            raise ValueError('Google did not grant the requested access. Connect again and allow access to continue.')
        return {'sealed':sealed,'scopes':scopes}
    raise ValueError('Unknown provider operation.')

try:
    print(json.dumps(perform(json.load(sys.stdin))))
except (ValueError,ImportError,KeyError) as exc:
    print(json.dumps({'error':str(exc) if isinstance(exc,ValueError) else 'Provider integration is unavailable.'}))
