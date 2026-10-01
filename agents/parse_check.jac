"""Does OpenResume read a tailored resume back correctly? Compares the parser's fields with what Stack wrote.

`values` are the parser's flat fields (see agents/resume_parser.jac), `text` its extracted text, and
`outline` the tailored LaTeX outline (agents.latex.outline). No model or network calls.
"""
import re;
import from agents { latex }
import from agents.tailoring { RESIDUE }
with entry {
    EMAIL = re.compile(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
    PHONE = re.compile(r'\+?\(?\d[\d\s().-]{7,}\d');
    KINDS = [
        (
            'workExperiences',
            re.compile(r'experience|employment|work|internship', re.I),
            ('company', 'jobTitle')
        ),
        ('educations', re.compile(r'education', re.I), ('school', 'degree')),
        ('projects', re.compile(r'project', re.I), ('project', )),
        ('skills', re.compile(r'skill', re.I), ())
    ];
}
"""Letters and digits only, so line wrapping, hyphenation and punctuation do not matter."""
def _key(text: any) -> any {
    return re.sub(r'[^a-z0-9]', '', text.replace('**', '').lower());
}
"""Name, email and phone as written in the resume header (before the first section)."""
def expected_profile(tex: any) -> any {
    begin = tex.find('\\begin{document}');
    head = tex[begin:] if (begin >= 0) else tex;
    head = head[:head.find('\\section')] if ('\\section' in head) else head;
    name = '';
    bold = re.search(r'\\textbf\s*\{', head);
    if bold {
        name = latex.plain(
            head[(bold.end() - 1):latex._group_end(
                latex.mask_comments(head), (bold.end() - 1)
            )]
        );
    }
    text = latex.plain(head);
    (email, phone) = (EMAIL.search(text), PHONE.search(text));
    return {
        'name': name.replace('**', '').strip(),
        'email': email.group(0) if email else '',
        'phone': phone.group(0).strip() if phone else ''
    };
}
def _same(field: any, written: any, parsed: any) -> any {
    if (field == 'phone') {
        return (re.sub(r'\D', '', written) == re.sub(r'\D', '', parsed));
    }
    return (_key(written) == _key(parsed));
}
def _records(values: any, kind: any) -> any {
    indexes = sorted(
        {
            int(k.split('.')[1])
            for k in values
            if k.startswith((kind + '.'))
        }
    );
    return [
        {
            k.split('.', 2)[2]: v
            for (k, v) in values.items()
            if k.startswith((kind + '.' + str(i) + '.'))
        } for i in indexes
    ];
}
def _read(`entry: any, record: any) -> any {
    described = _key(record.get('descriptions', ''));
    return [
        b
        for b in `entry['bullets']
        if (_key(b['text'])[:60] in described)
    ];
}
"""The parsed entry for this one: its name matches a heading part (exactly, or one contains the other),
    preferring exact names and then the record holding the most of its bullets. Each record is used once,
    so "Volunteer" and "Volunteer Swim Coach" are not confused."""
def _match(records: any, used: any, `entry: any, names: any, fields: any) -> any {
    wanted = [
        _key(n)
        for n in names
        if (len(_key(n)) >= 3)
    ];
    best: any = None; score: any = None;
    for (i, record) in enumerate(records) {
        if (i in used) {
            continue;
        }
        found = [_key(record.get(f, '')) for f in fields];
        exact = `any(
            (w == f) for w in wanted
            for f in found
            if f
        );
        if (
            not exact
            and not `any(
                ((w in f) or (f in w)) for w in wanted
                for f in found
                if f
            )
        ) {
            continue;
        }
        rank = (exact, len(_read(`entry, record)));
        if ((score is None) or (rank > score)) {
            (best, score) = (i, rank);
        }
    }
    if (best is not None) {
        used.add(best);
    }
    return records[best] if (best is not None) else None;
}

"""expected: the header's name, email and phone (expected_profile); each must be read back exactly."""
def compare(values: any, text: any, outline: any, expected: any = None) -> any {
    (checks, expected) = ([], (expected or {}));
    def add(label: any, ok: any, detail: any) -> any {
        checks.append({'label': label, 'ok': bool(ok), 'detail': detail});
    }
    for (field, label) in (('name', 'Name'), ('email', 'Email'), ('phone', 'Phone')) {
        (value, written) = (
            values.get(('profile.' + field), ''),
            expected.get(field, '')
        );
        if written {
            ok = _same(field, written, value);
            add(
                label,
                ok,
                value
                    if ok
                    else ('Read as ' + (value or 'nothing') + ', not ' + written)
            );
        } else {
            add(label, value, (value or 'Not found'));
        }
    }
    for section in outline {
        kind = next(
            (
                k
                for k in KINDS
                if k[1].search(section['title'])
            ),
            None
        );
        if (kind is None) {
            continue;
        }
        (name, _, fields) = kind;
        if (name == 'skills') {
            skills = _key(values.get('skills.descriptions', ''));
            missing = [
                l['label']
                for l in section['lines']
                if not all(
                    (_key(item) in skills)
                    for item in l['text'].split(',')
                    if _key(item)
                )
            ];
            if section['lines'] {
                add(
                    section['title'],
                    not missing,
                    'Every skill line read'
                        if not missing
                        else ('Missing items from: ' + ', '.join(missing[:3]))
                );
            }
            continue;
        }
        (records, used) = (_records(values, name), `set());
        for `entry in section['entries'] {
            if not `entry['heading'] {
                continue;
            }
            parts = [
                p.strip()
                for p in `entry['heading'].replace('**', '').split(' | ')
                if p.strip()
            ];
            label = section['title'] + ': ' + parts[0];
            record = _match(records, used, `entry, parts[:2], fields);
            if (record is None) {
                add(label, False, 'Not read as its own entry');
                continue;
            }
            read = _read(`entry, record);
            total = len(`entry['bullets']);
            add(
                label,
                (len(read) == total),
                (str(len(read)) + ' of ' + str(total) + ' bullets read')
                    if total
                    else 'Read as its own entry'
            );
        }
    }
    leaked = sorted(`set(RESIDUE.findall(text)));
    add(
        'No LaTeX code in the text',
        not leaked,
        ', '.join(leaked[:3]) if leaked else 'Clean'
    );
    return {
        'ok': all(c['ok'] for c in checks),
        'checks': checks,
        'passed': len(
            [
                c
                for c in checks
                if c['ok']
            ]
        ),
        'total': len(checks)
    };
}

