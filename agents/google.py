"""Google OAuth, Gmail and Calendar transport. No graph access."""
import base64
from email.message import EmailMessage
from email.utils import parseaddr
import hashlib
import json
import os
import re
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from urllib.parse import urlencode, quote
from typing import Any
from agents.security import http, b64url

SCOPES = {'read': 'https://www.googleapis.com/auth/gmail.readonly',
          'send': 'https://www.googleapis.com/auth/gmail.send',
          'calendar': 'https://www.googleapis.com/auth/calendar.app.created',
          'availability': 'https://www.googleapis.com/auth/calendar.freebusy'}


def authorization_url(state: str, verifier: str, capabilities: list[str]) -> str:
    if not set(capabilities) <= set(SCOPES):
        raise ValueError('Unsupported Google capability.')
    client = os.environ.get('GOOGLE_CLIENT_ID', '')
    redirect = os.environ.get('GOOGLE_REDIRECT_URI', '')
    if not client or not redirect.startswith('https://'):
        raise ValueError('Google integration needs a client ID and HTTPS redirect URL.')
    return 'https://accounts.google.com/o/oauth2/v2/auth?' + urlencode({
        'client_id': client, 'redirect_uri': redirect, 'response_type': 'code',
        'scope': ' '.join(SCOPES[x] for x in capabilities), 'state': state,
        'code_challenge': b64url(hashlib.sha256(verifier.encode()).digest()),
        'code_challenge_method': 'S256', 'access_type': 'offline',
        'include_granted_scopes': 'true', 'prompt': 'consent'})


def exchange(code: str, verifier: str) -> dict[str, Any]:
    result = http('https://oauth2.googleapis.com/token', urlencode({
        'client_id': os.environ['GOOGLE_CLIENT_ID'], 'client_secret': os.environ['GOOGLE_CLIENT_SECRET'],
        'redirect_uri': os.environ['GOOGLE_REDIRECT_URI'], 'grant_type': 'authorization_code',
        'code': code, 'code_verifier': verifier}).encode(), {'Content-Type': 'application/x-www-form-urlencoded'})
    if not result.get('refresh_token'):
        raise ValueError('Offline access was not granted. Reconnect with consent.')
    result['expires_at'] = time.time() + result.get('expires_in', 3600)
    return result


def refreshed(tokens: dict[str, Any]) -> dict[str, Any]:
    if tokens.get('expires_at', 0) > time.time() + 90:
        return tokens
    result = http('https://oauth2.googleapis.com/token', urlencode({
        'client_id': os.environ['GOOGLE_CLIENT_ID'], 'client_secret': os.environ['GOOGLE_CLIENT_SECRET'],
        'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token']}).encode(),
        {'Content-Type': 'application/x-www-form-urlencoded'})
    return {**tokens, **result, 'expires_at': time.time() + result.get('expires_in', 3600)}


def revoke(tokens: dict[str, Any]) -> None:
    http('https://oauth2.googleapis.com/revoke', urlencode({'token': tokens.get('refresh_token', tokens.get('access_token', ''))}).encode(), {'Content-Type': 'application/x-www-form-urlencoded'})


def request(tokens, path, body=None, method=None):
    return http('https://gmail.googleapis.com/gmail/v1/users/me/' + path, body,
                {'Authorization': 'Bearer ' + tokens['access_token'], 'Content-Type': 'application/json'}, method=method)


def send(tokens, contact, draft, action_id, thread_id=''):
    if not contact.get('selected') or contact.get('stopped') or not contact.get('email'):
        raise ValueError('Select a verified recipient before sending.')
    message = EmailMessage()
    for text in (contact['email'], draft['subject']):
        if '\r' in text or '\n' in text:
            raise ValueError('Invalid email header.')
    message['To'] = contact['email']
    message['Subject'] = draft['subject'][:200]
    message['Message-ID'] = '<stack.' + hashlib.sha256(action_id.encode()).hexdigest() + '@stack.invalid>'
    message.set_content(draft['body'][:10000])
    body = {'raw': b64url(message.as_bytes())}
    if thread_id:
        body['threadId'] = thread_id
    result = request(tokens, 'messages/send', body)
    if not result.get('id'):
        raise ValueError('Gmail did not return a send receipt.')
    return {'receipt': result['id'], 'thread_id': result.get('threadId', ''), 'message_id': str(message['Message-ID']), 'at': time.time()}


def body_text(payload):
    if payload.get('mimeType') in ('text/plain', 'text/html') and payload.get('body', {}).get('data'):
        data = payload['body']['data']
        value = base64.urlsafe_b64decode(data + '=' * (-len(data) % 4)).decode(errors='replace')[:60000]
        if payload.get('mimeType') == 'text/html':
            from html import unescape
            value = unescape(re.sub(r'<[^>]+>', ' ', re.sub(r'<(script|style)\b[^>]*>.*?</\1>', '', value, flags=re.S | re.I)))
        return value[:12000]
    return '\n'.join(body_text(p) for p in payload.get('parts', []))[:12000]


def classify(message, applications, interviews=None):
    headers = {h['name'].lower(): h['value'] for h in message.get('payload', {}).get('headers', [])}
    sender = parseaddr(headers.get('from', ''))[1].lower()
    text = headers.get('subject', '') + '\n' + body_text(message.get('payload', {}))
    lower = text.lower()
    # Resolve one tracked opening; a company alone is insufficient when multiple jobs match.
    matches = [a for a in applications if a['job']['company'].lower() in lower and a['job']['title'].lower() in lower]
    patterns = [('Rejected', r'(?:will not be moving forward|not moving forward|regret to inform|pursue other candidates)'),
                ('Interview', r'(?:invite you to (?:an |a )?interview|schedule (?:an |a )?interview)'),
                ('Assessment', r'(?:complete (?:the |an |a )?(?:coding |technical )?assessment)'),
                ('Submitted', r'(?:received your application|thank you for applying|application has been received)')]
    found = [(status, re.search(pattern, text, re.I)) for status, pattern in patterns]
    found = [(status, match) for status, match in found if match]
    status = found[0][0] if len(found) == 1 else ''
    calendar = calendar_attachment(message.get('payload', {}))
    linked = [i for i in (interviews or []) if i['key'] == calendar.get('uid')]
    if len(linked) == 1:
        matches = [{'id': linked[0]['application_id']}]
    if calendar and (len(linked) == 1 or 'interview' in calendar.get('summary', '').lower()) and not status:
        status = 'Interview'
    ambiguous = len(matches) != 1 or not status or len(found) > 1
    return {'key': message['id'], 'thread_id': message.get('threadId', ''), 'sender': sender,
            'subject': headers.get('subject', '')[:300], 'at': int(message.get('internalDate', 0)) / 1000,
            'application_id': matches[0]['id'] if len(matches) == 1 else '',
            'status': status, 'ambiguous': ambiguous,
            'quote': found[0][1].group(0) if len(found) == 1 else ('Calendar invitation: ' + calendar.get('uid', '') if calendar else ''), 'excerpt': text[:2000],
            'calendar': calendar}


def calendar_attachment(payload):
    """Unambiguous UTC or IANA-zone invites; DST gaps/overlaps require user input."""
    if payload.get('mimeType') == 'text/calendar' and payload.get('body', {}).get('data'):
        data = payload['body']['data']
        text = base64.urlsafe_b64decode(data + '=' * (-len(data) % 4)).decode(errors='replace')
        fields = {};zones = {}
        if text.count('BEGIN:VEVENT') > 1: return {}
        for line in text.replace('\r\n ', '').splitlines():
            key, sep, value = line.partition(':')
            parts = key.split(';');key = parts[0]
            zones[key] = next((p.split('=', 1)[1] for p in parts[1:] if p.startswith('TZID=')), '')
            if sep and key in ('UID', 'DTSTART', 'DTEND', 'SUMMARY', 'LOCATION', 'STATUS'):
                fields[key] = value[:1000]
        try:
            def parse(key):
                value = fields[key]
                if zones[key] and value.endswith('Z'): raise ValueError('Conflicting timezone definitions')
                if value.endswith('Z'): return datetime.strptime(value, '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
                local = datetime.strptime(value, '%Y%m%dT%H%M%S')
                zone = ZoneInfo(zones[key]);first = local.replace(tzinfo=zone, fold=0);second = local.replace(tzinfo=zone, fold=1)
                if first.utcoffset() != second.utcoffset() or first.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) != local:
                    raise ValueError('Ambiguous or nonexistent local time')
                return first.astimezone(timezone.utc)
            start = parse('DTSTART').isoformat();end = parse('DTEND').isoformat()
            if end <= start or not fields.get('UID'):
                return {}
            return {'uid': fields['UID'], 'summary': fields.get('SUMMARY', 'Interview'),
                    'start': {'dateTime': start}, 'end': {'dateTime': end},
                    'location': fields.get('LOCATION', ''), 'status': 'cancelled' if fields.get('STATUS') == 'CANCELLED' else 'confirmed'}
        except (ValueError, KeyError):
            return {}
    for child in payload.get('parts', []):
        event = calendar_attachment(child)
        if event:
            return event
    return {}


def hydrate_calendar(tokens, message_id, payload):
    body = payload.get('body', {})
    if payload.get('mimeType') == 'text/calendar' and body.get('attachmentId') and body.get('size', 0) <= 128000:
        payload['body'] = request(tokens, 'messages/' + quote(message_id, safe='') + '/attachments/' + quote(body['attachmentId'], safe=''))
    for child in payload.get('parts', []): hydrate_calendar(tokens, message_id, child)


def synchronize(tokens, checkpoint, applications, contacts, interviews=None):
    seen_order = list(checkpoint.get('seen', []))
    seen = set(seen_order)
    query_parts = []
    for a in applications:
        company = re.sub(r'[^\w .-]', '', a['job']['company'])
        if company:
            query_parts.append('"' + company + '"')
    query_parts.extend('from:' + c['email'] for c in contacts if c.get('email'))
    if not query_parts:
        return {'events': [], 'checkpoint': checkpoint}
    q = 'newer_than:30d {' + ' '.join(query_parts[:80]) + '}'
    # History is the incremental path. A stale history cursor falls back to bounded search.
    history = checkpoint.get('history_id', '')
    scan_start = checkpoint.get('scan_start', '')
    entries = None
    fallback = False
    if history:
        try:
            result = request(tokens, 'history?' + urlencode({'startHistoryId': history, 'historyTypes': 'messageAdded', 'maxResults': 100, 'pageToken': checkpoint.get('page_token', '')}))
            entries = [item['message'] for h in result.get('history', []) for item in h.get('messagesAdded', [])]
        except ValueError:
            entries = None;fallback = True;history = ''
    if entries is None:
        if not scan_start or fallback:
            scan_start = str(request(tokens, 'profile').get('historyId', ''))
        result = request(tokens, 'messages?' + urlencode({'q': q, 'maxResults': 100, 'pageToken': '' if fallback else checkpoint.get('page_token', '')}))
        entries = result.get('messages', [])
    events = []
    for entry in entries:
        if entry['id'] in seen:
            continue
        message = request(tokens, 'messages/' + quote(entry['id'], safe='') + '?format=full')
        hydrate_calendar(tokens, entry['id'], message.get('payload', {}))
        event = classify(message, applications, interviews)
        # History can mention any mailbox message; retain only relevant messages.
        if event['application_id'] or any(c.get('email') == event['sender'] for c in contacts) or any(a['job']['company'].lower() in event['excerpt'].lower() for a in applications):
            events.append(event)
        seen.add(entry['id']);seen_order.append(entry['id'])
    page_token = result.get('nextPageToken', '')
    if not page_token:
        history = str(result.get('historyId') or scan_start)
        scan_start = ''
    watch_at = checkpoint.get('watch_at', 0)
    topic = os.environ.get('GOOGLE_GMAIL_TOPIC', '')
    if topic and watch_at < time.time() - 86400:
        request(tokens, 'watch', {'topicName': topic});watch_at = time.time()
    return {'events': events, 'checkpoint': {'seen': seen_order[-3000:], 'scan_start': scan_start, 'page_token': page_token, 'history_id': history, 'watch_at': watch_at}}


def calendar_request(tokens, path, body=None, method=None):
    return http('https://www.googleapis.com/calendar/v3/' + path, body,
                {'Authorization': 'Bearer ' + tokens['access_token'], 'Content-Type': 'application/json'}, method=method)


def create_calendar(tokens):
    return calendar_request(tokens, 'calendars', {'summary': 'Stack interviews and preparation'})['id']


def add_event(tokens, calendar_id, event, stable_id):
    # A deterministic event ID prevents duplicate events after response loss.
    event_id = hashlib.sha256(stable_id.encode()).hexdigest()
    path = 'calendars/' + quote(calendar_id, safe='') + '/events'
    try:
        existing = calendar_request(tokens, path + '/' + event_id)
    except ValueError:
        existing = None
    if existing:
        return calendar_request(tokens, path + '/' + event_id, event, method='PATCH')
    return calendar_request(tokens, path, {**event, 'id': event_id})


def free_busy(tokens, start, end, calendars):
    return calendar_request(tokens, 'freeBusy', {'timeMin': start, 'timeMax': end, 'items': [{'id': x} for x in calendars]})
