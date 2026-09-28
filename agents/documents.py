"""PDF extraction and deterministic, source-preserving resume variants."""
import base64
from difflib import unified_diff
from io import BytesIO
import re


def extract(content):
    from pypdf import PdfReader
    reader = PdfReader(BytesIO(base64.b64decode(content, validate=True)))
    if reader.is_encrypted:
        raise ValueError('Use an unencrypted PDF.')
    text = '\n'.join(page.extract_text() or '' for page in reader.pages)
    if not text.strip():
        raise ValueError('This PDF has no readable text. Add verified facts or upload a text-based PDF.')
    return text[:50000]


def render_variant(name, original, ordered_facts):
    """Only verified, verbatim facts enter automatic PDFs. Rewrites require review."""
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib.enums import TA_LEFT
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
    from reportlab.lib import colors
    from xml.sax.saxutils import escape
    from pypdf import PdfReader
    out = BytesIO()
    styles = getSampleStyleSheet()
    styles['BodyText'].fontSize = 10
    styles['BodyText'].leading = 14
    doc = SimpleDocTemplate(out, pagesize=(612, 792), leftMargin=48, rightMargin=48, topMargin=42, bottomMargin=42)
    story = [Paragraph(escape(name), styles['Title']), Spacer(1, 12)]
    for fact in ordered_facts:
        story.extend([Paragraph(escape(fact['value']).replace('\n', '<br/>'), styles['BodyText']), Spacer(1, 8)])
    doc.build(story)
    raw = out.getvalue()
    reader = PdfReader(BytesIO(raw))
    recovered = '\n'.join(p.extract_text() or '' for p in reader.pages)
    normalize = lambda s: re.sub(r'\s+', '', s)
    if any(normalize(f['value']) not in normalize(recovered) for f in ordered_facts):
        raise ValueError('The rendered PDF did not preserve every fact. Review the resume before use.')
    text = '\n'.join(f['value'] for f in ordered_facts)
    return {'name': 'Tailored resume.pdf', 'content': base64.b64encode(raw).decode(),
            'text': text, 'pages': len(reader.pages), 'source_keys': [f['key'] for f in ordered_facts],
            'diff': '\n'.join(unified_diff(original.splitlines(), text.splitlines(), fromfile='Original', tofile='Tailored', lineterm='')),
            'checks': {'text_preserved': True, 'single_column': True, 'pages': len(reader.pages)}}
