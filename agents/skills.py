"""Finds known skills in text: O*NET Technology Skills (agents/data/skills.json, built by scripts/build-skills.py)
plus hand-curated concepts and short forms (agents/data/skill_aliases.json). No model calls."""
import json
import re
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).parent / 'data'
# Keeps C++, C#, Node.js, CI/CD, A/B and T-SQL whole.
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9+#]*(?:[./&-][A-Za-z0-9+#]+)*\+*')
LONGEST = 6


def _raw(text):
    return [(m.group(0), m.start()) for m in TOKEN.finditer(text or '')]


def tokens(text):
    """Words with offsets. "Supabase/PostgreSQL" and "React-based" split unless the whole is a skill (CI/CD, front-end)."""
    whole = _joined()
    out = []
    for word, start in _raw(text):
        if re.search(r'[/-]', word) and word.lower() not in whole:
            out += [(m.group(0), start + m.start()) for m in re.finditer(r'[^/-]+', word) if TOKEN.fullmatch(m.group(0))]
        else:
            out.append((word, start))
    return out


def _sentence_start(text, offset):
    before = text[:offset].rstrip()
    return not before or before[-1] in '.!?;•\n'


@lru_cache(maxsize=1)
def _joined():
    """Single-token aliases containing / or -, which must not be split."""
    extra = json.loads((DATA / 'skill_aliases.json').read_text())
    onet = json.loads((DATA / 'skills.json').read_text())['skills']
    aliases = [a for e in onet + extra['skills'] for a in e.get('aliases', []) + [e['name']]] + [a for v in extra['aliases'].values() for a in v]
    return {a.lower() for a in aliases if re.search(r'[/-]', a) and len(_raw(a)) == 1}


def _key(words):
    return tuple(w.lower() for w in words)


@lru_cache(maxsize=1)
def vocabulary():
    """{lowercase token tuple: [(skill name, exact spelling or None)]} and {skill name: hot}."""
    onet = json.loads((DATA / 'skills.json').read_text())['skills']
    extra = json.loads((DATA / 'skill_aliases.json').read_text())
    names, exact, hot = {}, set(extra.get('exact_case', [])), {}
    for entry in onet + extra['skills']:
        names.setdefault(entry['name'], set()).update(entry.get('aliases', []) + [entry['name']])
        exact.update(entry.get('exact_case', []))
        hot[entry['name']] = hot.get(entry['name'], False) or entry.get('hot', False)
    for name, more in extra['aliases'].items():
        names.setdefault(name, {name}).update(more)
    index = {}
    for name, aliases in names.items():
        for alias in aliases:
            words = [w for w, _ in _raw(alias)]
            if 0 < len(words) <= LONGEST:
                # All-caps acronyms (FAST, SAS) only match as written, so "fast-paced" is not a product.
                strict = alias in exact or bool(re.fullmatch(r'[A-Z][A-Z0-9+#./&-]+', alias))
                index.setdefault(_key(words), []).append((name, alias if strict else None))
    return index, hot


def mentions(text):
    """[(skill name, start, end)] for each mention, longest alias first, in reading order."""
    index, _ = vocabulary()
    words = tokens(text)
    found, i = [], 0
    while i < len(words):
        for n in range(min(LONGEST, len(words) - i), 0, -1):
            span = [w for w, _ in words[i:i + n]]
            keys = [_key(span)]
            if span[-1].lower().endswith('s') and len(span[-1]) > 3 and not span[-1].lower().endswith('ss'):
                keys.append(_key(span[:-1] + [span[-1][:-1]]))      # "data pipelines" -> "data pipeline"
            # A capitalized ordinary word at a sentence start ("Excel in a fast-paced team") is not the product.
            match = next(((name, exact) for key in keys for name, exact in index.get(key, [])
                          if exact is None or ((' '.join(span) == exact or ' '.join(span)[:-1] == exact)
                                               and not (any(c.islower() for c in exact) and _sentence_start(text, words[i][1])))), None)
            if match:
                last = words[i + n - 1]
                found.append((match[0], words[i][1], last[1] + len(last[0])))
                i += n
                break
        else:
            i += 1
    return found


def find(text):
    """[(skill name, start offset)] for each mention."""
    return [(name, start) for name, start, _ in mentions(text)]


def names(text):
    return {name for name, _ in find(text)}


def is_hot(name):
    return vocabulary()[1].get(name, False)
