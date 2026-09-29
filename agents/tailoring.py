"""Checks a model's tailoring proposal, fits the resume to one page, and describes every change. No model calls."""
import base64
import re
from collections import Counter
from difflib import unified_diff
from agents import latex

MAX_PAGES = 1
TERM = re.compile(r'[A-Za-z][A-Za-z0-9+#]*(?:[./-][A-Za-z0-9+#]+)*')
NUMBER = re.compile(r'\d+(?:[.,]\d+)*')


def prepare(value):
    """value: the worker API's encoded source. Returns the parsed source and the model's id-addressed outline."""
    source = latex.decode(value)
    structure = latex.parse(source)
    if not structure['bullets']:
        raise ValueError('Stack could not find bullet points in this LaTeX resume. Use \\item or \\resumeItem bullets, or choose a built-in template.')
    return {'source': source, 'structure': structure, 'outline': latex.outline(structure),
            'digest': value.get('digest') or latex.digest(source), 'format': value.get('format', '')}


def evidence_sources(outline):
    out = {}
    for section in outline:
        for entry in section['entries']:
            for bullet in entry['bullets']:
                out['resume:' + bullet['id']] = bullet['text']
        for line in section['lines']:
            out['resume:' + line['id']] = line['label'] + ': ' + line['text']
    return out


def _clean(text):
    return re.sub(r'\s+', ' ', str(text).replace('**', ' ')).strip()


def _numbers(text):
    return {n.replace(',', '') for n in NUMBER.findall(_clean(text))}


def _terms(text):
    """Proper nouns, tools and acronyms after the first word: the words a rewrite could invent."""
    text = _clean(text)
    out = set()
    for match in TERM.finditer(text):
        token = match.group(0)
        before = text[:match.start()].rstrip()
        if not before or before.endswith(('.', ':', ';', '!', '?')):
            continue
        if any(c.isupper() for c in token) or any(c.isdigit() or c in '+#' for c in token):
            out.add(token.lower())
    return out


def _items(text):
    """Comma-separated items, keeping commas inside parentheses."""
    items, depth, current = [], 0, ''
    for c in text:
        depth += c == '('
        depth -= c == ')'
        if c == ',' and depth == 0:
            items.append(current.strip())
            current = ''
        else:
            current += c
    items.append(current.strip())
    return [i for i in items if i]


def _where(structure, id):
    sections = {s['id']: s['title'] for s in structure['sections']}
    entries = {e['id']: e for e in structure['entries']}
    section = id.split('.')[0]
    entry = entries.get('.'.join(id.split('.')[:2]))
    heading = entry['heading'].replace('**', '').split(' | ')[0] if entry and entry['heading'] else ''
    return sections.get(section, '') + (' · ' + heading if heading else '')


def check(structure, data, facts):
    """Returns (plan, changes, notes). Unsupported edits are discarded with a note, never applied."""
    bullets = {b['id']: b for b in structure['bullets']}
    lines = {l['id']: l for l in structure['lines']}
    entries = {e['id']: e for e in structure['entries']}
    fact_text = ' '.join(str(f.get('value', '')) for f in facts if f.get('verified'))
    known = (' '.join(b['text'] for b in structure['bullets']) + ' ' + ' '.join(e['heading'] for e in structure['entries'])
             + ' ' + ' '.join(l['label'] + ' ' + l['text'] for l in structure['lines']) + ' ' + fact_text).lower().replace('**', '')
    fact_numbers = _numbers(fact_text)
    notes, changes = [], []

    unknown = [i for i in data.get('ranking', []) if i not in bullets]
    if unknown:
        raise ValueError('The tailoring referred to bullets that are not in your resume.')
    ranking = list(dict.fromkeys(data.get('ranking', [])))
    ranking += [b for b in bullets if b not in ranking]

    rewrites = {}
    for item in data.get('rewrites', []):
        id = item.get('id', '')
        original = bullets.get(id, lines.get(id))
        if original is None:
            notes.append('Ignored a rewrite for an unknown item.')
            continue
        text = str(item.get('text', '')).strip()
        if not text or text.replace('**', '') == original['text'].replace('**', ''):
            continue
        where = _where(structure, id)
        if id in lines:
            before, after = _items(original['text']), _items(text)
            allowed = {i.lower() for i in before}
            extra = [i for i in after if i.lower() not in allowed]
            if extra or not after:
                notes.append('Kept “' + original['label'] + '” unchanged: skill lines can only be reordered or shortened (not in your resume: ' + ', '.join(extra[:3]) + ').')
                continue
        else:
            invented = sorted(_numbers(text) - _numbers(original['text']) - fact_numbers)
            if invented:
                notes.append('Kept a bullet in ' + where + ' unchanged: the rewrite added numbers not in your resume (' + ', '.join(invented[:3]) + ').')
                continue
            new_terms = sorted(t for t in _terms(text) - _terms(original['text']) if t not in known)
            if new_terms:
                notes.append('Kept a bullet in ' + where + ' unchanged: the rewrite mentioned ' + ', '.join(new_terms[:3]) + ', which is not in your resume.')
                continue
            limit = max(len(original['text']) * 1.25, len(original['text']) + 15)
            if len(text) > limit:
                notes.append('Kept a bullet in ' + where + ' unchanged: the rewrite was much longer than the original.')
                continue
        rewrites[id] = text
        changes.append({'id': id, 'kind': 'rewrite', 'where': where, 'before': original['text'], 'after': text, 'reason': str(item.get('reason', ''))[:300]})

    omit = []
    for item in data.get('omit', []):
        id = item.get('id', '')
        if id in bullets:
            before = bullets[id]['text']
        elif id in entries and entries[id]['movable']:
            before = entries[id]['heading'].replace('**', '')
        else:
            continue
        if id in omit:
            continue
        omit.append(id)
        rewrites.pop(id, None)
        changes = [c for c in changes if c['id'] != id]
        changes.append({'id': 'omit:' + id, 'kind': 'omit', 'where': _where(structure, id), 'before': before, 'after': '',
                        'reason': str(item.get('reason', ''))[:300]})

    entry_order = {}
    for item in data.get('entry_order', []):
        section = item.get('section', '')
        movable = [e['id'] for e in structure['entries'] if e['section'] == section and e['movable']]
        wanted = [e for e in dict.fromkeys(item.get('entries', [])) if e in movable]
        order = wanted + [e for e in movable if e not in wanted]
        if order != movable:
            entry_order[section] = order
            title = next(s['title'] for s in structure['sections'] if s['id'] == section)
            changes.append({'id': 'order:' + section, 'kind': 'reorder', 'where': title, 'reason': '',
                            'before': ' → '.join(entries[e]['heading'].replace('**', '').split(' | ')[0] for e in movable),
                            'after': ' → '.join(entries[e]['heading'].replace('**', '').split(' | ')[0] for e in order)})

    bullet_order = {}
    position = {b: i for i, b in enumerate(ranking)}
    for entry in structure['entries']:
        own = [b['id'] for b in structure['bullets'] if b['entry'] == entry['id']]
        order = sorted(own, key=lambda b: position[b])
        if order != own:
            bullet_order[entry['id']] = order
            changes.append({'id': 'order:' + entry['id'], 'kind': 'reorder', 'where': _where(structure, entry['id']),
                            'reason': 'Most relevant bullets first.', 'before': '', 'after': 'Bullets reordered by relevance to this job.'})
    plan = {'rewrites': rewrites, 'omit': omit, 'entry_order': entry_order, 'bullet_order': bullet_order, 'ranking': ranking}
    return plan, changes, notes


def effective(plan, rejected):
    """The plan without the changes the user rejected."""
    rejected = set(rejected)
    return {'rewrites': {k: v for k, v in plan['rewrites'].items() if k not in rejected},
            'omit': [i for i in plan['omit'] if 'omit:' + i not in rejected],
            'entry_order': {k: v for k, v in plan['entry_order'].items() if 'order:' + k not in rejected},
            'bullet_order': {k: v for k, v in plan['bullet_order'].items() if 'order:' + k not in rejected},
            'ranking': plan['ranking']}


def _search(n, fits):
    """Smallest k in 1..n with fits(k), assuming more removal never adds pages; None when even n does not fit."""
    if n == 0 or not fits(n):
        return None
    lo, hi = 1, n
    while lo < hi:
        mid = (lo + hi) // 2
        if fits(mid):
            hi = mid
        else:
            lo = mid + 1
    return lo


def fit(prepared, plan):
    """Drops the least relevant bullets, then entries, until the resume fits on one page."""
    structure, source = prepared['structure'], prepared['source']
    cache = {}

    def build(extra):
        tex = latex.apply(structure, {**plan, 'omit': list(plan['omit']) + list(extra)})
        if tex not in cache:
            cache[tex] = latex.compile(latex.with_main(source, tex))
        return tex, cache[tex]

    tex, compiled = build([])
    if compiled['pages'] <= MAX_PAGES:
        return tex, compiled, []
    omitted = set(plan['omit'])
    ranking = plan['ranking']

    def bullet_candidates(skip_entries):
        live = [b for b in structure['bullets'] if b['id'] not in omitted and b['entry'] not in omitted and b['entry'] not in skip_entries]
        counts = Counter(b['entry'] for b in live)
        by_id = {b['id']: b for b in live}
        out = []
        for id in reversed(ranking):
            b = by_id.get(id)
            if b and counts[b['entry']] > 1:
                out.append(id)
                counts[b['entry']] -= 1
        return out

    bullets = bullet_candidates(set())
    k = _search(len(bullets), lambda k: build(bullets[:k])[1]['pages'] <= MAX_PAGES)
    if k is not None:
        tex, compiled = build(bullets[:k])
        return tex, compiled, bullets[:k]
    rank = {id: i for i, id in enumerate(ranking)}
    entries = [e for e in structure['entries'] if e['movable'] and e['id'] not in omitted]
    score = lambda e: min((rank[b['id']] for b in structure['bullets'] if b['entry'] == e['id'] and b['id'] in rank), default=len(rank))
    per_section = Counter(e['section'] for e in entries)
    removable = []
    for e in sorted(entries, key=score, reverse=True):
        if per_section[e['section']] > 1:
            removable.append(e['id'])
            per_section[e['section']] -= 1
    k = _search(len(removable), lambda k: build(bullets + removable[:k])[1]['pages'] <= MAX_PAGES)
    if k is None:
        raise ValueError('Even without its least relevant bullets and entries, this resume is longer than one page. Shorten the source, then tailor again.')
    dropped_entries = removable[:k]
    bullets = bullet_candidates(set(dropped_entries))
    j = _search(len(bullets), lambda j: build(dropped_entries + bullets[:j])[1]['pages'] <= MAX_PAGES)
    extra = dropped_entries + (bullets[:j] if j is not None else bullets)
    tex, compiled = build(extra)
    return tex, compiled, extra


def _outline_text(structure):
    out = []
    for section in latex.outline(structure):
        out.append(section['title'].upper())
        for entry in section['entries']:
            if entry['heading']:
                out.append(entry['heading'].replace('**', ''))
            out += ['• ' + b['text'].replace('**', '') for b in entry['bullets']]
        out += [l['label'] + ': ' + l['text'] for l in section['lines']]
    return out


def _document(prepared, tex, compiled, dropped):
    structure = prepared['structure']
    before = _outline_text(structure)
    after = _outline_text(latex.parse(latex.with_main(prepared['source'], tex)))
    bullets = {b['id']: b for b in structure['bullets']}
    entries = {e['id']: e for e in structure['entries']}
    described = [{'id': id, 'where': _where(structure, id),
                  'text': bullets[id]['text'] if id in bullets else entries[id]['heading'].replace('**', '')} for id in dropped]
    pdf = {'name': 'Tailored resume.pdf', 'content': base64.b64encode(compiled['pdf']).decode(), 'pages': compiled['pages'],
           'text': '\n'.join(after), 'original_text': '\n'.join(before),
           'diff': '\n'.join(unified_diff(before, after, fromfile='Original', tofile='Tailored', lineterm='')),
           'checks': {'pages': compiled['pages'], 'fits': compiled['pages'] <= MAX_PAGES}}
    return pdf, described


def tailor(prepared, data, facts):
    """Model proposal -> proposed tailored resume (all changes applied) for the user's review."""
    plan, changes, notes = check(prepared['structure'], data, facts)
    tex, compiled, dropped = fit(prepared, plan)
    pdf, described = _document(prepared, tex, compiled, dropped)
    if described:
        notes.append('To fit one page, Stack left out ' + str(len(described)) + ' of the least relevant item' + ('s' if len(described) > 1 else '') + '.')
    return {'summary': str(data.get('summary', '')), 'changes': changes, 'dropped': described, 'notes': notes, 'plan': plan,
            'evidence': data.get('evidence', []), 'source_digest': prepared['digest'], 'format': prepared['format'],
            'pdf': pdf, 'tex': tex, 'rejected': [], 'final': False,
            'top_bullets': [{'key': id, 'value': prepared_text(prepared, id, plan)} for id in plan['ranking'][:3]]}


def prepared_text(prepared, id, plan):
    return plan['rewrites'].get(id) or next(b['text'] for b in prepared['structure']['bullets'] if b['id'] == id)


def finalize(prepared, tailored):
    """Rebuilds the resume with only the changes the user kept."""
    if prepared['digest'] != tailored.get('source_digest'):
        raise ValueError('Your resume source changed after tailoring. Start tailoring again.')
    rejected = [r for r in tailored.get('rejected', []) if r in {c['id'] for c in tailored.get('changes', [])}]
    plan = effective(tailored['plan'], rejected)
    tex, compiled, dropped = fit(prepared, plan)
    pdf, described = _document(prepared, tex, compiled, dropped)
    kept = len(tailored.get('changes', [])) - len(rejected)
    return {'summary': 'Applied ' + str(kept) + ' of ' + str(len(tailored.get('changes', []))) + ' changes.',
            'tailor': {'pdf': pdf, 'tex': tex, 'dropped': described, 'final': True, 'applied_plan': plan}}
