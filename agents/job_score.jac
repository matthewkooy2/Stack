"""Job score: how well the user's confirmed resume information covers one job listing.
No model calls; see docs/JOB_SCORE.md.

Contract `stack.job_score` version 1. The inputs are exactly:
  records - the user-confirmed resume records ({id, kind, text}); the caller passes nothing unconfirmed
  job     - the listing's title, description, qualifications, eligibility and requirements
  as_of   - the month ("YYYY-MM") that ends a role marked Present
The same canonical inputs, contract version and skills vocabulary always give the same output.
Only confirmed text is evidence: a record's name line, contact lines and negated clauses
("Did not lead a team") are never evidence, and nothing is inferred or invented.
The listing parser is shared with document scoring (agents/scoring.jac).
"""
import hashlib;
import json;
import re;
import from datetime { date }
import from discovery { matching }
import from agents { scoring, skills }
import from agents.record_resume { validate_records }
with entry {
    CONTRACT = 'stack.job_score';
    VERSION = 1;
    WEIGHTS = {
        'skills': 55,
        'title': 10,
        'education': 10,
        'experience': 10,
        'keywords': 15
    };
    LABELS = {
        'skills': 'Skills',
        'title': 'Job title',
        'education': 'Education',
        'experience': 'Experience',
        'keywords': 'Listing phrases'
    };
    # Evidence strength by where a confirmed claim appears.
    CREDIT = {'applied': 1.0, 'mentioned': 0.8, 'listed': 0.6};
    TIER = {
        'experience': 'applied',
        'projects': 'applied',
        'education': 'mentioned',
        'other': 'mentioned',
        'skills': 'listed'
    };
    SOFT_WEIGHT = 0.5;
    # Section of a heading record; the first pattern that matches wins.
    SECTIONS = [
        ('skills', re.compile(r'skill|technolog|tools|competenc|proficienc|languages', re.I)),
        ('experience', re.compile(r'experience|employment|\bwork\b|internship', re.I)),
        ('projects', re.compile(r'project', re.I)),
        ('education', re.compile(r'education|academic|degree|certif|credential|coursework', re.I))
    ];
    NEGATED = re.compile(
        r"\b(?:not|never|cannot|no (?:experience|knowledge|exposure|background|familiarity|degree))\b|n't\b",
        re.I
    );
    CONTACT = re.compile(r'@|https?://|www\.|\b[a-z0-9-]+\.(?:com|io|dev|me|org|net)/', re.I);
    CLAUSE = re.compile(r'(?<=[.!?;])\s+');
    # Degree spellings resumes use that the listing patterns (matching.DEGREES) miss.
    RESUME_DEGREES = [
        (4, re.compile(r'\bM\.?Sc\.?(?=\W|$)|\bM\.?Eng\.?(?=\W|$)')),
        (3, re.compile(r'\bB\.?Sc\.?(?=\W|$)|\bB\.?Eng\.?(?=\W|$)|\bB\.?A\.?Sc\.?(?=\W|$)'))
    ];
    AS_OF = re.compile(r'^((?:19|20)\d\d)-(0[1-9]|1[0-2])$');
    JOB_FIELDS = ('title', 'description', 'qualifications', 'eligibility');
}

def _text(value: any) -> any {
    lines = str((value or '')).replace('\r\n', '\n').replace('\r', '\n').split('\n');
    return '\n'.join(
        re.sub(r'[ \t ]+', ' ', line).strip()
        for line in lines
        if line.strip()
    );
}
"""The listing fields the score reads, with line endings and spacing made uniform."""
def canonical_job(job: any) -> any {
    if not isinstance(job, dict) {
        raise ValueError('The saved job has no listing to score.');
    }
    out = {field: _text(job.get(field)) for field in JOB_FIELDS};
    out['requirements'] = [
        _text(r)
        for r in (job.get('requirements') or [])
        if _text(r)
    ];
    return out;
}
"""Confirmed records in order, as {id, kind, text}."""
def canonical_records(records: any) -> any {
    return [
        {'id': r['id'], 'kind': r['kind'], 'text': r['text']}
        for r in validate_records(records)
    ];
}
def _month(day: any) -> any {
    return str(day.year).zfill(4) + '-' + str(day.month).zfill(2);
}
"""'YYYY-MM'. Defaults to the current month."""
def canonical_as_of(as_of: any = None) -> any {
    if isinstance(as_of, date) {
        return _month(as_of);
    }
    if (as_of is None) or (as_of == '') {
        return _month(date.today());
    }
    if not AS_OF.match(str(as_of)) {
        raise ValueError('Give the score month as YYYY-MM.');
    }
    return str(as_of);
}
def _digest(value: any) -> any {
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()
    ).hexdigest();
}
"""Identifies the skills vocabulary the rubric matched with."""
def vocabulary_digest() -> any {
    return hashlib.sha256(
        (
            (skills.DATA / 'skills.json').read_bytes()
            + b'\n'
            + (skills.DATA / 'skill_aliases.json').read_bytes()
        )
    ).hexdigest();
}
def _section(heading: any) -> any {
    return next((name for (name, p) in SECTIONS if p.search(heading)), 'other');
}
"""Usable evidence: each non-negated clause of a confirmed record, with its section and tier.
    Name lines (kind title), contact lines and headings themselves are left out."""
def evidence_units(records: any) -> any {
    (units, section) = ([], 'other');
    for r in records {
        if (r['kind'] == 'heading') {
            section = _section(r['text']);
            continue;
        }
        if ((r['kind'] == 'title') or CONTACT.search(r['text'])) {
            continue;
        }
        for clause in CLAUSE.split(r['text']) {
            if (clause.strip() and not NEGATED.search(clause)) {
                units.append(
                    {
                        'record': r['id'],
                        'kind': r['kind'],
                        'section': section,
                        'tier': TIER[section],
                        'text': clause.strip(),
                        'skills': skills.names(clause),
                        'stems': ' ' + ' '.join(scoring._stems(clause)) + ' '
                    }
                );
            }
        }
    }
    return units;
}
def _ids(units: any, limit: any = 3) -> any {
    return `list(`dict.fromkeys(u['record'] for u in units))[:limit];
}
def _status(credit: any) -> any {
    return 'met' if (credit >= 1.0) else 'partial' if (credit > 0) else 'missing';
}
def _skill(requirement: any, units: any) -> any {
    (best, tier, via, cited) = (0.0, 'missing', '', []);
    for name in requirement['alternatives'] {
        found = [u for u in units if (name in u['skills'])];
        for u in found {
            if (CREDIT[u['tier']] > best) {
                (best, tier, via) = (CREDIT[u['tier']], u['tier'], name);
            }
        }
        if (found and (via == name)) {
            cited = [u for u in found if (u['tier'] == tier)];
        }
    }
    return {
        'kind': 'skill',
        'term': requirement['term'],
        'alternatives': requirement['alternatives'],
        'required': requirement['required'],
        'weight': requirement['weight'],
        'status': tier,
        'credit': best,
        'via': via if (len(requirement['alternatives']) > 1) else '',
        'evidence': _ids(cited)
    };
}
def _title(title: any, units: any) -> any {
    words = sorted(
        {
            w
            for w in matching.tokens(title)
            if ((w not in scoring.TITLE_NOISE) and (w not in scoring.STOP))
        }
    );
    if not words {
        return None;
    }
    (best, cited) = (0.0, []);
    for u in units {
        if ((u['section'] != 'experience') or (u['kind'] == 'bullet')) {
            continue;
        }
        overlap = len(`set(words) & `set(matching.tokens(u['text']))) / len(words);
        if (overlap > best) {
            (best, cited) = (overlap, [u]);
        }
    }
    return {
        'kind': 'title',
        'term': title,
        'required': False,
        'status': _status(best),
        'credit': round(best, 4),
        'evidence': _ids(cited)
    };
}
def _degree_level(text: any) -> any {
    levels = [level for (level, p) in matching.DEGREES if p.search(text)];
    levels += [level for (level, p) in RESUME_DEGREES if p.search(text)];
    return max(levels) if levels else 0;
}
def _education(need: any, units: any) -> any {
    if not need {
        return None;
    }
    (have, cited) = (0, []);
    for u in units {
        level = _degree_level(u['text']) if (u['section'] == 'education') else 0;
        if (level > have) {
            (have, cited) = (level, [u]);
        }
    }
    want = need['level'];
    credit = 1.0
        if (have >= want)
        else 0.75
            if need.get('alternative')
            else 0.5 if (have == (want - 1)) else 0.0;
    return {
        'kind': 'education',
        'term': need['name'],
        'required': need['required'],
        'status': _status(credit),
        'credit': credit,
        'quote': need['quote'],
        'evidence': _ids(cited)
    };
}
def _experience(need: any, units: any, as_of: any) -> any {
    if not (need and need.get('min')) {
        return None;
    }
    entries = [
        u
        for u in units
        if (
            (u['section'] == 'experience')
            and (u['kind'] != 'bullet')
            and scoring.DATE.search(u['text'])
        )
    ];
    (year, month) = as_of.split('-');
    counted = scoring._years_of(
        [{'section': 'Experience', 'text': u['text']} for u in entries],
        date(int(year), int(month), 1)
    );
    credit = min(1.0, (counted / need['min']));
    return {
        'kind': 'experience',
        'term': str(need['min']) + '+ years',
        'required': need['required'],
        'status': _status(credit),
        'credit': round(credit, 4),
        'counted_years': counted,
        'quote': need['quote'],
        'evidence': _ids(entries, 10)
    };
}
def _phrases(need: any, units: any) -> any {
    out = [];
    for k in need['keywords'] {
        key = ' ' + ' '.join(scoring._stems(k['term'])) + ' ';
        found = [u for u in units if (key in u['stems'])];
        out.append(
            {
                'kind': 'keyword',
                'term': k['term'],
                'required': False,
                'weight': k['weight'],
                'status': 'met' if found else 'missing',
                'credit': 1.0 if found else 0.0,
                'evidence': _ids(found)
            }
        );
    }
    for name in need['soft'] {
        found = [
            u
            for u in units
            if `any(
                re.search((r'\b' + re.escape(f) + r'\b'), u['text'].lower())
                for f in scoring.SOFT[name]
            )
        ];
        out.append(
            {
                'kind': 'soft_skill',
                'term': name,
                'required': False,
                'weight': SOFT_WEIGHT,
                'status': 'met' if found else 'missing',
                'credit': 1.0 if found else 0.0,
                'evidence': _ids(found)
            }
        );
    }
    return out;
}
def _weighted(items: any) -> any {
    total = sum(i['weight'] for i in items);
    return (sum((i['weight'] * i['credit']) for i in items) / total) if total else None;
}
"""Scores confirmed resume records against one listing. Raises ValueError for invalid inputs."""
def score(records: any, job: any, as_of: any = None) -> any {
    canon = {
        'records': canonical_records(records),
        'job': canonical_job(job),
        'as_of': canonical_as_of(as_of)
    };
    need = scoring.job_requirements(canon['job']);
    units = evidence_units(canon['records']);
    found_skills = [_skill(s, units) for s in need['skills']];
    phrases = _phrases(need, units);
    title = _title(canon['job']['title'], units);
    education = _education(need['education'], units);
    experience = _experience(need['years'], units, canon['as_of']);
    values = {
        'skills': _weighted(found_skills),
        'title': title['credit'] if title else None,
        'education': education['credit'] if education else None,
        'experience': experience['credit'] if experience else None,
        'keywords': _weighted(phrases)
    };
    present = {k: v for (k, v) in values.items() if (v is not None)};
    # A title alone is too little to compare against.
    scored = bool(`set(present) - {'title'});
    total = sum(WEIGHTS[k] for k in present);
    requirements = (
        found_skills
        + [r for r in (title, education, experience) if r]
        + phrases
    );
    return {
        'contract': CONTRACT,
        'version': VERSION,
        'status': 'scored' if scored else 'insufficient_job',
        'score': round(
            ((100 * sum((WEIGHTS[k] * v) for (k, v) in present.items())) / total)
        )
            if scored
            else None,
        'components': [
            {
                'key': k,
                'label': LABELS[k],
                'weight': WEIGHTS[k],
                'score': round((100 * present[k]))
            }
            for k in WEIGHTS
            if (scored and (k in present))
        ],
        'requirements': requirements,
        'missing_required': [
            r['term']
            for r in requirements
            if (r['required'] and (r['credit'] == 0))
        ],
        'listing': {
            'title': canon['job']['title'],
            'years': need['years'],
            'education': need['education']
        },
        'inputs': {
            'as_of': canon['as_of'],
            'records': len(canon['records']),
            'evidence_records': len(`dict.fromkeys(u['record'] for u in units)),
            'job_digest': _digest(canon['job']),
            'records_digest': _digest(canon['records']),
            'digest': _digest({'contract': CONTRACT, 'version': VERSION, **canon})
        },
        'rubric': {
            'weights': WEIGHTS,
            'credit': CREDIT,
            'vocabulary_digest': vocabulary_digest()
        }
    };
}
"""The earlier score_resume summary shape, for clients that predate this contract.
    `match` is the job score; `quality` is the job-independent writing score of the same confirmed records."""
def legacy_summary(result: any, quality: any) -> any {
    skills_found = [r for r in result['requirements'] if (r['kind'] == 'skill')];
    experience = [r for r in result['requirements'] if (r['kind'] == 'experience')];
    return {
        'version': result['version'],
        'match': result['score'],
        'quality': quality['score'],
        'match_components': result['components'],
        'quality_components': quality['components'],
        'missing': [
            {'term': r['term'], 'required': r['required'], 'supported': False}
            for r in skills_found
            if (r['status'] == 'missing')
        ][:12],
        'listed_only': [r['term'] for r in skills_found if (r['status'] == 'listed')][:12],
        'keywords': [
            {'term': r['term'], 'found': (r['status'] == 'met')}
            for r in result['requirements']
            if (r['kind'] == 'keyword')
        ],
        'stuffed': [],
        'requirements': {
            'years': result['listing']['years'],
            'education': result['listing']['education'],
            'title': result['listing']['title'],
            'resume_years': experience[0]['counted_years'] if experience else None
        },
        'issues': quality['issues'][:12]
    };
}
