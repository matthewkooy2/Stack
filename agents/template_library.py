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
