"""Pinned upstream resume designs, adapted to Stack's editable content macros."""
import re
from pathlib import Path

TEMPLATES = {
    'awesome-cv': 'Awesome-CV',
    'bill-ryan': "Bill Ryan's Elegant Resume",
    'sb2nov': "Sourabh Bajaj's Resume",
    'deedy': 'Deedy Resume',
    'jan-kuster': "Jan Kuster's Classic CV",
}
LATEX_RECORD_TEMPLATES = frozenset(TEMPLATES) | {'jake'}
ROOT = Path(__file__).parent / 'templates'


def fill(template, body):
    """Return portable source with the selected design's class, fonts and notices."""
    folder = ROOT / template
    files = {p.relative_to(folder).as_posix(): p.read_bytes()
             for p in folder.rglob('*') if p.is_file()}
    if template == 'deedy':
        # Keep the header full width and content in source order. A section
        # boundary keeps a heading together with its entries in either column.
        parts = re.split(r'(?=\\section\{)', body)
        header, sections = parts[0], parts[1:]
        split = min(range(1, len(sections)),
                    key=lambda i: abs(len(''.join(sections[:i])) / max(1, len(''.join(sections))) - .33)) if len(sections) > 1 else len(sections)
        body = (header + '\n\\columnratio{0.32}\\begin{paracol}{2}\n'
                + ''.join(sections[:split])
                + '\n\\switchcolumn\n'
                + ''.join(sections[split:]) + '\n\\end{paracol}\n')
    files['resume.tex'] = (ROOT / (template + '.tex')).read_text(encoding='utf-8').replace('%%STACK_BODY%%', body).encode()
    return {'main': 'resume.tex', 'files': files}


def records_source(template, records):
    """Render reviewed text verbatim, without guessing structured resume fields."""
    # The structured-details escape helper normalizes quotes and Markdown.
    # Reviewed records must retain those characters exactly as approved.
    replacements = str.maketrans({
        '\\': r'\textbackslash{}', '{': r'\{', '}': r'\}',
        '#': r'\#', '$': r'\$', '%': r'\%', '&': r'\&', '_': r'\_',
        '^': r'\textasciicircum{}', '~': r'\textasciitilde{}',
    })
    if template == 'awesome-cv':
        # Source Sans Pro's shared hyphen glyph extracts as U+2011 in XeTeX.
        # Use the bundled TeX monospace face for literal ASCII hyphens.
        replacements[ord('-')] = r'\texttt{-}'
    if template == 'jake':
        replacements.update(str.maketrans({
            "'": r'\textquotesingle{}', '"': r'\textquotedbl{}', '`': r'\textasciigrave{}',
            '<': r'\textless{}', '>': r'\textgreater{}',
        }))
        # Jake's TeX font joins pairs such as ff and --. Break the ligatures
        # while keeping the visible characters and exact extracted resume text.
        escaped = [(record['kind'], re.sub(r'f(?=[fil])|-(?=-)', lambda match: match[0] + r'\kern0pt{}',
                                           record['text'].translate(replacements))) for record in records]
        return fill(template, _jake_records(escaped))
    lines, listing = [], False
    for index, record in enumerate(records):
        kind, text = record['kind'], record['text'].translate(replacements)
        if listing and kind != 'bullet':
            lines.append(r'\resumeItemListEnd')
            listing = False
        if kind == 'heading':
            lines.append(r'\section{' + text + '}')
        elif kind == 'title':
            lines.append(r'\begin{center}\stackname{' + text + r'}\end{center}' if index == 0
                         else r'{\large\bfseries ' + text + r'}\par')
        elif kind == 'bullet':
            if not listing:
                lines.append(r'\resumeItemListStart')
                listing = True
            lines.append(r'\resumeItem{' + text + '}')
        else:
            lines.append(r'\noindent ' + text + r'\par')
    if listing:
        lines.append(r'\resumeItemListEnd')
    return fill(template, '\n'.join(lines))


def _jake_records(records):
    """Use Jake's masthead, ruled sections and nested lists with confirmed text."""
    lines = []
    if records and records[0][0] == 'title':
        lines = [r'\begin{center}', r'\textbf{\Huge \scshape ' + records[0][1] + '}']
        end = 1
        while end < len(records) and records[end][0] == 'paragraph':
            lines.append(r'\par{\small ' + records[end][1] + '}')
            end += 1
        lines.append(r'\end{center}')
        records = records[end:]
    entries, bullets = False, False
    for index, (kind, text) in enumerate(records):
        follows_with_bullet = index + 1 < len(records) and records[index + 1][0] == 'bullet'
        if bullets and kind != 'bullet':
            lines.append(r'\resumeItemListEnd')
            bullets = False
        if entries and (kind == 'heading' or (kind != 'bullet' and not follows_with_bullet)):
            lines.append(r'\resumeSubHeadingListEnd')
            entries = False
        if kind == 'heading':
            lines.append(r'\section{' + text + '}')
        elif kind == 'bullet':
            if not bullets:
                lines.append(r'\resumeItemListStart')
                bullets = True
            lines.append(r'\resumeItem{' + text + '}')
        elif follows_with_bullet:
            if not entries:
                lines.append(r'\resumeSubHeadingListStart')
                entries = True
            # A reviewed record is an opaque line, so preserve its order and wrap long headers.
            lines.append(r'\item {\small\textbf{' + text + '}}')
        else:
            lines.append(r'\noindent {\small ' + text + r'}\par')
    if bullets:
        lines.append(r'\resumeItemListEnd')
    if entries:
        lines.append(r'\resumeSubHeadingListEnd')
    return '\n'.join(lines)
