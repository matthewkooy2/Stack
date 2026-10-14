"""Stack's independent, deterministic resume record parser.

`dates`, `records` and `structure` are restored unchanged from Stack's own
standalone parser (unmerged PR 23, commit c604389ee3a0b22fc2ebcaf668c37fc3e834c489,
`integrations/independent-resume-parser/resume_parser`). They consume page spans
`{id, text, bbox: [x, baselineY, width, height]}` with a top-left origin. The PR's
Node/PDF.js extractor and process supervisor are not part of this package; spans
come from the bounded `agents.pdf_safety` lane (see `docs/RESUME_PARSER.md`).
"""
from .structure import structure

PARSER_NAME = 'stack-independent-resume-parser'
PARSER_VERSION = '0.2.0'

__all__ = ['structure', 'PARSER_NAME', 'PARSER_VERSION']
