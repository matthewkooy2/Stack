"""Deterministic search ordering and date presentation; no network or storage."""
import base64
import json
import math
import re
import time
from datetime import datetime, timezone


def title_score(job: dict, query: str) -> float:
    title = ' '.join(re.findall(r'\w+', job.get('title', '').lower()))
    query = ' '.join(re.findall(r'\w+', query.lower()))
    # Exact title, phrase, then all title words. Used when no match evaluation is attached.
    if not query:
        return 0.0
    return 3.0 if title == query else 2.0 if f' {query} ' in f' {title} ' else 1.0 if set(query.split()) <= set(title.split()) else 0.0


def rank(job: dict, order: str, query: str = '') -> tuple[float, float, str]:
    # Best match uses the evaluated fit (role match, confirmed inputs, preferences); ties go to newer posts.
    match = job.get('match') or {}
    score = float(match['score']) if 'score' in match else title_score(job, query)
    posted = float(job.get('posted_at') or 0)
    return (-score, -posted, job['id']) if order == 'relevance' else (-posted, -score, job['id'])


def encode_cursor(fingerprint: str, key: tuple) -> str:
    return base64.urlsafe_b64encode(json.dumps([fingerprint, key], separators=(',', ':')).encode()).decode()


def decode_cursor(cursor: str, fingerprint: str) -> tuple[float, float, str] | None:
    if not cursor:
        return None
    try:
        if len(cursor) > 512:
            raise ValueError()
        saved, key = json.loads(base64.b64decode(cursor, altchars=b'-_', validate=True))
        if saved != fingerprint:
            raise ValueError()
        if not isinstance(key, list) or len(key) != 3:
            raise ValueError()
        if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) for n in key[:2]):
            raise ValueError()
        if not isinstance(key[2], str) or not re.fullmatch(r'job_[a-f0-9]{32}', key[2]):
            raise ValueError()
        return tuple(key)
    except (ValueError, TypeError, UnicodeError):
        raise ValueError('Search changed or cursor expired. Refresh the results.') from None


def posting_label(posted_at: float) -> str:
    if not posted_at:
        return 'Posting date unknown'
    elapsed = max(0, time.time() - posted_at)
    if elapsed < 86400:
        return 'Posted within 24 hours'
    days = int(elapsed // 86400)
    if days < 7:
        return f'Posted {days} day' + ('s' if days != 1 else '') + ' ago'
    return 'Posted ' + datetime.fromtimestamp(posted_at, timezone.utc).strftime('%b %d, %Y')
