"""Builds agents/data/skills.json from O*NET Technology Skills (CC BY 4.0, see discovery/NOTICE.md).

  python3 scripts/build-skills.py                      # downloads O*NET 30.1
  python3 scripts/build-skills.py "Technology Skills.txt"

O*NET names are formal ("Structured query language SQL", "Oracle Java", "Amazon Web Services AWS
software"). Each becomes the terms people write: SQL, Java, AWS. Generic categories ("Spreadsheet
software") are skipped. Short names and names that are ordinary English words ("Word", "Access", "R")
only match when written with the same capitalization.
"""
import csv
import io
import json
import re
import sys
import urllib.request
from pathlib import Path

URL = 'https://www.onetcenter.org/dl_files/database/db_30_1_text/Technology%20Skills.txt'
OUT = Path(__file__).resolve().parents[1] / 'agents' / 'data' / 'skills.json'
VENDORS = ('Microsoft', 'Oracle', 'Adobe', 'IBM', 'Google', 'Amazon', 'Apple', 'SAP', 'The MathWorks', 'Autodesk', 'Atlassian',
           'Apache', 'Salesforce', 'Intuit', 'Cisco', 'VMware', 'Red Hat', 'Epic Systems', 'Esri', 'ESRI', 'SAS Institute', 'Tableau Software')
# Everyday words that are also product names; alone they only match when capitalized as a name.
ENGLISH = {'word', 'access', 'project', 'teams', 'notes', 'office', 'publisher', 'dynamics', 'windows', 'outlook', 'visio', 'excel', 'chef',
           'puppet', 'go', 'swift', 'rust', 'spark', 'hive', 'pig', 'flask', 'react', 'express', 'slack', 'box', 'zoom', 'sketch', 'figma',
           'jira', 'confluence', 'git', 'r', 'c', 'd', 'j', 'shell', 'bash', 'unity', 'maya', 'blender', 'keynote', 'pages', 'numbers',
           'ruby', 'perl', 'julia', 'scala', 'dart', 'elixir', 'erlang', 'haskell', 'lisp', 'prolog', 'basic', 'logo', 'alteryx', 'looker'}


# A vendor is dropped ("Oracle Java" -> Java) unless what remains is one ordinary word ("Google Cloud" stays).
DICTIONARY = {w.strip().lower() for w in open('/usr/share/dict/words')} if Path('/usr/share/dict/words').exists() else set()
def ordinary(word):
    """An English word, allowing -ing, -s and -ed forms the word list omits ("imaging", "editing")."""
    w = word.lower().strip('!')
    return any(c in DICTIONARY for c in (w, w[:-1], w[:-2], w[:-3], w[:-3] + 'e', w[:-2] + 'e') if len(c) > 2) if len(w) > 3 else w in DICTIONARY


KEEP_SHORT = {'Excel', 'Java', 'Word', 'Outlook', 'Access', 'Teams', 'Project', 'Visio', 'Publisher', 'Dynamics'}
# "X software" names a product, not a kind of software, for these ordinary words.
PRODUCT_SOFTWARE = {'Blackboard', 'Oracle', 'SAP', 'Workday', 'Perforce'}
# Products named by an ordinary word still match in any case when they are core tech names.
ANY_CASE = {'Python', 'Docker', 'Tableau', 'Snowflake', 'Prometheus', 'Selenium', 'Postman', 'Bootstrap', 'Drupal', 'Moodle', 'Asana', 'Scala', 'Solidity'}
# Single words that name a kind of software rather than a product ("Spreadsheet software").
GENERIC = {'spreadsheet', 'database', 'email', 'presentation', 'accounting', 'graphics', 'calendar', 'video', 'photo', 'mapping',
           'scheduling', 'inventory', 'billing', 'payroll', 'drawing', 'desktop', 'mobile', 'web', 'office', 'internet', 'point',
           'music', 'audio', 'medical', 'dental', 'legal', 'library', 'project', 'backup', 'antivirus', 'compiler', 'debugger'}


def _abbreviates(acronym, words):
    """Whether the words' initials spell the acronym, in order: "JavaScript Object Notation" -> JSON."""
    initials = ''.join(w[0].lower() for w in words if w[0].isalpha())
    letters = re.sub(r'[^a-z]', '', acronym.lower())
    if not initials or initials[0] != letters[0]:
        return False
    it = iter(letters)
    return all(c in it for c in initials) and len(initials) >= min(2, len(letters))


def aliases(example):
    name = re.sub(r'\s+', ' ', example).strip()
    base = re.sub(r'\s*\bsoftware$', '', name).split()
    # "Word processing software" or "Spreadsheet software": a category, not a product.
    if name.endswith('software') and (not base or (len(base) > 1 and not re.search(r'[A-Z]', ' '.join(base)[1:]))
                                      or (len(base) == 1 and (base[0].lower() in GENERIC or (ordinary(base[0]) and base[0] not in PRODUCT_SOFTWARE)))):
        return None, []
    name = re.sub(r'\s+software$', '', name)
    found = {name}
    words = name.split()
    # "Structured query language SQL" -> SQL; "Amazon Web Services AWS" -> AWS and "Amazon Web Services".
    display = name
    if len(words) >= 3 and re.fullmatch(r'[A-Z][A-Z0-9+#./-]{1,9}', words[-1]):
        # Only the words the acronym stands for: "Amazon Web Services AWS" -> AWS, "Amazon Web Services".
        spelled = next((words[i:-1] for i in range(len(words) - 1) if _abbreviates(words[-1], words[i:-1])), None)
        if spelled:
            found |= {words[-1], ' '.join(spelled)}
            display = words[-1]
    for vendor in VENDORS:
        if display == name and name.startswith(vendor + ' ') and len(name) > len(vendor) + 3:
            rest = name[len(vendor) + 1:]
            if ' ' in rest or not ordinary(rest) or rest in KEEP_SHORT:
                found.add(rest)
                display = rest
    return display, sorted(found)


def build(text):
    skills = {}
    for row in csv.DictReader(io.StringIO(text), delimiter='\t'):
        display, found = aliases(row['Example'])
        if not display:
            continue
        entry = skills.setdefault(display, {'name': display, 'aliases': set(), 'hot': False})
        entry['aliases'] |= set(found)
        entry['hot'] = entry['hot'] or row['Hot Technology'] == 'Y'
    out = []
    for entry in sorted(skills.values(), key=lambda e: e['name'].lower()):
        names = sorted(entry['aliases'] | {entry['name']})
        # Short names and ordinary words ("Act!", "Square", "Word") only match when capitalized as a name.
        exact = sorted(a for a in names if len(a) <= 2 or a.lower() in ENGLISH
                       or (' ' not in a and ordinary(a) and a not in ANY_CASE))
        out.append({'name': entry['name'], 'aliases': names, 'exact_case': exact, 'hot': entry['hot']})
    return out


if __name__ == '__main__':
    raw = Path(sys.argv[1]).read_text(encoding='utf-8') if len(sys.argv) > 1 else urllib.request.urlopen(URL, timeout=60).read().decode('utf-8')
    skills = build(raw)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({'source': 'O*NET 30.1 Technology Skills, CC BY 4.0 (see discovery/NOTICE.md)', 'skills': skills},
                              separators=(',', ':'), ensure_ascii=False) + '\n')
    print('Wrote', len(skills), 'skills to', OUT)
