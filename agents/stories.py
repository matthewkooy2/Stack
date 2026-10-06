"""Extractive STAR contracts: model prose cannot become a personal fact."""
import copy
import re
from typing import Any

FIELDS = ('situation', 'task', 'action', 'result', 'personal', 'team', 'learning')
TOPICS = ('ownership', 'conflict', 'decisions', 'learning')
UNKNOWN_OUTCOME = re.compile(r"\b(?:unknown|pending|do not know|don't know|not (?:yet )?(?:happened|measured|released)|no (?:known )?outcome)\b", re.I)
QUESTIONS = {
    'situation': 'What was happening in this event?',
    'task': 'What were you responsible for?',
    'action': 'What did you do?',
    'result': 'What happened afterward? An unmeasured or unknown outcome is fine.',
    'personal': 'What did you personally contribute?',
    'team': 'What did the team contribute, if anything?',
    'learning': 'What did you learn or change afterward?',
}


def validate(data: Any, source: Any) -> dict[str, Any]:
    if not isinstance(data, dict) or set(data) != {'fields', 'topics', 'evidence'}:
        raise ValueError('Incomplete story response.')
    if not isinstance(data['fields'], dict) or set(data['fields']) != set(FIELDS):
        raise ValueError('Return every STAR and contribution field.')
    for field, claim in data['fields'].items():
        if not isinstance(claim, dict) or set(claim) != {'source', 'quote'}:
            raise ValueError('Each story field needs its exact source quotation.')
        quote = claim['quote']
        if not isinstance(quote, str) or len(quote) > 8000 or claim['source'] != source['key']:
            raise ValueError('Story field uses an unavailable source.')
        if quote and (not quote.strip() or quote not in source['text']):
            raise ValueError('Story claims must copy exact source text.')
        # Preserve first-person/team attribution; ambiguous third-person text stays
        # in Action rather than being promoted to a personal contribution.
        if quote and field == 'personal' and (not re.match(r'I\b', quote, re.I) or
                re.search(r'\b(?:we|our|(?:my|the) team)\b', quote, re.I)):
            raise ValueError('Personal contribution needs an explicit I statement without team attribution.')
        if quote and field == 'team' and (not re.match(r'(?:we\b|(?:our|the|my) (?:team|teammates)\b)', quote, re.I) or
                re.search(r'\bI\b', quote, re.I)):
            raise ValueError('Team contribution needs an explicit team statement without personal attribution.')
    topics = data['topics']
    if not isinstance(topics, list) or len(topics) > 4 or any(t not in TOPICS for t in topics):
        raise ValueError('Choose supported behavioral question types.')
    # Evidence is derived from displayed quotes, never accepted as a weaker
    # substitute for validating each displayed factual field.
    out = copy.deepcopy(data)
    out['topics'] = sorted(set(topics))
    out['evidence'] = [dict(field=k, **v) for k, v in out['fields'].items() if v['quote']]
    return out


def corrected(content: Any, changes: Any, revision: int) -> dict[str, Any]:
    if not isinstance(changes, dict) or not changes or not set(changes) <= set(FIELDS):
        raise ValueError('Choose story fields to correct.')
    out = copy.deepcopy(content)
    for field, text in changes.items():
        if not isinstance(text, str) or len(text) > 8000 or (text and not text.strip()):
            raise ValueError('Corrections must be text under 8,000 characters.')
        out['fields'][field] = {'source': f'user-confirmed:{revision}:{field}', 'quote': text}
    out['evidence'] = [dict(field=k, **v) for k, v in out['fields'].items() if v['quote']]
    return out


def empty(source: Any) -> dict[str, Any]:
    return {'fields': {k: {'source': source['key'], 'quote': ''} for k in FIELDS},
            'topics': [], 'evidence': []}


def missing(content: Any) -> list[dict[str, Any]]:
    return [{'field': k, 'question': QUESTIONS[k]} for k in FIELDS
            if not content['fields'][k]['quote'] or
            (k == 'result' and UNKNOWN_OUTCOME.search(content['fields'][k]['quote']))]


def model_source(source: Any) -> dict[str, Any]:
    """Exclude other events and pre-correction transcripts from inference."""
    return {'key': source['key'], 'text': source['text']}
