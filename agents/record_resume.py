"""Reviewed, lossless text records and Stack-owned PDF/DOCX resume templates.

Import deliberately does not infer employers, credentials, dates or achievements.
Every extracted paragraph is retained for explicit review. Model edits have a
small supported surface: selection, ordering within a contiguous bullet group,
and removal of introductory filler. Other rewrites remain review notes.
"""
import base64
import hashlib
import io
import json
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile

MAX_BYTES = 10 * 1024 * 1024
MAX_TEXT = 60000
MAX_RECORDS = 300
KINDS = {'title', 'heading', 'paragraph', 'bullet'}
TEMPLATES = {'classic', 'jake'}
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'


def _docx_lines(raw):
    """Bound ZIP expansion and XML before parsing; never extract archive paths."""
    if not raw or len(raw) > MAX_BYTES:
        raise ValueError('Choose a PDF or DOCX of 10 MB or less.')
    try:
        with ZipFile(io.BytesIO(raw)) as archive:
            members = archive.infolist()
            names = [m.filename for m in members]
            if (len(members) > 256 or len(set(names)) != len(names)
                    or sum(m.file_size for m in members) > 8 * 1024 * 1024
                    or any(m.flag_bits & 1 for m in members)
                    or any('vbaProject' in n or n.startswith('word/embeddings/') for n in names)
                    or 'word/document.xml' not in names):
                raise ValueError('This DOCX exceeds the supported limits or contains embedded content.')
            # Headers, footers, drawings and tracked edits need a richer review
            # surface. Refuse these instead of silently losing their facts.
            if any(re.match(r'word/(header|footer)\d+\.xml$', n) for n in names):
                raise ValueError('Move DOCX header/footer content into the document body before importing.')
            xml = archive.read('word/document.xml')
            if b'<!DOCTYPE' in xml.upper() or b'<!ENTITY' in xml.upper():
                raise ValueError('Unsupported DOCX XML declarations.')
            root = ET.fromstring(xml)
            if any(root.find('.//{%s}%s' % (W, tag)) is not None
                   for tag in ('drawing', 'pict', 'object', 'del', 'ins', 'moveFrom', 'moveTo', 'moveFromRangeStart', 'moveFromRangeEnd', 'moveToRangeStart', 'moveToRangeEnd', 'txbxContent', 'altChunk', 'sym', 'footnoteReference', 'endnoteReference', 'fldSimple', 'instrText')):
                raise ValueError('Export a text-only DOCX with tracked changes accepted before importing.')
            lines = []
            for p in root.iter('{%s}p' % W):
                text = ''.join((node.text or '') if node.tag == '{%s}t' % W else
                               '\n' if node.tag in ('{%s}br' % W, '{%s}cr' % W) else
                               '\t' if node.tag == '{%s}tab' % W else
                               '-' if node.tag == '{%s}noBreakHyphen' % W else
                               '\u00ad' if node.tag == '{%s}softHyphen' % W else ''
                               for node in p.iter())
                lines.extend(text.splitlines())
            if sum(map(len, lines)) > MAX_TEXT + MAX_RECORDS * 2:
                raise ValueError('Resume text exceeds the supported limit.')
            return lines
    except (BadZipFile, ET.ParseError, KeyError, RuntimeError, OSError):
        raise ValueError('This DOCX could not be opened. Export a new copy.') from None


def inspect_docx(raw):
    """Use the existing OS-bounded document lane for untrusted ZIP/XML too."""
    from agents.pdf_safety import _python_executable, _run_worker, _slots
    if not raw or len(raw) > MAX_BYTES:
        raise ValueError('Choose a PDF or DOCX of 10 MB or less.')
    if not _slots.acquire(blocking=False):
        raise ValueError('Document processing is busy. Please try again shortly.')
    try:
        encoded = _run_worker([_python_executable(), '-I', '-S', str(Path(__file__).resolve()), 'docx'], raw)
        value = json.loads(encoded)
        if value.get('error'):
            raise ValueError(value['error'])
        if not isinstance(value.get('lines'), list) or any(not isinstance(s, str) for s in value['lines']):
            raise ValueError('DOCX processing returned invalid output.')
        return value['lines']
    finally:
        _slots.release()


def validate_upload(name: str, raw: bytes) -> str:
    if len(raw) > MAX_BYTES:
        raise ValueError('Choose a PDF or DOCX of 10 MB or less.')
    suffix = Path(name).suffix.lower()
    if suffix == '.pdf' and raw.startswith(b'%PDF-'):
        from agents.pdf_safety import inspect_pdf
        inspect_pdf(raw)
    elif suffix == '.docx':
        inspect_docx(raw)
    else:
        raise ValueError('Choose a valid PDF or DOCX, 10 MB or smaller.')
    return suffix


def import_records(name, raw):
    if Path(name).suffix.lower() == '.docx':
        lines = inspect_docx(raw)
    else:
        from agents.pdf_safety import inspect_pdf
        lines = inspect_pdf(raw, True, MAX_TEXT)['text'].splitlines()
    records = []
    for line in lines:
        text = line.strip()
        if not text:
            continue
        kind = 'paragraph'
        if re.match(r'^[•\-*] ', text):
            kind, text = 'bullet', text[2:]
        records.append({'id': 'r' + str(len(records)), 'kind': kind, 'text': text})
    if not records:
        raise ValueError('This resume has no readable text. Upload a text-based PDF or DOCX.')
    return validate_records(records)


def validate_records(records):
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_RECORDS:
        raise ValueError('Review between 1 and 300 resume records.')
    result, ids, size = [], set(), 0
    for record in records:
        if not isinstance(record, dict):
            raise ValueError('Invalid resume record.')
        rid, kind, text = record.get('id'), record.get('kind'), record.get('text')
        eligible = record.get('allow_omit', False)
        if (not isinstance(rid, str) or not re.fullmatch(r'r\d{1,4}', rid) or rid in ids
                or kind not in KINDS or not isinstance(eligible, bool) or not isinstance(text, str) or not text.strip()
                    or len(text) > 2000 or any((ord(c) < 32 and c not in '\t\n') or ord(c) == 127 for c in text)):
            raise ValueError('Each record needs a unique id, supported kind and 1–2,000 text characters.')
        text = re.sub(r'\s+', ' ', text).strip()
        size += len(text)
        result.append({'id': rid, 'kind': kind, 'text': text, **({'allow_omit': True} if eligible else {})})
        ids.add(rid)
    if size > MAX_TEXT:
        raise ValueError('Resume text exceeds the supported limit.')
    return result


def prepare(value):
    records = validate_records(value['records'])
    template = value.get('template', 'classic')
    if template not in TEMPLATES:
        raise ValueError('Choose the Classic or Jake template.')
    payload = {'records': records, 'template': template,
               'upload_digest': value['upload_digest'], 'revision': value['revision']}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    outline = []
    for record in records:
        if not outline or record['kind'] == 'heading':
            sid = 's' + str(len(outline))
            outline.append({'id': sid, 'title': record['text'] if record['kind'] == 'heading' else 'Resume',
                            'entries': [{'id': sid + '.e0', 'heading': '', 'bullets': []}], 'lines': []})
        if record['kind'] != 'heading':
            outline[-1]['entries'][0]['bullets'].append({'id': record['id'], 'text': record['text']})
    return {**payload, 'digest': digest, 'format': 'records', 'outline': outline}


def _supported_rewrite(before, after):
    # Entire remaining claim must be identical, including negation, attribution,
    # numbers and credentials. This intentionally does not trust model semantics.
    reduced = re.sub(r'^(?:I |Successfully |Duties included: )', '', before, count=1)
    return after == reduced or (reduced and after == reduced[0].upper() + reduced[1:])


def _groups(records):
    groups, current = [], []
    for record in records:
        if record['kind'] == 'bullet':
            current.append(record['id'])
        elif current:
            groups.append(current)
            current = []
    if current:
        groups.append(current)
    return groups


def _plan(prepared, data):
    by_id = {r['id']: r for r in prepared['records']}
    changes, notes, rewrites, omitted, orders = [], [], {}, [], {}
    for edit in data.get('rewrites', []):
        rid, after = edit.get('id'), edit.get('text', '')
        original = by_id.get(rid)
        if (not original or original['kind'] not in ('bullet', 'paragraph')
                or not isinstance(after, str) or rid in rewrites):
            continue
        if after == original['text']:
            continue
        if not _supported_rewrite(original['text'], after):
            notes.append('Kept ' + rid + ': the proposed rewrite changes wording beyond supported filler removal.')
            continue
        rewrites[rid] = after
        changes.append({'id': rid, 'kind': 'rewrite', 'where': rid, 'before': original['text'],
                        'after': after, 'reason': str(edit.get('reason', 'Remove introductory filler.'))[:500]})
    for edit in data.get('omit', []):
        rid = edit.get('id')
        original = by_id.get(rid)
        # Records stay by default. Selection requires the human's explicit
        # eligibility flag; numeric and known credential guards add protection.
        if (not original or original['kind'] != 'bullet' or not original.get('allow_omit', False) or rid in omitted
                or re.search(r'\d|certif|degree|bachelor|master|licens|credential|diploma|accredit|\b(?:CPA|CFA|PMP|RN|MD|PhD|BSc|MSc|MBA)\b', original['text'], re.I)):
            notes.append('Ignored an unsupported omission.')
            continue
        omitted.append(rid)
        changes.append({'id': 'omit:' + rid, 'kind': 'omit', 'where': rid, 'before': original['text'],
                        'after': '', 'reason': str(edit.get('reason', 'Select content relevant to the job.'))[:500]})
    ranking = list(dict.fromkeys(x for x in data.get('ranking', []) if x in by_id))
    for group in _groups(prepared['records']):
        order = [x for x in ranking if x in group] + [x for x in group if x not in ranking]
        if order != group:
            key = 'order:' + group[0]
            orders[key] = order
            changes.append({'id': key, 'kind': 'order', 'where': group[0], 'before': ', '.join(group),
                            'after': ', '.join(order), 'reason': 'Lead this bullet group with the most relevant content.'})
    return {'rewrites': rewrites, 'omit': omitted, 'orders': orders}, changes, notes


def _apply(prepared, plan, rejected):
    records = [dict(r) for r in prepared['records']]
    by_id = {r['id']: r for r in records}
    for group in _groups(records):
        key = 'order:' + group[0]
        if key not in rejected and key in plan['orders']:
            offset = next(i for i, r in enumerate(records) if r['id'] == group[0])
            records[offset:offset + len(group)] = [by_id[x] for x in plan['orders'][key]]
    for r in records:
        if r['id'] not in rejected:
            r['text'] = plan['rewrites'].get(r['id'], r['text'])
    return [r for r in records if r['id'] not in plan['omit'] or 'omit:' + r['id'] in rejected]


def _docx(records, template):
    # Minimal native OOXML: paragraphs remain fully editable, never screenshots.
    doc = ET.Element('{%s}document' % W)
    body = ET.SubElement(doc, '{%s}body' % W)
    for record in records:
        p = ET.SubElement(body, '{%s}p' % W)
        properties = ET.SubElement(p, '{%s}pPr' % W)
        if record['kind'] in ('title', 'heading'):
            ET.SubElement(properties, '{%s}keepNext' % W)
        ET.SubElement(properties, '{%s}spacing' % W, {'{%s}after' % W: '100' if template == 'classic' else '60'})
        if record['kind'] == 'bullet':
            ET.SubElement(properties, '{%s}ind' % W, {'{%s}left' % W: '180', '{%s}hanging' % W: '180'})
        run = ET.SubElement(p, '{%s}r' % W)
        props = ET.SubElement(run, '{%s}rPr' % W)
        ET.SubElement(props, '{%s}rFonts' % W, {'{%s}ascii' % W: 'Calibri', '{%s}hAnsi' % W: 'Calibri'})
        ET.SubElement(props, '{%s}sz' % W, {'{%s}val' % W: '36' if record['kind'] == 'title' else '22'})
        if record['kind'] in ('title', 'heading'):
            ET.SubElement(props, '{%s}b' % W)
        ET.SubElement(run, '{%s}t' % W).text = ('• ' if record['kind'] == 'bullet' else '') + record['text']
    sect = ET.SubElement(body, '{%s}sectPr' % W)
    ET.SubElement(sect, '{%s}pgSz' % W, {'{%s}w' % W: '12240', '{%s}h' % W: '15840'})
    ET.SubElement(sect, '{%s}pgMar' % W, {('{%s}' % W) + k: '864' for k in ('top', 'bottom', 'left', 'right')})
    output = io.BytesIO()
    with ZipFile(output, 'w', ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        archive.writestr('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        archive.writestr('word/document.xml', ET.tostring(doc, encoding='utf-8', xml_declaration=True))
    return output.getvalue()


def documents(records, template='classic'):
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import SimpleDocTemplate, Paragraph
    # Use bundled fonts on every platform, not optional system fonts.
    import reportlab
    font_dir = Path(reportlab.__file__).parent / 'fonts'
    for name, filename in [('StackResume', 'Vera.ttf'), ('StackResumeBold', 'VeraBd.ttf')]:
        if name not in pdfmetrics.getRegisteredFontNames():
            pdfmetrics.registerFont(TTFont(name, str(font_dir / filename)))
    supported = pdfmetrics.getFont('StackResume').face.charToGlyph
    if any(ord(c) not in supported for r in records for c in r['text']):
        raise ValueError('The Stack template font cannot display some characters. No output was saved.')
    output, story = io.BytesIO(), []
    for record in records:
        kind = record['kind']
        style = ParagraphStyle('record', fontName='StackResumeBold' if kind in ('title', 'heading') else 'StackResume',
                               fontSize=18 if kind == 'title' else 11, leading=15,
                               spaceAfter=8 if template == 'classic' else 5,
                               keepWithNext=kind in ('title', 'heading'),
                               leftIndent=12 if kind == 'bullet' else 0,
                               bulletFontName='StackResume', bulletFontSize=11)
        story.append(Paragraph(escape(record['text']), style, bulletText='•' if kind == 'bullet' else None))
    SimpleDocTemplate(output, pagesize=(612, 792), leftMargin=43.2, rightMargin=43.2,
                      topMargin=43.2, bottomMargin=43.2, title='Tailored resume').build(story)
    pdf, docx = output.getvalue(), _docx(records, template)
    checked = check_documents(pdf, docx, records)
    if not checked['ok']:
        raise ValueError('Generated file text differs from approved records. No output was saved.')
    return {'pdf': {'name': 'Tailored resume.pdf', 'content': base64.b64encode(pdf).decode(),
                    'pages': checked['pages'], 'text': checked['text']},
            'docx': {'name': 'Tailored resume.docx', 'content': base64.b64encode(docx).decode()}}


def check_documents(pdf, docx, records):
    from agents.pdf_safety import inspect_pdf
    checked = inspect_pdf(pdf, True, MAX_TEXT + MAX_RECORDS * 2)
    expected = ''.join(r['text'] for r in validate_records(records))
    clean = lambda s: re.sub(r'[\s•]', '', s)
    checks = [{'key': 'pdf_text', 'ok': clean(expected) == clean(checked['text'])},
              {'key': 'docx_text', 'ok': clean(expected) == clean(''.join(inspect_docx(docx)))}]
    return {**checked, 'available': True, 'ok': all(c['ok'] for c in checks),
            'checks': checks, 'passed': sum(c['ok'] for c in checks), 'total': len(checks)}


def tailor(prepared, data, facts=(), job=None):
    plan, changes, notes = _plan(prepared, data)
    records = _apply(prepared, plan, set())
    return {'summary': 'Review selected content and every supported change.', 'format': 'records',
            'source_digest': prepared['digest'], 'plan': plan, 'changes': changes, 'notes': notes,
            'rejected': [], 'dropped': [], 'evidence': [], 'final': False,
            'records': records, 'template': prepared['template'], **documents(records, prepared['template'])}


def finalize(prepared, tailored, job=None, facts=()):
    if prepared['digest'] != tailored.get('source_digest'):
        raise ValueError('Your reviewed resume changed after tailoring. Start tailoring again.')
    rejected = set(tailored.get('rejected', []))
    # Revalidate the saved proposal against the source before applying it.
    plan = tailored['plan']
    data = {'rewrites': [{'id': k, 'text': v} for k, v in plan['rewrites'].items()],
            'omit': [{'id': k} for k in plan['omit']],
            'ranking': [rid for order in plan['orders'].values() for rid in order]}
    checked, _, _ = _plan(prepared, data)
    if checked != plan:
        raise ValueError('The saved change plan is invalid. Start tailoring again.')
    records = _apply(prepared, plan, rejected)
    return {'summary': 'Generated the approved PDF and editable DOCX.',
            'tailor': {'final': True, 'format': 'records', 'records': records, 'template': prepared['template'],
                       'source_digest': prepared['digest'], 'applied_plan': plan,
                       'change_record': {'source_digest': prepared['digest'], 'rejected': sorted(rejected),
                                         'upload_digest': prepared['upload_digest'], 'review_revision': prepared['revision'],
                                         'reviewed_records': prepared['records'],
                                         'changes': tailored['changes'], 'notes': tailored.get('notes', [])},
                       **documents(records, prepared['template'])}}


if __name__ == '__main__':
    # Isolated child: no site hooks, project imports or optional dependencies.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from pdf_safety import _worker_limits
    try:
        _worker_limits()
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        result = {'lines': _docx_lines(raw)}
    except Exception as exc:
        result = {'error': str(exc) if isinstance(exc, ValueError) else 'DOCX processing failed.'}
    sys.stdout.write(json.dumps(result))
