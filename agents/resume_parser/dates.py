"""Literal English resume date tokens; no inferred or normalized dates."""
import re

MONTH = (r'(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|'
         r'Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|'
         r'Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?')
TOKEN = rf'\b(?:(?:{MONTH})\s+)?(?:19|20)\d{{2}}\b|\b(?:Present|Current)\b'
DATE = re.compile(TOKEN, re.I)
DATE_RANGE = re.compile(rf'(?:{TOKEN})\s*(?:[-–—]|\bto\b)\s*(?:{TOKEN})', re.I)
