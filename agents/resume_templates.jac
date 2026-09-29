"""Built-in LaTeX templates filled from confirmed resume details. Output is ordinary .tex that Stack tailors like an upload."""
import re;
import from pathlib { Path }
import from agents.latex { escape }
with entry {
    TEMPLATES = {'jake': "Jake's Resume", 'classic': 'Classic'};
    NAME_STYLE = {
        'jake': '\\textbf{\\Huge \\scshape {name}} \\\\ \\vspace{1pt}',
        'classic': '{\\LARGE\\bfseries {name}} \\\\ \\vspace{3pt}'
    };
}
def _items(value: any) -> any {
    return [
        re.sub(r'^\s*[•\-–*·]\s*', '', line).strip()
        for line in str((value or '')).splitlines()
        if line.strip(' •-–*·')
    ];
}
def _indexes(values: any, section: any) -> any {
    return sorted(
        {
            int(k.split('.')[1])
            for k in values
            if (k.startswith((section + '.')) and k.split('.')[1].isdigit())
        }
    );
}
def _bullets(lines: any, indent: any) -> any {
    if not lines {
        return [];
    }
    pad = ' ' * indent;
    return (
        [(pad + '\\resumeItemListStart')]
        + [(pad + '  \\resumeItem{' + escape(line) + '}') for line in lines]
        + [(pad + '\\resumeItemListEnd')]
    );
}
def body(template: any, values: any) -> any {
    v = lambda (key: any) { str((values.get(key, '') or '')).strip(); };
    name = v('profile.name') or 'Your Name';
    contact = [];
    for key in ('profile.phone', 'profile.email', 'profile.url', 'profile.location') {
        value = v(key);
        if not value {
            continue;
        }
        if (key == 'profile.email') {
            contact.append(
                (
                    '\\href{mailto:'
                    + value.replace('\\', '').replace('}', '')
                    + '}{\\underline{'
                    + escape(value)
                    + '}}'
                )
            );
        } elif (key == 'profile.url') {
            url = value if value.startswith('http') else ('https://' + value);
            contact.append(
                (
                    '\\href{'
                    + url.replace('\\', '').replace('}', '').replace(
                        '%', '\\%'
                    ).replace(
                        '#', '\\#'
                    )
                    + '}{\\underline{'
                    + escape(value)
                    + '}}'
                )
            );
        } else {
            contact.append(escape(value));
        }
    }
    out = [
        '\\begin{center}',
        ('    ' + NAME_STYLE[template].replace('{name}', escape(name))),
        ('    \\small ' + ' $|$ '.join(contact)),
        '\\end{center}',
        ''
    ];
    if v('profile.summary') {
        out += ['\\section{Summary}', escape(v('profile.summary')), ''];
    }
    groups = [
        ('educations', 'Education'),
        ('workExperiences', 'Experience'),
        ('projects', 'Projects')
    ];
    for (section, title) in groups {
        rows = [];
        for i in _indexes(values, section) {
            p = section + '.' + str(i) + '.';
            if (section == 'educations') {
                (school, degree) = (v((p + 'school')), v((p + 'degree')));
                if not (school or degree) {
                    continue;
                }
                if v((p + 'gpa')) {
                    degree = (
                        ((degree + ', ') if degree else '') + 'GPA: ' + v((p + 'gpa'))
                    );
                }
                rows += [
                    '    \\resumeSubheading',
                    ('      {' + escape(school) + '}{' + escape(v((p + 'date'))) + '}'),
                    ('      {' + escape(degree) + '}{}')
                ];
            } elif (section == 'workExperiences') {
                (title_, company) = (v((p + 'jobTitle')), v((p + 'company')));
                if not (title_ or company) {
                    continue;
                }
                rows += [
                    '    \\resumeSubheading',
                    (
                        '      {'
                        + escape((title_ or company))
                        + '}{'
                        + escape(v((p + 'date')))
                        + '}'
                    ),
                    ('      {' + escape(company if title_ else '') + '}{}')
                ];
            } else {
                project = v((p + 'project'));
                if not project {
                    continue;
                }
                rows += [
                    '    \\resumeProjectHeading',
                    (
                        '      {\\textbf{'
                        + escape(project)
                        + '}}{'
                        + escape(v((p + 'date')))
                        + '}'
                    )
                ];
            }
            rows += _bullets(_items(v((p + 'descriptions'))), 6);
        }
        if rows {
            out += (
                [('\\section{' + title + '}'), '  \\resumeSubHeadingListStart']
                + rows
                + ['  \\resumeSubHeadingListEnd', '']
            );
        }
    }
    skills = _items(v('skills.descriptions'));
    if skills {
        lines = [];
        for line in skills {
            (label, sep, rest) = line.partition(':');
            if (sep and rest.strip() and (len(label) <= 40)) {
                lines.append(
                    (
                        '     \\textbf{'
                        + escape(label.strip())
                        + '}{: '
                        + escape(rest.strip())
                        + '}'
                    )
                );
            } else {
                lines.append(('     ' + escape(line)));
            }
        }
        out += [
            '\\section{Skills}',
            ' \\begin{itemize}[leftmargin=0.15in, label={}]',
            '    \\small{\\item{',
            ' \\\\\n'.join(lines),
            '    }}',
            ' \\end{itemize}',
            ''
        ];
    }
    extra = _items(v('additional.descriptions'));
    if extra {
        out += [
            '\\section{Additional}',
            '  \\resumeSubHeadingListStart',
            '    \\item',
            '    \\resumeItemListStart'
        ];
        out += [('      \\resumeItem{' + escape(line) + '}') for line in extra];
        out += ['    \\resumeItemListEnd', '  \\resumeSubHeadingListEnd', ''];
    }
    return '\n'.join(out);
}
"""Returns a source {'main', 'files'} for a built-in template."""
def fill(template: any, values: any) -> any {
    if (template not in TEMPLATES) {
        raise ValueError('Choose one of the built-in templates.');
    }
    if not `any(str(x).strip() for x in values.values()) {
        raise ValueError(
            'Confirm your resume details first, so Stack can fill the template.'
        );
    }
    base = (Path(__file__).parent / 'templates' / (template + '.tex')).read_text();
    return {
        'main': 'resume.tex',
        'files': {
            'resume.tex': base.replace(
                '%%STACK_BODY%%', body(template, values)
            ).encode()
        }
    };
}

