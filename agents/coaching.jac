"""Structured practice coaching (#112): the coach step's schema, its checks and a readable text copy.

The coach step asks every provider for this schema. A reply that parses as JSON must
pass `clean`; a reply that is not JSON at all (a local model that ignored the format)
is kept as prose, as before. Stored artifacts always carry `text` and `summary`, so
clients that only read prose keep working."""
import json;
import math;

with entry {
    TEXT = {'type': 'string'};
    SCHEMA = {
        'type': 'object',
        'properties': {
            'verdict': TEXT,
            'scores': {
                'type': 'array',
                'maxItems': 9,
                'items': {
                    'type': 'object',
                    'properties': {'name': TEXT, 'score': {'type': 'integer', 'minimum': 0, 'maximum': 4}, 'why': TEXT},
                    'required': ['name', 'score', 'why'],
                    'additionalProperties': False
                }
            },
            'work_on': TEXT,
            'follow_ups': {'type': 'array', 'maxItems': 2, 'items': TEXT},
            'example': TEXT
        },
        'required': ['verdict', 'scores', 'work_on', 'follow_ups', 'example'],
        'additionalProperties': False
    };
    INSTRUCTION = 'Coach this practice attempt using a 0-4 rubric. Technical: reasoning, edge cases, complexity, tradeoffs, communication. '
        'Behavioral: specificity, ownership, structure, reflection. Use actual test results for correctness. '
        'verdict: one short sentence on how the answer went. scores: one entry per criterion that applies, with why in one or two sentences. '
        'work_on: the single most useful next practice step, in one sentence. follow_ups: up to two short follow-up questions. '
        'example: a short illustrative answer of at most 120 words only when it clearly helps, otherwise the empty string; '
        'never present invented experience as the candidate\'s own. Keep the whole reply under 250 words.';
    LIMITS = {'verdict': 240, 'name': 40, 'why': 400, 'work_on': 300, 'follow_up': 240, 'example': 1600};
}

def clip(value: any, limit: int) -> str {
    text = ' '.join(value.split()) if isinstance(value, str) else '';
    return text if len(text) <= limit else text[:limit - 1].rstrip() + '…';
}

"""A 0-4 score from an int or a finite number; None for anything else, including booleans."""
def score_of(value: any) -> any {
    if isinstance(value, bool) or not isinstance(value, (int, float)) { return None; }
    if isinstance(value, float) and not math.isfinite(value) { return None; }
    return min(4, max(0, int(round(value))));
}

"""Bounded, trimmed structured coaching, or None when the reply has neither a verdict nor a score.

    Model output and worker results are untrusted, so this runs in the provider and again
    where the server stores the artifact."""
def clean(data: any) -> any {
    if not isinstance(data, `dict) { return None; }
    scores: list[dict[str, any]] = [];
    for item in (data.get('scores') if isinstance(data.get('scores'), `list) else [])[:9] {
        if not isinstance(item, `dict) { continue; }
        name = clip(item.get('name'), LIMITS['name']);
        score = score_of(item.get('score'));
        if name and score is not None {
            scores.append({'name': name[0].upper() + name[1:], 'score': score, 'why': clip(item.get('why'), LIMITS['why'])});
        }
    }
    verdict = clip(data.get('verdict'), LIMITS['verdict']);
    if not verdict and not scores { return None; }
    asked = data.get('follow_ups') if isinstance(data.get('follow_ups'), `list) else [];
    return {
        'verdict': verdict,
        'scores': scores,
        'work_on': clip(data.get('work_on'), LIMITS['work_on']),
        'follow_ups': [q for q in [clip(q, LIMITS['follow_up']) for q in asked] if q][:2],
        'example': clip(data.get('example'), LIMITS['example'])
    };
}

"""Plain text with the same layout every time, for clients that read `text`."""
def render(data: dict[str, any]) -> str {
    parts = [data['verdict']] if data['verdict'] else [];
    if data['scores'] {
        parts.append('Scores:\n' + '\n'.join(
            (s['name'] + ': ' + str(s['score']) + '/4' + (' - ' + s['why'] if s['why'] else '')) for s in data['scores']
        ));
    }
    if data['work_on'] { parts.append('Work on: ' + data['work_on']); }
    if data['follow_ups'] {
        parts.append('Follow-up questions:\n' + '\n'.join(
            (str(i + 1) + '. ' + q) for (i, q) in enumerate(data['follow_ups'])
        ));
    }
    if data['example'] { parts.append('Example answer:\n' + data['example']); }
    return '\n\n'.join(parts);
}

def structured(data: dict[str, any]) -> dict[str, any] {
    return {**data, 'summary': data['verdict'] or data['scores'][0]['why'] or data['scores'][0]['name'], 'text': render(data), 'format': 'structured'};
}

def prose(text: str) -> dict[str, any] {
    return {'text': text, 'summary': text, 'format': 'text'};
}

"""The artifact for one coach reply.

    JSON that fails the checks raises, so the worker retries the step; anything that is
    not JSON is kept as prose."""
def artifact(reply: any) -> dict[str, any] {
    if isinstance(reply, `dict) {
        data = clean(reply);
        if data is None { raise ValueError('The coaching reply could not be validated. Please retry.'); }
        return structured(data);
    }
    text = reply if isinstance(reply, str) else '';
    if not text.strip() { raise ValueError('The model returned no coaching text. Please retry.'); }
    body = text.strip();
    if body.startswith('```') {
        body = body.strip('`').strip();
        if body.lower().startswith('json') { body = body[4:].strip(); }
    }
    try { parsed = json.loads(body); } except (ValueError, RecursionError) { return prose(text); }
    if not isinstance(parsed, `dict) { return prose(text); }
    return artifact(parsed);
}

"""Re-check a worker's coach artifact before it is stored; prose artifacts pass through."""
def stored(value: any) -> dict[str, any] {
    if isinstance(value, `dict) and ('scores' in value or 'verdict' in value) { return artifact({k: v for (k, v) in value.items() if k in SCHEMA['properties']}); }
    text = (value.get('text') or value.get('summary')) if isinstance(value, `dict) else '';
    if not isinstance(text, str) or not text.strip() { raise ValueError('The coaching reply was empty. Please retry.'); }
    return {**value, 'text': text[:30000], 'summary': str(value.get('summary') or text)[:30000]};
}
