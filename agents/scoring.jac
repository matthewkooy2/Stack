"""Resume scores. No model calls; see docs/RESUME_SCORING.md.

Two separate 0-100 scores, each with components and the items behind them:
  match   - how well the resume covers this job (skills, title, education, experience, keywords)
  quality - how the resume reads regardless of job (metrics, verbs, repetition, length, clarity, tense)
The weights and targets are Stack's own defaults. Commercial tools do not publish theirs. The scores
guide tailoring and are not a prediction of hiring.

`outline` is agents.latex.outline(...) or outline_from_parser(...): sections of entries (heading, bullets)
and skill lines.
"""
import math;
import re;
import from datetime { date }
import from discovery { matching }
import from agents { skills }
with entry {
    VERSION = 1;
    MATCH_WEIGHTS = {
        'skills': 55,
        'title': 10,
        'education': 10,
        'experience': 10,
        'keywords': 15
    };
    QUALITY_WEIGHTS = {
        'metrics': 25,
        'verbs': 20,
        'repetition': 15,
        'brevity': 15,
        'clarity': 10,
        'tense': 5,
        'parsing': 10
    };
    SECTION_WEIGHT = {
        'required': 3.0,
        'preferred': 1.5,
        'duties': 1.0,
        'other': 1.0,
        'intro': 0.5
    };
    HEADINGS = [
        (
            'ignore',
            re.compile(
                r"^(?:benefits|perks|why (?:join|work)|about (?!the role|this role|you\b)|our (?:values|mission|culture|story|benefits|commitment)|"
                r"equal (?:opportunity|employment)|eeo|compensation|salary|pay (?:range|transparency)|privacy|diversity|how to apply|"
                r"what we offer|what you.ll get|life at|perks)",
                re.I
            )
        ),
        (
            'preferred',
            re.compile(
                r"^(?:preferred|desired|bonus|nice[- ]to[- ]haves?|pluses|extra credit|it.d be (?:great|nice)|even better|additional qualifications)",
                re.I
            )
        ),
        (
            'required',
            re.compile(
                r"^(?:what we.re looking for|what you.ll (?:need|bring)|what you bring|what we need|you (?:have|bring|should have|might be)|"
                r"who you are|about you|must[- ]haves?|(?:minimum|basic|required|key) (?:qualifications|requirements|skills)|"
                r"requirements|qualifications|skills(?: (?:and|&) experience)?|(?:the )?ideal candidate|we.re looking for|you.re a (?:good|great) fit)",
                re.I
            )
        ),
        (
            'duties',
            re.compile(
                r"^(?:(?:key )?responsibilities|what you.ll do|what you will do|you will|in this role|(?:about )?the role|as an? .{0,70}you will|"
                r"day[- ]to[- ]day|your impact|the opportunity)",
                re.I
            )
        )
    ];
    BOILERPLATE = re.compile(
        r"equal opportunity|without regard to|protected (?:veteran|characteristic)|authori[sz]ed to work|visa|sponsorship|"
        r"salary|compensation|\$\s?\d|401\(?k|benefits|pto\b|paid time off|accommodation",
        re.I
    );
    (DEMONSTRATED, ELSEWHERE, LISTED) = (1.0, 0.8, 0.6);
    METRIC_TARGET = 0.75;
    WORDS = (8, 35);
    BULLETS = (2, 6);
    CHRONOLOGICAL = re.compile(r'experience|employment|work|internship', re.I);
    EDUCATION = re.compile(r'education', re.I);
    MONTHS = {
        m: (i + 1)
        for (i, m) in enumerate(
            [
                'jan',
                'feb',
                'mar',
                'apr',
                'may',
                'jun',
                'jul',
                'aug',
                'sep',
                'oct',
                'nov',
                'dec'
            ]
        )
    };
    DATE = re.compile(
        r'\b(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+)?((?:19|20)\d\d)\b',
        re.I
    );
    CURRENT = re.compile(r'\b(present|current|now|ongoing)\b', re.I);
    METRIC = re.compile(
        r'\d|\$|%|\b(?:one|two|three|four|five|six|seven|eight|nine|ten|twelve|dozens?|hundreds?|thousands?|millions?|billions?|double[ds]?|tripled?|halved)\b',
        re.I
    );
    STOP = `set(
        'a an and are as at be by for from has have in into is it its of on or our that the their this to was were will with within you your we they them'
        ' through throughout next months month weeks week days recently quickly well able based targeting hybrid office onsite schedule'
        ' who what which while where when than then these those such can may must should would could using use used via per across over under about'.split()
    );
    GENERIC = `set(
        'experience experienced ability able strong excellent good great knowledge understanding familiarity proficiency proficient'
        ' skill skills year years work working team teams role candidate candidates including include includes new help plus'
        ' preferred required requirement requirements qualification qualifications degree bachelor master related field equivalent'
        ' job company opportunity position environment ideal level entry senior junior intern internship grad graduate etc other'
        ' like well also one two three more least minimum etc build building develop developing solution solutions product products'
        ' customer customers business make making provide providing ensure support supporting tools technologies technology'
        ' complex problem problems solid academic personal project projects concept concepts quality high highly maintainable'
        ' well-tested well-factored code engineering engineer engineers feature features class classes course courses'
        ' learn learning solve solving demonstrated demonstrate willingness closely hands-on real time world new/updated'.split()
    );
    SOFT = {
        'communication': ['communication', 'communicate', 'communicating'],
        'collaboration': [
            'collaboration',
            'collaborate',
            'collaborative',
            'cross-functional'
        ],
        'leadership': ['leadership', 'led', 'lead', 'leading', 'mentored', 'mentoring'],
        'problem solving': [
            'problem solving',
            'problem-solving',
            'troubleshooting',
            'debugging'
        ],
        'ownership': ['ownership', 'owned', 'end to end', 'end-to-end'],
        'attention to detail': ['attention to detail', 'detail-oriented']
    };
    TITLE_NOISE = `set(
        'new grad graduate entry level junior senior sr jr i ii iii iv intern internship co op coop the and of a an to for with remote hybrid contract full part time 2025 2026 2027 summer fall spring winter'.split()
    );
    STRONG = `set(
        'accelerate achieve add analyze architect audit automate balance benchmark build calibrate champion clarify coach collaborate'
        ' compile compute configure consolidate construct convert coordinate create cut debug decrease define deliver deploy'
        ' design detect develop diagnose direct discover document double drive eliminate enable engineer enhance establish'
        ' evaluate execute expand expedite extend extract facilitate forecast formalize founded generate grow guide identify'
        ' implement improve increase initiate innovate inspect instrument integrate introduce invent investigate launch lead'
        ' lower maintain manage map maximize measure mentor merge migrate minimize model modernize monitor negotiate optimize'
        ' orchestrate organize overhaul own parallelize partner pilot pioneer plan predict present prioritize produce profile'
        ' program propose prototype publish quantify raise rebuild recruit redesign reduce refactor research resolve restructure'
        ' revamp run save scale schedule secure serve ship simplify solve spearhead standardize streamline strengthen'
        ' structure supervise test train transform translate triage troubleshoot tune unify upgrade validate visualize win write'
        ' reject isolate ship serve generate own drive grow make teach sell oversee rebuild'.split()
    );
    IRREGULAR = {
        'led': 'lead',
        'built': 'build',
        'rebuilt': 'rebuild',
        'ran': 'run',
        'wrote': 'write',
        'won': 'win',
        'drove': 'drive',
        'grew': 'grow',
        'made': 'make',
        'taught': 'teach',
        'sold': 'sell',
        'oversaw': 'oversee',
        'cut': 'cut',
        'set': 'set',
        'spun': 'spin',
        'found': 'find'
    };
    WEAK = [
        'responsible for',
        'helped',
        'help',
        'assisted',
        'assist',
        'worked on',
        'work on',
        'participated in',
        'involved in',
        'tasked with',
        'duties included',
        'in charge of',
        'handled',
        'utilized',
        'contributed to',
        'was responsible',
        'exposure to',
        'familiar with'
    ];
    FILLER = [
        'various',
        'successfully',
        'effectively',
        'efficiently',
        'utilize',
        'utilized',
        'synergy',
        'detail-oriented',
        'hard-working',
        'hardworking',
        'team player',
        'go-getter',
        'self-starter',
        'results-driven',
        'results-oriented',
        'dynamic',
        'passionate',
        'motivated',
        'think outside the box',
        'best of breed',
        'value add',
        'value-add',
        'leveraged',
        'leverage',
        'robust',
        'cutting-edge',
        'state-of-the-art',
        'etc'
    ];
    PRONOUNS = re.compile(r'\b(I|me|my|mine|we|our|us)\b');
    PASSIVE = re.compile(
        r'\b(?:was|were|been|being|is|are)\s+(?:\w+ly\s+)?\w+ed\b', re.I
    );
}

def _plain(text: any) -> any {
    return str((text or '')).replace('**', '').strip();
}
def _words(text: any) -> any {
    return re.findall(r"[A-Za-z0-9][A-Za-z0-9+#'./-]*", _plain(text));
}
def _stems(text: any) -> any {
    return [matching.stem(w) for w in re.findall(r'[a-z0-9]+', _plain(text).lower())];
}
def _clip(text: any, size: any = 90) -> any {
    text = re.sub(r'\s+', ' ', _plain(text));
    return text if (len(text) <= size) else (text[:(size - 1)].rsplit(' ', 1)[0] + '…');
}
"""Flat view: bullets and headings (with where they are) and skill lines."""
def resume_items(outline: any) -> any {
    (bullets, headings, lines) = ([], [], []);
    for section in outline {
        for `entry in section.get('entries', []) {
            heading = _plain(`entry.get('heading', ''));
            where = (
                section['title'] + ((' · ' + heading.split(' | ')[0]) if heading else '')
            );
            if heading {
                headings.append(
                    {'id': `entry['id'], 'section': section['title'], 'text': heading}
                );
            }
            current = bool(CURRENT.search(heading));
            for bullet in `entry.get('bullets', []) {
                bullets.append(
                    {
                        'id': bullet['id'],
                        'entry': `entry['id'],
                        'section': section['title'],
                        'where': where,
                        'text': _plain(bullet['text']),
                        'current': current
                    }
                );
            }
        }
        for line in section.get('lines', []) {
            lines.append(
                {
                    'id': line['id'],
                    'section': section['title'],
                    'text': (
                        _plain(line.get('label', '')) + ': ' + _plain(line['text'])
                    )
                }
            );
        }
    }
    return (bullets, headings, lines);
}
"""The same outline shape from OpenResume fields, for resumes that are only a PDF."""
def outline_from_parser(values: any) -> any {
    def records(kind: any) -> any {
        indexes = sorted(
            {
                int(k.split('.')[1])
                for k in values
                if k.startswith((kind + '.'))
            }
        );
        return [
            (
                i,
                {
                    k.split('.', 2)[2]: v
                    for (k, v) in values.items()
                    if k.startswith((kind + '.' + str(i) + '.'))
                }
            ) for i in indexes
        ];
    }
    out = [];
    for (n, (kind, title, fields)) in enumerate(
        [
            ('educations', 'Education', ('school', 'degree', 'date')),
            ('workExperiences', 'Experience', ('company', 'jobTitle', 'date')),
            ('projects', 'Projects', ('project', 'date'))
        ]
    ) {
        entries = [];
        for (i, record) in records(kind) {
            bullets = [
                b.strip(' •-\t')
                for b in record.get('descriptions', '').split('\n')
                if b.strip(' •-\t')
            ];
            entries.append(
                {
                    'id': ('p' + str(n) + '.e' + str(i)),
                    'heading': ' | '.join(
                        record.get(f, '')
                        for f in fields
                        if record.get(f)
                    ),
                    'movable': True,
                    'bullets': [
                        {
                            'id': ('p' + str(n) + '.e' + str(i) + '.b' + str(j)),
                            'text': b
                        } for (j, b) in enumerate(bullets)
                    ]
                }
            );
        }
        if entries {
            out.append(
                {'id': ('p' + str(n)), 'title': title, 'entries': entries, 'lines': []}
            );
        }
    }
    skill_lines = [
        s
        for s in values.get('skills.descriptions', '').split('\n')
        if s.strip()
    ];
    if skill_lines {
        out.append(
            {
                'id': 'p3',
                'title': 'Skills',
                'entries': [],
                'lines': [
                    {'id': ('p3.l' + str(i)), 'label': '', 'text': s}
                    for (i, s) in enumerate(skill_lines)
                ]
            }
        );
    }
    return out;
}
"""(sentence, section) for the listing: required, preferred, duties, intro (text before any heading) or other.
    Benefits, company background, pay and EEO text are left out."""
def job_sentences(job: any) -> any {
    out = [];
    for field in ('description', 'qualifications', 'eligibility') {
        section = 'intro' if (field == 'description') else 'required';
        for line in str(matching.plain((job.get(field) or ''))).splitlines() {
            line = line.strip(' \t•●▪·*-–');
            if not line {
                continue;
            }
            head = line.rstrip(':').strip();
            if (
                (len(head) < 90) and (line.endswith(':') or (len(head.split()) <= 6))
            ) {
                kind = next(
                    (
                        k
                        for (k, p) in HEADINGS
                        if p.search(head)
                    ),
                    None
                );
                if kind {
                    section = kind;
                    continue;
                }
                if line.endswith(':') {
                    section = 'other';
                    continue;
                }
            }
            if (section == 'ignore') {
                continue;
            }
            for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z0-9$])|;\s+', line) {
                if (sentence.strip() and not BOILERPLATE.search(sentence)) {
                    out.append((sentence.strip(), section));
                }
            }
        }
    }
    return (out + [(str(r), 'required') for r in (job.get('requirements') or [])]);
}

"""Skills and keywords in the listing, weighted by where they appear, plus title, years and education."""
def job_requirements(job: any) -> any {
    sentences = job_sentences(job);
    found = {};
    def note(name: any, weight: any, count: any = 1) -> any {
        `entry = found.setdefault(
            name, {'term': name, 'weight': 0.0, 'count': 0, 'required': False}
        );
        `entry['weight'] = max(`entry['weight'], weight);
        `entry['count'] += count;
        `entry['required'] = (
            `entry['required'] or (weight >= SECTION_WEIGHT['required'])
        );
    }
    for name in skills.names(job.get('title', '')) {
        note(name, SECTION_WEIGHT['required']);
    }
    groups = [];
    phrases = {};
    for (sentence, section) in sentences {
        weight = SECTION_WEIGHT.get(section, 1.0);
        if matching.PREFERRED.search(sentence) {
            weight = min(weight, SECTION_WEIGHT['preferred']);
        } elif matching.REQUIRED.search(sentence) {
            weight = max(weight, SECTION_WEIGHT['required']);
        }
        for group in _alternatives(sentence) {
            for name in group {
                note(name, weight);
            }
            if (len(group) > 1) {
                groups.append(group);
            }
        }
        if (
            (section in ('required', 'preferred', 'duties'))
            or (weight >= SECTION_WEIGHT['required'])
        ) {
            for phrase in _phrases(sentence) {
                `entry = phrases.setdefault(
                    phrase, {'term': phrase, 'weight': 0.0, 'count': 0}
                );
                `entry['weight'] = max(`entry['weight'], weight);
                `entry['count'] += 1;
            }
        }
    }
    for `entry in found.values() {
        `entry['weight'] = round(
            (`entry['weight'] * (1 + (0.25 * min((`entry['count'] - 1), 4)))), 2
        );
    }
    (items, grouped) = ([], `set());
    for group in groups {
        members = [
            g
            for g in group
            if (g not in grouped)
        ];
        if (len(members) > 1) {
            grouped.update(members);
            best = max(
                (found[g] for g in members), key=lambda (e: any) { e['weight']; }
            );
            items.append(
                {
                    'term': (', '.join(members[:-1]) + ' or ' + members[-1]),
                    'alternatives': members,
                    'weight': best['weight'],
                    'count': max(found[g]['count'] for g in members),
                    'required': `any(found[g]['required'] for g in members)
                }
            );
        }
    }
    items += [
        {** e, 'alternatives': [e['term']]}
        for (name, e) in found.items()
        if (name not in grouped)
    ];
    covered = {w for name in found for w in _stems(name)};
    found_items = items;
    candidates = [
        p
        for p in phrases.values()
        if (
            not (`set(_stems(p['term'])) <= covered)
            and ((p['count'] > 1) or (p['weight'] >= SECTION_WEIGHT['required']))
        )
    ];
    shorter = {
        p['term']
        for p in candidates
        if (len(p['term'].split()) == 2)
    };
    candidates = [
        p
        for p in candidates
        if (
            (len(p['term'].split()) == 2) or not `any((t in p['term']) for t in shorter)
        )
    ];
    keywords = sorted(
        candidates, key=lambda (p: any) { ((-p['count'] * p['weight']), p['term']); }
    )[:10];
    text = ' '.join(s for (s, _) in sentences).lower();
    soft = [
        name
        for (name, forms) in SOFT.items()
        if `any(re.search((r'\b' + re.escape(f) + r'\b'), text) for f in forms)
    ];
    years = matching._years_facts(job, sentences).get('years');
    education = matching._education_facts(job, sentences).get('education');
    return {
        'skills': sorted(
            found_items, key=lambda (e: any) { (-e['weight'], e['term']); }
        ),
        'keywords': keywords,
        'soft': soft,
        'title': job.get('title', ''),
        'years': years,
        'education': education
    };
}
with entry {
    SEPARATOR = re.compile(r'^\s*(?:,|/|\(|\)|or|and|,\s*(?:or|and))?\s*$', re.I);
}
"""Skills in the sentence, grouped: a list joined by "or" ("C, C++, Rust, Java, or Go") is one group."""
def _alternatives(sentence: any) -> any {
    found = skills.mentions(sentence);
    (groups, run, joins) = ([], [], []);
    for (k, (name, start, end)) in enumerate(found) {
        between = sentence[found[(k - 1)][2]:start] if k else '';
        if (run and SEPARATOR.match(between)) {
            run.append(name);
            joins.append(between.lower());
            continue;
        }
        if run {
            groups.append((run, joins));
        }
        (run, joins) = ([name], []);
    }
    if run {
        groups.append((run, joins));
    }
    out = [];
    for (names, seps) in groups {
        if (
            (len(names) > 1)
            and `any(re.search(r'\bor\b|/', j) for j in seps)
            and not `any(re.search(r'\band\b', j) for j in seps)
        ) {
            out.append(`list(`dict.fromkeys(names)));
        } else {
            out += [[n] for n in `dict.fromkeys(names)];
        }
    }
    return out;
}
"""Two- and three-word phrases of content words within one clause ("distributed storage systems").
    Phrases do not cross punctuation, and names ("Seattle") are left out."""
def _phrases(sentence: any) -> any {
    out = `set();
    for clause in re.split(r'[,;:()]|\band\b|\bor\b|\bwith\b', sentence) {
        words = re.findall(r'[A-Za-z][A-Za-z+#-]*', clause);
        for n in (2, 3) {
            for i in range(((len(words) - n) + 1)) {
                gram = words[i:(i + n)];
                if `any(
                    (
                        (w.lower() in STOP)
                        or (w.lower() in GENERIC)
                        or (len(w) < 3)
                        or (w[0].isupper() and ((i + gram.index(w)) > 0))
                    ) for w in gram
                ) {
                    continue;
                }
                out.add(' '.join(w.lower() for w in gram));
            }
        }
    }
    return out;
}

"""Years across work entries from their dates; internships count half; overlaps count once."""
def _years_of(headings: any, now: any) -> any {
    spans = [];
    for h in headings {
        if not CHRONOLOGICAL.search(h['section']) {
            continue;
        }
        dates = [
            (int(y), MONTHS.get((m or 'jan')[:3].lower(), 1))
            for (m, y) in DATE.findall(h['text'])
        ];
        if not dates {
            continue;
        }
        today = now.year + ((now.month - 1) / 12);
        start = dates[0][0] + ((dates[0][1] - 1) / 12);
        if CURRENT.search(h['text']) {
            end = today;
        } elif (len(dates) > 1) {
            end = dates[-1][0] + (dates[-1][1] / 12);
        } else {
            end = start + 0.25;
        }
        end = min(end, today);
        if (end > start) {
            spans.append(
                (start, end, 0.5 if re.search(r'\bintern', h['text'], re.I) else 1.0)
            );
        }
    }
    (total, until) = (0.0, float('-inf'));
    for (start, end, factor) in sorted(spans) {
        start = max(start, until);
        if (end > start) {
            total += (end - start) * factor;
        }
        until = max(until, end);
    }
    return round(total, 1);
}
def _degree(headings: any, bullets: any, lines: any) -> any {
    text = ' '.join(
        h['text']
        for h in headings
        if EDUCATION.search(h['section'])
    );
    levels = [
        level
        for (level, pattern) in matching.DEGREES
        if pattern.search(text)
    ];
    return max(levels) if levels else 0;
}
"""text: the resume's full plain text, so skills outside bullets (coursework, a summary) still count."""
def `match(
    outline: any, job: any, facts: any = (), now: any = None, text: any = ''
) -> any {
    now = now or date.today();
    need = job_requirements(job);
    (bullets, headings, lines) = resume_items(outline);
    shown = ' \n'.join(([b['text'] for b in bullets] + [h['text'] for h in headings]));
    listed = ' \n'.join(l['text'] for l in lines);
    (in_shown, in_listed, in_text) = (
        skills.names(shown),
        skills.names(listed),
        skills.names(text)
    );
    fact_text = ' '.join(
        str(f.get('value', ''))
        for f in facts
        if f.get('verified')
    );
    in_facts = skills.names(fact_text);
    counts = {};
    for (name, _) in skills.find((shown + ' \n' + listed)) {
        counts[name] = counts.get(name, 0) + 1;
    }
    def credit(name: any) -> any {
        if (name in in_shown) {
            return (DEMONSTRATED, 'bullets');
        }
        if (name in (in_text - in_listed)) {
            return (ELSEWHERE, 'elsewhere');
        }
        if (name in in_listed) {
            return (LISTED, 'skills line');
        }
        return (0.0, '');
    }
    (components, matched, missing, stuffed) = ({}, [], [], []);
    total = sum(s['weight'] for s in need['skills']);
    if total {
        earned = 0.0;
        for s in need['skills'] {
            ((value, where), `by) = max(
                ((credit(a), a) for a in s['alternatives']),
                key=lambda (x: any) { x[0][0]; }
            );
            earned += s['weight'] * value;
            if value {
                matched.append(
                    {
                        'term': s['term'],
                        'where': where,
                        'required': s['required'],
                        'via': `by if (len(s['alternatives']) > 1) else ''
                    }
                );
            } else {
                missing.append(
                    {
                        'term': s['term'],
                        'required': s['required'],
                        'supported': `any((a in in_facts) for a in s['alternatives'])
                    }
                );
            }
            for a in s['alternatives'] {
                if ((counts.get(a, 0) >= 4) and (counts[a] > (s['count'] + 2))) {
                    stuffed.append({'term': a, 'count': counts[a]});
                }
            }
        }
        components['skills'] = earned / total;
    }
    title = [
        w
        for w in matching.tokens(need['title'])
        if ((w not in TITLE_NOISE) and (w not in STOP))
    ];
    if title {
        best = max(
            (
                (
                    len((`set(title) & `set(matching.tokens(h['text']))))
                    / len(`set(title))
                )
                for h in headings
                if CHRONOLOGICAL.search(h['section'])
            ),
            `default=0.0
        );
        components['title'] = best;
    }
    if need['education'] {
        (have, want) = (_degree(headings, bullets, lines), need['education']['level']);
        components['education'] = 1.0
            if (have >= want)
            else 0.75
                if need['education'].get('alternative')
                else 0.5 if (have == (want - 1)) else 0.0;
    }
    if (need['years'] and need['years'].get('min')) {
        components['experience'] = min(
            1.0, (_years_of(headings, now) / need['years']['min'])
        );
    }
    resume_stems = (
        ' ' + ' '.join(_stems((shown + ' \n ' + listed + ' \n ' + text))) + ' '
    );
    `has = lambda (phrase: any) { (
        (' ' + ' '.join(_stems(phrase)) + ' ') in resume_stems
    ); };
    keywords = need['keywords'];
    soft_found = [
        s
        for s in need['soft']
        if `any(
            re.search(
                (r'\b' + re.escape(f) + r'\b'),
                (shown + ' ' + listed + ' ' + text).lower()
            ) for f in SOFT[s]
        )
    ];
    if (keywords or need['soft']) {
        weight = sum(k['weight'] for k in keywords) + (0.5 * len(need['soft']));
        got = (
            sum(
                k['weight']
                for k in keywords
                if `has(k['term'])
            )
            + (0.5 * len(soft_found))
        );
        components['keywords'] = (got / weight) if weight else 1.0;
    }
    score = _combine(components, MATCH_WEIGHTS);
    return {
        'score': score,
        'components': _labelled(components, MATCH_WEIGHTS),
        'matched': matched,
        'missing': sorted(
            missing, key=lambda (m: any) { (not m['required'], m['term']); }
        ),
        'stuffed': stuffed,
        'keywords': [{'term': k['term'], 'found': `has(k['term'])} for k in keywords],
        'soft': [{'term': s, 'found': (s in soft_found)} for s in need['soft']],
        'requirements': {
            'years': need['years'],
            'education': need['education'],
            'title': need['title'],
            'resume_years': _years_of(headings, now) if need['years'] else None
        }
    };
}
def _opener(text: any) -> any {
    words = [w.lower() for w in _words(text)[:3]];
    return (' '.join(words[:2]), words[0] if words else '');
}
"""(base verb, form) for a strong opener: form is past, present or ing. ('', '') when not a known strong verb."""
def _verb(word: any) -> any {
    if (word in IRREGULAR) {
        return (IRREGULAR[word], 'past');
    }
    if (word in STRONG) {
        return (word, 'present');
    }
    if (word.endswith('s') and (word[:-1] in STRONG)) {
        return (word[:-1], 'present');
    }
    if word.endswith('ed') {
        for base in (word[:-2], word[:-1], (word[:-3] + 'y'), word[:-3]) {
            if (base in STRONG) {
                return (base, 'past');
            }
        }
    }
    if word.endswith('ing') {
        for base in (word[:-3], (word[:-3] + 'e'), word[:-4]) {
            if (base in STRONG) {
                return (base, 'ing');
            }
        }
    }
    return ('', '');
}
"""What makes one bullet read worse: a weak opener, filler words, pronouns or passive voice."""
def bullet_flaws(text: any) -> any {
    (pair, first) = _opener(text);
    low = _plain(text).lower();
    flaws = {
        ('opens with "' + w + '"')
        for w in WEAK
        if (pair.startswith(w) or (first == w))
    };
    flaws |= {
        ('"' + f + '"')
        for f in FILLER
        if re.search((r'\b' + re.escape(f) + r'\b'), low)
    };
    if PRONOUNS.search(_plain(text)) {
        flaws.add('a personal pronoun');
    }
    if PASSIVE.search(_plain(text)) {
        flaws.add('passive voice');
    }
    return flaws;
}
def quality(outline: any, parse: any = None, pages: any = None) -> any {
    (bullets, _, _) = resume_items(outline);
    (components, issues) = ({}, []);
    if bullets {
        unquantified = [
            b
            for b in bullets
            if not METRIC.search(b['text'])
        ];
        components['metrics'] = min(
            1.0, ((len(bullets) - len(unquantified)) / len(bullets) / METRIC_TARGET)
        );
        issues += [
            {
                'kind': 'metric',
                'id': b['id'],
                'where': b['where'],
                'text': _clip(b['text']),
                'detail': 'No number, %, $ or scale'
            } for b in unquantified
        ];
        (verb_scores, openers) = ([], {});
        for b in bullets {
            (pair, first) = _opener(b['text']);
            weak = next(
                (
                    w
                    for w in WEAK
                    if (pair.startswith(w) or (first == w))
                ),
                None
            );
            base = _verb(first)[0];
            if weak {
                verb_scores.append(0.0);
                issues.append(
                    {
                        'kind': 'weak_verb',
                        'id': b['id'],
                        'where': b['where'],
                        'text': _clip(b['text']),
                        'detail': ('Opens with "' + weak + '"')
                    }
                );
            } else {
                verb_scores.append(1.0 if base else 0.5);
            }
            if base {
                openers.setdefault(base, []).append(b);
            }
        }
        components['verbs'] = sum(verb_scores) / len(verb_scores);
        repeats = 0;
        for (verb, group) in openers.items() {
            if (len(group) > 2) {
                repeats += len(group) - 2;
                issues.append(
                    {
                        'kind': 'repeated_opener',
                        'ids': [b['id'] for b in group],
                        'where': (str(len(group)) + ' bullets'),
                        'text': (verb.capitalize() + '…'),
                        'detail': (
                            'Same opening verb in ' + str(len(group)) + ' bullets'
                        )
                    }
                );
            }
        }
        known = {
            w for b in bullets for name in skills.names(b['text']) for w in _stems(name)
        };
        usage = {};
        for b in bullets {
            for w in `set(_stems(b['text'])) {
                if (
                    (len(w) > 3)
                    and (w not in STOP)
                    and (w not in known)
                    and not w.isdigit()
                ) {
                    usage.setdefault(w, []).append(b['id']);
                }
            }
        }
        overused = [
            w
            for (w, ids) in usage.items()
            if (len(ids) >= max(4, math.ceil((len(bullets) * 0.3))))
        ];
        repeats += len(overused);
        issues += [
            {
                'kind': 'overused_word',
                'ids': usage[w],
                'where': (str(len(usage[w])) + ' bullets'),
                'text': w,
                'detail': ('Word used in ' + str(len(usage[w])) + ' bullets')
            } for w in overused
        ];
        components['repetition'] = max(0.0, (1.0 - (0.15 * repeats)));
        lengths = [len(_words(b['text'])) for b in bullets];
        in_range = [(WORDS[0] <= n <= WORDS[1]) for n in lengths];
        per_entry = {};
        for b in bullets {
            per_entry[b['entry']] = per_entry.get(b['entry'], 0) + 1;
        }
        entries_ok = [(BULLETS[0] <= n <= BULLETS[1]) for n in per_entry.values()];
        brevity = (
            ((0.7 * sum(in_range)) / len(in_range))
            + (0.3 * ((sum(entries_ok) / len(entries_ok)) if entries_ok else 1.0))
        );
        components['brevity'] = brevity * (0.8 if (pages and (pages > 1)) else 1.0);
        issues += [
            {
                'kind': 'length',
                'id': b['id'],
                'where': b['where'],
                'text': _clip(b['text']),
                'detail': (
                    str(n)
                    + ' words (aim for '
                    + str(WORDS[0])
                    + '–'
                    + str(WORDS[1])
                    + ')'
                )
            }
            for (b, n, ok) in zip(bullets, lengths, in_range)
            if not ok
        ];
        clarity = 0;
        for b in bullets {
            low = b['text'].lower();
            found = [
                f
                for f in FILLER
                if re.search((r'\b' + re.escape(f) + r'\b'), low)
            ];
            if PRONOUNS.search(b['text']) {
                found.append('personal pronoun');
            }
            if PASSIVE.search(b['text']) {
                found.append('passive voice');
            }
            if found {
                clarity += len(found);
                issues.append(
                    {
                        'kind': 'clarity',
                        'id': b['id'],
                        'where': b['where'],
                        'text': _clip(b['text']),
                        'detail': ', '.join(found[:3])
                    }
                );
            }
        }
        components['clarity'] = max(0.0, (1.0 - (0.1 * clarity)));
        tense_off = [];
        for b in bullets {
            if ((_verb(_opener(b['text'])[1])[1] == 'present') and not b['current']) {
                tense_off.append(b);
            }
        }
        issues += [
            {
                'kind': 'tense',
                'id': b['id'],
                'where': b['where'],
                'text': _clip(b['text']),
                'detail': 'Present tense in a past role'
            } for b in tense_off
        ];
        components['tense'] = 1.0 - (len(tense_off) / len(bullets));
    }
    if (parse and parse.get('total')) {
        components['parsing'] = parse.get('passed', 0) / parse['total'];
    }
    return {
        'score': _combine(components, QUALITY_WEIGHTS),
        'components': _labelled(components, QUALITY_WEIGHTS),
        'issues': issues,
        'bullets': len(bullets)
    };
}
with entry {
    LABELS = {
        'skills': 'Hard skills',
        'title': 'Job title',
        'education': 'Education',
        'experience': 'Experience',
        'keywords': 'Other keywords',
        'metrics': 'Quantified results',
        'verbs': 'Action verbs',
        'repetition': 'Repetition',
        'brevity': 'Brevity',
        'clarity': 'Clarity',
        'tense': 'Tense',
        'parsing': 'Parser check'
    };
}
def _combine(components: any, weights: any) -> any {
    total = sum(weights[k] for k in components);
    return round(
        ((100 * sum((weights[k] * v) for (k, v) in components.items())) / total)
    )
        if total
        else None;
}
def _labelled(components: any, weights: any) -> any {
    return [
        {'key': k, 'label': LABELS[k], 'score': round((100 * v)), 'weight': weights[k]}
        for (k, v) in components.items()
    ];
}
def score(
    outline: any,
    job: any,
    facts: any = (),
    parse: any = None,
    pages: any = None,
    now: any = None,
    text: any = ''
) -> any {
    return {
        'version': VERSION,
        'match': `match(outline, job, facts, now, text),
        'quality': quality(outline, parse, pages)
    };
}
"""Concrete, honest targets for the tailor prompt. Missing skills are listed only when the resume or the
    user's verified facts support them; everything else stays a gap for the user."""
def guidance(result: any, limit: any = 8) -> any {
    (m, q) = (result['match'], result['quality']);
    by_kind = {};
    for issue in q['issues'] {
        by_kind.setdefault(issue['kind'], []).append(issue);
    }
    return {
        'skills_only_listed': [
            x['term']
            for x in m['matched']
            if (x['where'] == 'skills line')
        ][:limit],
        'missing_supported_by_facts': [
            x['term']
            for x in m['missing']
            if x['supported']
        ][:limit],
        'job_keywords_missing': [
            k['term']
            for k in m['keywords']
            if not k['found']
        ][:limit],
        'unquantified_bullets': [i['id'] for i in by_kind.get('metric', [])][:limit],
        'weak_openers': [
            {'id': i['id'], 'issue': i['detail']} for i in by_kind.get('weak_verb', [])
        ][:limit],
        'repeated_openers': [
            {'verb': i['text'].rstrip('…'), 'ids': i['ids']}
            for i in by_kind.get('repeated_opener', [])
        ][:limit],
        'overused_words': [i['text'] for i in by_kind.get('overused_word', [])][:limit],
        'wordy_or_unclear': [
            {'id': i['id'], 'issue': i['detail']}
            for i in (by_kind.get('clarity', []) + by_kind.get('length', []))
        ][:limit],
        'stuffed': [s['term'] for s in m['stuffed']]
    };
}

"""What the app shows: scores, components, and the top items, small enough to store with a resume."""
def summary(result: any) -> any {
    (m, q) = (result['match'], result['quality']);
    return {
        'version': result['version'],
        'match': m['score'],
        'quality': q['score'],
        'match_components': m['components'],
        'quality_components': q['components'],
        'missing': m['missing'][:12],
        'listed_only': [
            x['term']
            for x in m['matched']
            if (x['where'] == 'skills line')
        ][:12],
        'keywords': m['keywords'],
        'stuffed': m['stuffed'],
        'requirements': m['requirements'],
        'issues': q['issues'][:12]
    };
}

