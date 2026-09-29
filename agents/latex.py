"""LaTeX resume sources: safe loading, structure, content-only edits, and compilation. No model calls."""
import base64
import hashlib
import io
import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ALLOWED = {'.tex', '.cls', '.sty', '.bib', '.bst', '.png', '.jpg', '.jpeg', '.pdf', '.eps', '.ttf', '.otf'}
TEXT = {'.tex', '.cls', '.sty', '.bib', '.bst'}
MAX_UPLOAD = 2 * 1024 * 1024
MAX_TOTAL = 8 * 1024 * 1024
MAX_FILES = 50
# Overleaf compiles with pdfLaTeX; Tectonic is XeTeX. These pdfTeX-only settings do nothing under XeTeX.
SHIM = ('\\ifdefined\\pdfglyphtounicode\\else\\def\\pdfglyphtounicode#1#2{}\\fi'
        '\\ifdefined\\pdfgentounicode\\else\\newcount\\pdfgentounicode\\fi'
        '\\ifdefined\\pdfminorversion\\else\\newcount\\pdfminorversion\\fi'
        '\\ifdefined\\pdfsuppresswarningpagegroup\\else\\newcount\\pdfsuppresswarningpagegroup\\fi\n')
FORBIDDEN = re.compile(r'\\(write18|openout|directlua|luaexec|ShellEscape|pdfshellescape|openin)(?![A-Za-z])')
PATHS = re.compile(r'\\(input|include|includegraphics|includepdf|InputIfFileExists|lstinputlisting|verbatiminput|bibliography|addbibresource)\s*\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}')
BARE_INPUT = re.compile(r'\\input\s+([^\s{}\\%]+)')
SECTION = re.compile(r'\\(section\*?|cvsection|resumeSection)(?![A-Za-z])')
DEFINITION = re.compile(r'\\(?:re)?(?:newcommand|providecommand)\*?\s*(?:\{\s*\\([A-Za-z]+)\s*\}|\\([A-Za-z]+))\s*(?:\[(\d)\])?\s*(?:\[[^\]]*\])?\s*\{')
DEFAULT_BULLETS = {'resumeItem', 'resumeSubItem', 'cventry', 'item'}


# ---------- Loading and safety ----------

def _safe_path(value):
    value = value.strip()
    return not (value.startswith(('/', '~', '\\')) or '..' in value.replace('\\', '/').split('/') or ':' in value or '|' in value)


def lint(files):
    """Rejects commands that can touch anything outside the compile folder."""
    for path, data in files.items():
        if PurePosixPath(path).suffix.lower() not in TEXT:
            continue
        text = mask_comments(data.decode('utf-8', errors='replace'))
        found = FORBIDDEN.search(text)
        if found:
            raise ValueError(path + ' uses \\' + found.group(1) + ', which Stack does not run. Remove it and upload again.')
        for match in PATHS.finditer(text):
            for part in match.group(2).split(','):
                if not _safe_path(part):
                    raise ValueError(path + ' refers to a file outside your project (' + part.strip()[:80] + '). Use paths inside the project.')
        for match in BARE_INPUT.finditer(text):
            if not _safe_path(match.group(1)):
                raise ValueError(path + ' refers to a file outside your project.')


def _pick_main(files):
    candidates = []
    for path, data in files.items():
        if not path.lower().endswith('.tex'):
            continue
        text = mask_comments(data.decode('utf-8', errors='replace'))
        if '\\documentclass' in text and '\\begin{document}' in text:
            candidates.append(path)
    if not candidates:
        raise ValueError('No main .tex file was found. The main file needs \\documentclass and \\begin{document}.')
    preferred = [p for p in candidates if PurePosixPath(p).stem.lower() in ('main', 'resume', 'cv')]
    return sorted(preferred or candidates, key=lambda p: (p.count('/'), p))[0]


def _flatten(files, main, depth=0):
    """Inlines \\input/\\include files that exist in the project, so the whole resume is one editable file."""
    text = files[main].decode('utf-8')
    if depth > 3:
        return text
    masked = mask_comments(text)
    body_start = masked.find('\\begin{document}')
    out, pos = [], 0
    for match in re.finditer(r'\\(input|include)\s*\{([^}]*)\}', masked):
        if match.start() < body_start and depth == 0:
            continue
        name = match.group(2).strip()
        base = str(PurePosixPath(main).parent / name) if '/' in main else name
        for candidate in (base, base + '.tex'):
            candidate = str(PurePosixPath(candidate))
            if candidate in files and candidate.endswith('.tex'):
                out.append(text[pos:match.start()])
                out.append(_flatten(files, candidate, depth + 1).rstrip('\n'))
                pos = match.end()
                break
    out.append(text[pos:])
    return ''.join(out)


def load(name, raw):
    """A .tex file or an Overleaf source .zip -> {'main', 'files', 'skipped'}; the main file is flattened."""
    if len(raw) > MAX_UPLOAD:
        raise ValueError('Upload a LaTeX source of 2 MB or less.')
    lower = name.lower()
    skipped = []
    if lower.endswith('.tex'):
        files = {'resume.tex': raw}
    elif lower.endswith('.zip'):
        files, total = {}, 0
        try:
            archive = zipfile.ZipFile(io.BytesIO(raw))
        except zipfile.BadZipFile:
            raise ValueError('This .zip could not be opened. Download the source again from Overleaf.') from None
        with archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                path = PurePosixPath(info.filename)
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('The .zip contains a path outside the project.')
                if path.parts[0] == '__MACOSX' or any(p.startswith('.') for p in path.parts):
                    continue
                if path.suffix.lower() not in ALLOWED:
                    skipped.append(str(path))
                    continue
                total += info.file_size
                if total > MAX_TOTAL or len(files) >= MAX_FILES:
                    raise ValueError('The project is too large. Keep it under 50 files and 8 MB.')
                files[str(path)] = archive.read(info)
        tops = {PurePosixPath(p).parts[0] for p in files}
        if len(tops) == 1 and all(len(PurePosixPath(p).parts) > 1 for p in files):
            files = {str(PurePosixPath(*PurePosixPath(p).parts[1:])): v for p, v in files.items()}
    else:
        raise ValueError('Upload a .tex file, or the source .zip from Overleaf (Menu → Download → Source).')
    for path in files:
        if PurePosixPath(path).suffix.lower() in TEXT:
            try:
                files[path].decode('utf-8')
            except UnicodeDecodeError:
                raise ValueError(path + ' is not UTF-8 text.') from None
    lint(files)
    main = _pick_main(files)
    files[main] = _flatten(files, main).encode()
    return {'main': main, 'files': files, 'skipped': skipped}


def pack(source):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('.stack-main', source['main'])
        for path, data in sorted(source['files'].items()):
            archive.writestr(path, data)
    return out.getvalue()


def unpack(raw):
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        names = [n for n in archive.namelist() if n != '.stack-main']
        return {'main': archive.read('.stack-main').decode(), 'files': {n: archive.read(n) for n in names}}


def encode(source):
    """JSON-safe form for the worker API."""
    return {'main': source['main'], 'files': {p: base64.b64encode(v).decode() for p, v in source['files'].items()}, 'digest': digest(source)}


def decode(value):
    return {'main': value['main'], 'files': {p: base64.b64decode(v) for p, v in value['files'].items()}}


def digest(source):
    h = hashlib.sha256(source['main'].encode())
    for path, data in sorted(source['files'].items()):
        h.update(path.encode() + b'\0' + hashlib.sha256(data).digest())
    return h.hexdigest()


# ---------- Compilation ----------

def engine():
    path = os.environ.get('STACK_TECTONIC') or shutil.which('tectonic') or next(
        (p for p in ('/opt/homebrew/bin/tectonic', '/usr/local/bin/tectonic') if Path(p).exists()), '')
    if not path:
        raise ValueError('LaTeX is not set up on this Mac. Run: brew install tectonic')
    return path


def _log_error(log):
    lines = log.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('! '):
            where = next((m.group(1) for m in (re.match(r'l\.(\d+)', l) for l in lines[i + 1:i + 8]) if m), '')
            message = line[2:].strip()
            if where:
                message += ' (line ' + str(max(1, int(where) - 1)) + ')'
            return message
    return ''


def compile(source, timeout=120):
    """Compiles with Tectonic in an isolated temp folder. Returns {'pdf': bytes, 'pages': int}."""
    from pypdf import PdfReader
    main = source['main']
    with tempfile.TemporaryDirectory(prefix='stack-latex-') as directory:
        root = Path(directory)
        for path, data in source['files'].items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (root / main).write_bytes(SHIM.encode() + source['files'][main])
        try:
            result = subprocess.run([engine(), '-X', 'compile', '--untrusted', '--keep-logs', main], cwd=root,
                                    capture_output=True, timeout=timeout, env={**os.environ, 'TECTONIC_UNTRUSTED_MODE': '1'})
        except subprocess.TimeoutExpired:
            raise ValueError('LaTeX took too long. The first compile downloads packages; try again in a minute.') from None
        output = root / PurePosixPath(main).with_suffix('.pdf')
        if result.returncode or not output.exists():
            log_path = root / PurePosixPath(main).with_suffix('.log')
            log = log_path.read_text(errors='replace') if log_path.exists() else ''
            detail = _log_error(log) or (result.stderr.decode(errors='replace').strip().splitlines() or ['unknown error'])[-1]
            raise ValueError('LaTeX could not compile this resume: ' + detail[:300])
        pdf = output.read_bytes()
    return {'pdf': pdf, 'pages': len(PdfReader(io.BytesIO(pdf)).pages)}


# ---------- Text helpers ----------

def mask_comments(text):
    """Same-length copy with comments blanked, so offsets map back to the source."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '\\':
            i += 2
            continue
        if c == '%':
            while i < n and text[i] != '\n':
                out[i] = ' '
                i += 1
            continue
        i += 1
    return ''.join(out)


def _group_end(s, i):
    """s[i] is '{'; returns the index just past its matching '}'."""
    depth, j, n = 0, i, len(s)
    while j < n:
        c = s[j]
        if c == '\\':
            j += 2
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    raise ValueError('Your LaTeX has an unmatched brace near: ' + s[i:i + 60].strip())


def _args(s, i, limit=9):
    """Reads [optional] and {group} arguments starting at i. Returns ([(start, end) content spans], end)."""
    groups, j, n = [], i, len(s)
    while len(groups) < limit:
        k = j
        while k < n and s[k] in ' \t\r\n':
            k += 1
        if '\n\n' in s[j:k].replace('\r', ''):
            break
        if k < n and s[k] == '[' and not groups:
            close = s.find(']', k)
            if close < 0:
                break
            j = close + 1
            continue
        if k < n and s[k] == '{':
            end = _group_end(s, k)
            groups.append((k + 1, end - 1))
            j = end
            continue
        break
    return groups, j


INLINE = ('textbf', 'textit', 'emph', 'underline', 'textsc', 'texttt', 'textrm', 'textsf', 'small', 'footnotesize',
          'scriptsize', 'large', 'Large', 'normalsize', 'mbox', 'text', 'textnormal', 'uline', 'bfseries', 'itshape')
SYMBOLS = {'$|$': '|', '$\\sim$': '~', '$\\cdot$': '·', '$\\bullet$': '•', '$\\times$': '×', '$\\rightarrow$': '→',
           '$\\to$': '→', '$\\approx$': '≈', '$<$': '<', '$>$': '>', '$\\geq$': '≥', '$\\leq$': '≤', '\\textbar': '|',
           '\\textasciitilde': '~', '\\LaTeX': 'LaTeX', '\\TeX': 'TeX', '\\ldots': '...', '\\dots': '...'}


def plain(latex):
    """Readable text for a LaTeX fragment; bold becomes **bold** so it can survive a rewrite."""
    s = mask_comments(latex)
    for key, value in SYMBOLS.items():
        s = s.replace(key, value)
    s = re.sub(r'\\href\s*\{[^{}]*\}\s*\{', '{', s)
    for _ in range(4):
        s = re.sub(r'\\textbf\s*\{((?:[^{}]|\{[^{}]*\})*)\}', r'**\1**', s)
        s = re.sub(r'\\(?:' + '|'.join(INLINE) + r')(?![A-Za-z])\s*\{((?:[^{}]|\{[^{}]*\})*)\}', r'\1', s)
    s = re.sub(r'\\(?:vspace|hspace)\*?\s*\{[^{}]*\}', ' ', s)
    s = re.sub(r'\\(?:' + '|'.join(INLINE) + r')(?![A-Za-z])', ' ', s)
    s = s.replace('\\\\', ' ').replace('---', '—').replace('--', '–').replace('``', '“').replace("''", '”')
    kept = '&%$#_{}'
    s = re.sub(r'\\([&%$#_{}])', lambda m: chr(0xE000 + kept.index(m.group(1))), s)
    s = re.sub(r'(?<!\\)~', ' ', s)
    s = re.sub(r'\\[A-Za-z]+\*?', ' ', s)
    s = s.replace('{', '').replace('}', '').replace('$', '')
    s = ''.join(kept[ord(c) - 0xE000] if 0xE000 <= ord(c) < 0xE000 + len(kept) else c for c in s)
    s = re.sub(r'\*\*\s*\*\*', '', s)
    return re.sub(r'\s+', ' ', s).strip()


ESCAPES = {'\\': '\\textbackslash{}', '&': '\\&', '%': '\\%', '$': '\\$', '#': '\\#', '_': '\\_', '{': '\\{',
           '}': '\\}', '~': '\\textasciitilde{}', '^': '\\textasciicircum{}', '—': '---', '–': '--', '“': '``',
           '”': "''", '‘': '`', '’': "'", '→': '$\\rightarrow$', '×': '$\\times$', '≈': '$\\approx$',
           '≥': '$\\geq$', '≤': '$\\leq$', '•': '$\\bullet$', '·': '$\\cdot$', '|': '$|$', '<': '$<$', '>': '$>$'}


def escape(text):
    """Plain text (with optional **bold**) -> LaTeX. The model never writes raw LaTeX."""
    parts = re.split(r'\*\*(.+?)\*\*', text.strip())
    out = []
    for i, part in enumerate(parts):
        value = ''.join(ESCAPES.get(c, c) for c in part.replace('\r', '').replace('\n', ' '))
        out.append('\\textbf{' + value + '}' if i % 2 else value)
    return ''.join(out)


# ---------- Structure ----------

def _definitions(files):
    found = {}
    for path, data in files.items():
        if PurePosixPath(path).suffix.lower() not in ('.tex', '.cls', '.sty'):
            continue
        text = mask_comments(data.decode('utf-8', errors='replace'))
        for match in DEFINITION.finditer(text):
            name = match.group(1) or match.group(2)
            try:
                body = text[match.end() - 1:_group_end(text, match.end() - 1)]
            except ValueError:
                continue
            found[name] = (int(match.group(3) or 0), body)
    return found


def _macro_roles(files):
    definitions = _definitions(files)
    bullets = {n for n in DEFAULT_BULLETS if n not in definitions and n != 'item'}
    headings, list_ends, list_starts = set(), set(), set()
    for name, (arity, body) in definitions.items():
        if '\\end{itemize}' in body or '\\end{enumerate}' in body:
            list_ends.add(name)
        if '\\begin{itemize}' in body or '\\begin{enumerate}' in body:
            list_starts.add(name)
        if arity >= 2 and ('\\item' in body or 'heading' in name.lower()):
            headings.add(name)
        elif 'heading' in name.lower() and arity >= 1:
            headings.add(name)
        elif arity == 1 and '\\item' in body and 'tabular' not in body:
            bullets.add(name)
    changed = True
    while changed:
        changed = False
        for name, (arity, body) in definitions.items():
            if arity == 1 and name not in bullets and name not in headings and any('\\' + b + '{' in body.replace(' ', '') for b in bullets):
                bullets.add(name)
                changed = True
    return bullets, headings, list_ends, list_starts


def _macro_at(masked, i):
    match = re.match(r'\\([A-Za-z]+)', masked[i:])
    return match.group(1) if match else ''


def parse(source):
    """Finds sections, entries, bullets and 'Label: items' lines in the main file, with source offsets."""
    tex = source['files'][source['main']].decode('utf-8')
    masked = mask_comments(tex)
    begin = masked.find('\\begin{document}')
    end = masked.rfind('\\end{document}')
    if begin < 0 or end < 0:
        raise ValueError('The main file needs \\begin{document} and \\end{document}.')
    bullets_named, headings_named, list_ends, list_starts = _macro_roles(source['files'])
    structural = bullets_named | headings_named | list_ends | list_starts
    marks = [(m.start(), m) for m in SECTION.finditer(masked, begin, end)]
    sections, entries, bullets, lines = [], [], [], []
    for index, (start, match) in enumerate(marks):
        stop = marks[index + 1][0] if index + 1 < len(marks) else end
        groups, _ = _args(masked, match.end(), 1)
        title = plain(tex[groups[0][0]:groups[0][1]]) if groups else 'Section'
        sid = 's' + str(index)
        sections.append({'id': sid, 'title': title, 'start': start, 'end': stop})
        section_bullets, heads = [], []
        i = match.end()
        while i < stop:
            j = masked.find('\\', i, stop)
            if j < 0:
                break
            name = _macro_at(masked, j)
            if not name:
                i = j + 2
                continue
            after = j + 1 + len(name)
            if name in headings_named:
                groups, call_end = _args(masked, after)
                heads.append({'start': j, 'call_end': call_end, 'text': ' | '.join(t for t in (plain(tex[a:b]) for a, b in groups) if t)})
                i = call_end
            elif name in bullets_named:
                groups, call_end = _args(masked, after, 1)
                if groups:
                    section_bullets.append({'start': j, 'end': call_end, 'arg': groups[0], 'text': plain(tex[groups[0][0]:groups[0][1]])})
                i = call_end
            elif name == 'item':
                item = _bare_item(tex, masked, after, stop, structural)
                if item:
                    section_bullets.append({'start': j, **item})
                i = after
            else:
                i = after
        # Entries run from one heading to the next; the last ends after its bullet list closes.
        for k, head in enumerate(heads):
            eid = sid + '.e' + str(k)
            owned = [b for b in section_bullets if b['start'] > head['start'] and (k + 1 == len(heads) or b['start'] < heads[k + 1]['start'])]
            if k + 1 < len(heads):
                stop_at = heads[k + 1]['start']
                while stop_at > head['start'] and tex[stop_at - 1] in ' \t\r\n':
                    stop_at -= 1
            else:
                stop_at = _list_close(masked, owned[-1]['end'], stop, list_ends) if owned else head['call_end']
            entries.append({'id': eid, 'section': sid, 'heading': head['text'], 'start': head['start'], 'end': stop_at, 'movable': True})
            for n, b in enumerate(owned):
                b.update({'id': eid + '.b' + str(n), 'section': sid, 'entry': eid})
        loose = [b for b in section_bullets if 'id' not in b]
        if loose:
            eid = sid + '.e' + str(len(heads))
            entries.append({'id': eid, 'section': sid, 'heading': '', 'start': loose[0]['start'],
                            'end': _list_close(masked, loose[-1]['end'], stop, list_ends), 'movable': False})
            for n, b in enumerate(loose):
                b.update({'id': eid + '.b' + str(n), 'section': sid, 'entry': eid})
        bullets.extend(section_bullets)
        taken = [(b['start'], b['end']) for b in section_bullets]
        for m in re.finditer(r'\\textbf\s*\{', masked[:stop]):
            if m.start() < match.end() or any(a <= m.start() < b for a, b in taken):
                continue
            line = _labeled_line(tex, masked, m, stop)
            if line:
                owner = next((e['id'] for e in entries if e['section'] == sid and e['start'] <= line['start'] < e['end']), '')
                lines.append({'id': sid + '.l' + str(len([x for x in lines if x['section'] == sid])), 'section': sid, 'entry': owner, **line})
    return {'tex': tex, 'sections': sections, 'entries': entries, 'bullets': bullets, 'lines': lines}


def _list_close(masked, pos, stop, list_ends):
    """Extends an entry over the list end that closes its bullets."""
    k = pos
    while k < stop and masked[k] in ' \t\r\n':
        k += 1
    for token in ('\\end{itemize}', '\\end{enumerate}'):
        if masked.startswith(token, k):
            return k + len(token)
    name = _macro_at(masked, k)
    return k + 1 + len(name) if name in list_ends else pos


def _bare_item(tex, masked, i, stop, structural):
    """A plain \\item bullet: text up to the next \\item or list end at the same depth.
    An \\item that wraps other bullets, headings or lists is layout, not a bullet."""
    k = i
    while k < stop and masked[k] in ' \t':
        k += 1
    if k < stop and masked[k] == '[':
        return None
    if k < stop and masked[k] == '{':
        close = _group_end(masked, k)
        text = plain(tex[k + 1:close - 1])
        if any('\\' + name in masked[k:close] for name in structural) or '\\begin{' in masked[k:close]:
            return None
        if '\\textbf' in masked[k:close] and re.search(r'\\textbf\s*\{[^{}]*\}\s*\{?\s*:', masked[k:close]):
            return None
        return {'end': close, 'arg': (k + 1, close - 1), 'text': text} if text else None
    depth, j = 0, k
    while j < stop:
        c = masked[j]
        if c == '\\':
            name = _macro_at(masked, j)
            if name in structural:
                return None
            if depth == 0 and (name == 'item' or masked.startswith('\\end{itemize}', j) or masked.startswith('\\end{enumerate}', j) or masked.startswith('\\begin{', j)):
                break
            j += 1 + max(1, len(name))
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            if depth == 0:
                break
            depth -= 1
        j += 1
    while j > k and tex[j - 1] in ' \t\r\n':
        j -= 1
    fragment = masked[k:j]
    if not fragment.strip() or re.search(r'\\textbf\s*\{[^{}]*\}\s*\{?\s*:', fragment) or any(h in fragment for h in ('tabular', '\\begin')):
        return None
    return {'end': j, 'arg': (k, j), 'text': plain(tex[k:j])}


def _labeled_line(tex, masked, match, stop):
    """\\textbf{Label}{: items} or \\textbf{Label}: items (to \\\\, closing brace or line end)."""
    label_open = match.end() - 1
    label_close = _group_end(masked, label_open)
    label = plain(tex[label_open + 1:label_close - 1]).rstrip(':').strip()
    k = label_close
    while k < stop and masked[k] in ' \t':
        k += 1
    if k < stop and masked[k] == '{':
        close = _group_end(masked, k)
        inner = k + 1
        while inner < close - 1 and masked[inner] in ' \t:':
            inner += 1
        if ':' not in masked[k + 1:inner]:
            return None
        value_end = close - 1
    elif k < stop and masked[k] == ':' or tex[label_open + 1:label_close - 1].rstrip().endswith(':'):
        inner = k + 1 if masked[k] == ':' else k
        while inner < stop and masked[inner] in ' \t':
            inner += 1
        value_end = inner
        while value_end < stop and masked[value_end] != '\n' and not masked.startswith('\\\\', value_end) and masked[value_end] != '}':
            value_end += 1
    else:
        return None
    while value_end > inner and tex[value_end - 1] in ' \t':
        value_end -= 1
    text = plain(tex[inner:value_end])
    if not label or not text or len(label) > 60:
        return None
    return {'label': label, 'text': text, 'start': inner, 'end': value_end}


def outline(structure):
    """Compact, id-addressed view for the model and for diffs."""
    out = []
    for section in structure['sections']:
        sid = section['id']
        out.append({'id': sid, 'title': section['title'],
                    'entries': [{'id': e['id'], 'heading': e['heading'], 'movable': e['movable'],
                                 'bullets': [{'id': b['id'], 'text': b['text']} for b in structure['bullets'] if b['entry'] == e['id']]}
                                for e in structure['entries'] if e['section'] == sid],
                    'lines': [{'id': l['id'], 'label': l['label'], 'text': l['text']} for l in structure['lines'] if l['section'] == sid]})
    return out


def summary(structure):
    return {'sections': len(structure['sections']), 'entries': len([e for e in structure['entries'] if e['movable']]),
            'bullets': len(structure['bullets']), 'lines': len(structure['lines']),
            'titles': [s['title'] for s in structure['sections']]}


# ---------- Edits ----------

def _splice(tex, lo, hi, edits):
    out, pos = [], lo
    for start, end, text in sorted(edits, key=lambda e: e[0]):
        out.append(tex[pos:start])
        out.append(text)
        pos = end
    out.append(tex[pos:hi])
    return ''.join(out)


def _removal(tex, start, end):
    """Widens a removed span to its whole line when nothing else is on it."""
    a = start
    while a > 0 and tex[a - 1] in ' \t':
        a -= 1
    b = end
    while b < len(tex) and tex[b] in ' \t':
        b += 1
    if (a == 0 or tex[a - 1] == '\n') and (b == len(tex) or tex[b] == '\n'):
        return a, min(len(tex), b + 1)
    return start, end


def _permute(tex, slots, order, render):
    """Fills fixed slots with items in a new order; slots past the end are removed."""
    edits = []
    for i, slot in enumerate(slots):
        if i < len(order):
            edits.append((slot['start'], slot['end'], render(order[i])))
        else:
            a, b = _removal(tex, slot['start'], slot['end'])
            edits.append((a, b, ''))
    return edits


def apply(structure, plan):
    """plan: rewrites {id: text}, omit [ids], entry_order {section: [entry ids]}, bullet_order {entry: [bullet ids]}.
    Only content spans change; the preamble and macros are untouched."""
    tex = structure['tex']
    rewrites, omit = plan.get('rewrites', {}), set(plan.get('omit', []))
    by_entry = {}
    for b in structure['bullets']:
        by_entry.setdefault(b['entry'], []).append(b)
    bullets = {b['id']: b for b in structure['bullets']}
    lines = [l for l in structure['lines']]

    def bullet_text(bid):
        b = bullets[bid]
        if bid not in rewrites:
            return tex[b['start']:b['end']]
        a, z = b['arg']
        return tex[b['start']:a] + escape(rewrites[bid]) + tex[z:b['end']]

    def line_edits(owner, lo, hi):
        return [(l['start'], l['end'], escape(rewrites[l['id']])) for l in lines
                if l['entry'] == owner and l['id'] in rewrites and lo <= l['start'] < hi]

    def entry_text(e):
        own = by_entry.get(e['id'], [])
        wanted = [bid for bid in plan.get('bullet_order', {}).get(e['id'], []) if bid in bullets and bullets[bid]['entry'] == e['id']]
        order = wanted + [b['id'] for b in own if b['id'] not in wanted]
        order = [bid for bid in order if bid not in omit]
        if own and not order:
            order = [own[0]['id']]
        edits = _permute(tex, own, order, bullet_text) + line_edits(e['id'], e['start'], e['end'])
        return _splice(tex, e['start'], e['end'], edits)

    section_edits = []
    for section in structure['sections']:
        own = [e for e in structure['entries'] if e['section'] == section['id']]
        movable = [e for e in own if e['movable']]
        wanted = [eid for eid in plan.get('entry_order', {}).get(section['id'], []) if eid in {e['id'] for e in movable}]
        order = wanted + [e['id'] for e in movable if e['id'] not in wanted]
        kept = [eid for eid in order if eid not in omit]
        if movable and not kept and not [e for e in own if not e['movable']] and not [l for l in lines if l['section'] == section['id']]:
            section_edits.append((section['start'], section['end'], ''))
            continue
        if movable and not kept:
            kept = [movable[0]['id']]
        entries = {e['id']: e for e in own}
        edits = _permute(tex, movable, kept, lambda eid: entry_text(entries[eid]))
        edits += [(e['start'], e['end'], entry_text(e)) for e in own if not e['movable']]
        edits += line_edits('', section['start'], section['end'])
        section_edits.append((section['start'], section['end'], _splice(tex, section['start'], section['end'], edits)))
    return _splice(tex, 0, len(tex), section_edits)


def with_main(source, tex):
    return {'main': source['main'], 'files': {**source['files'], source['main']: tex.encode()}}
