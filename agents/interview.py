"""Bounded interview state and source validation; no model or transport authority."""
import copy
import re
from typing import Any

STEPS = {'interview_turn', 'interview_coach'}
# Structured like the prep coach step (#112, agents/coaching.jac): the reply is JSON with
# scores, strengths and weaknesses; a reply that is not JSON is still kept as prose.
_FIELDS = ('verdict: one short sentence on how it went. scores: one entry per criterion that applies '
    '(relevance to the role, specificity, ownership, structure, results and reflection), each 0-4 with why in one or two sentences. '
    'strengths: up to three short points on what worked. weaknesses: up to three short points on what was weak or missing. '
    'work_on: the single most useful suggested improvement, in one sentence. follow_ups: up to two short follow-up questions. '
    'example: a short illustrative answer of at most 120 words only when it clearly helps, otherwise the empty string. ')
_GROUNDING = ('Use only the saved job in context.job, the confirmed resume facts in context.facts and the answers given. '
    'Never present invented experience, employers, metrics or results as the candidate\'s own. Keep the whole reply under 250 words.')
INSTRUCTIONS = {
    'interview_turn': 'Coach the latest reviewed answer to this job-specific mock interview question for the saved role, '
        'using a 0-4 rubric. ' + _FIELDS + _GROUNDING,
    'interview_coach': 'Give an overall assessment of this job-specific mock interview for the saved role, using a 0-4 rubric. '
        'Assess only the answers in context.interview.turns. The session may have ended early: when context.interview.unanswered '
        'is above zero, say the assessment covers only the answered questions, and never score, invent or penalize answers that were not given. '
        + _FIELDS + _GROUNDING}
LIMIT = 6
BEHAVIOR = ('collaborat', 'team', 'communicat', 'stakeholder', 'partner', 'cross-functional', 'mentor', 'feedback', 'customer')
SKILL = ('require', 'experience', 'build', 'design', 'develop', 'implement', 'maintain', 'sql', 'python', 'test')

def _sentences(description):
    return [x.strip() for x in re.split(r'[\n.!?]+', description) if len(x.strip()) > 8]

def _pick(sentences, words, skip=()):
    return next((x for x in sentences if x not in skip and any(w in x.lower() for w in words)), '')

def _group(key):
    """Which question a resume fact supports: project, experience, or neither (profile, education, skills)."""
    lower = key.lower()
    if '.projects.' in lower or lower.endswith('project') or '.project.' in lower:
        return 'project'
    if any(w in lower for w in ('workexperience', '.work', 'experience', '.job', 'employment', 'intern')):
        return 'experience'
    if any(w in lower for w in ('.profile.', '.educations.', 'education', 'skills.', 'additional.', '.contact')):
        return ''
    return 'other'

def _headline(fact):
    """A short label for a resume fact: "Job title at Company", the project name, or its first line."""
    fields = dict(line.split(': ', 1) for line in str(fact['value']).split('\n') if ': ' in line)
    if fields.get('Job title') and fields.get('Company'):
        return fields['Job title'] + ' at ' + fields['Company']
    for name in ('Project', 'Company', 'Job title'):
        if fields.get(name):
            return fields[name]
    line = str(fact['value']).split('\n')[0]
    return line if len(line) <= 160 else line[:159].rstrip() + '…'

def record_facts(records, resume_id):
    """Confirmed resume records as resume facts, for a resume confirmed as reviewed text instead of details.

    Each entry under an Experience or Projects heading becomes one fact: its header line and its bullets."""
    facts, section, entry = [], '', None
    for record in records or []:
        kind, text = record.get('kind'), str(record.get('text', '')).strip()
        if kind == 'heading':
            lower = text.lower()
            section = 'projects' if 'project' in lower else 'workExperiences' if any(
                w in lower for w in ('experience', 'employment', 'work')) else ''
            entry = None
        elif section and kind == 'paragraph':
            entry = {'key': 'resume.%s.%s.%s' % (resume_id, section, record['id']), 'value': text[:1500],
                     'verified': True, 'resume_id': resume_id, 'source': 'Confirmed resume records'}
            facts.append(entry)
        elif section and kind == 'bullet':
            if entry is None:
                entry = {'key': 'resume.%s.%s.%s' % (resume_id, section, record['id']), 'value': '',
                         'verified': True, 'resume_id': resume_id, 'source': 'Confirmed resume records'}
                facts.append(entry)
            entry['value'] = (entry['value'] + '\n' + text).strip()[:1500]
    return facts[:12]

def create(job, facts, application_id, resume_id, records=None) -> dict[str, Any]:
    """Experience, project and behavioral questions from the saved job and the confirmed resume.

    Resume facts come from confirmed details; a resume confirmed only as reviewed records
    supplies `records` instead. Without either, questions use the listing alone."""
    description = str(job.get('description', '')).strip()
    if not description or len(description) > 12000:
        raise ValueError('Choose a saved role with a job description of up to 12,000 characters.')
    confirmed = [copy.deepcopy(f) for f in facts if f.get('verified') and str(f.get('key', '')).startswith('resume.')
                 and (not resume_id or not f.get('resume_id') or f['resume_id'] == resume_id)]
    if not confirmed and records:
        confirmed = record_facts(records, resume_id)
    # Compact exact listing excerpts keep selection inspectable and within local context.
    sentences = _sentences(description)
    # Teamwork sentences go to the behavioral question; skill sentences to the others.
    skills = [x for x in sentences if not any(w in x.lower() for w in BEHAVIOR)]
    requirement = (_pick(skills, SKILL) or _pick(sentences, SKILL) or _pick(sentences, BEHAVIOR) or description)[:500]
    second = (_pick(skills, SKILL, (requirement,)) or requirement)[:500]
    team = _pick(sentences, BEHAVIOR, (requirement, second))[:500]
    listing = lambda quote: {'source': 'listing', 'quote': quote, 'claim': 'Saved role requirement'}
    cite = lambda fact: {'source': 'fact:' + fact['key'], 'quote': str(fact['value'])[:500], 'claim': 'Confirmed resume fact'}
    groups = {name: [f for f in confirmed if _group(f['key']) == name] for name in ('experience', 'project', 'other')}
    work = (groups['experience'] or groups['other'][:1] or [None])[0]
    project = (groups['project'] or [f for f in groups['other'] if f is not work] or [None])[0]
    if work is not None and _group(work['key']) == 'experience':
        experience = {'question': f'Your resume lists "{_headline(work)}". This role asks for "{requirement}". '
                      'Tell me about something you personally did there that shows this: the situation, your actions and the result.',
                      'evidence': [listing(requirement), cite(work)], 'kind': 'experience'}
    elif work is not None:
        quote = str(work['value'])[:500]
        experience = {'question': f'Your confirmed resume says "{quote}". What did you personally do, how did you verify the result, and how would it help in this role?',
                      'evidence': [listing(requirement), cite(work)], 'kind': 'experience'}
    else:
        experience = {'question': f'This role asks for "{requirement}". Describe a real example, your contribution, and a tradeoff, or explain what you still need to learn.',
                      'evidence': [listing(requirement)], 'kind': 'experience'}
    if project is not None:
        project_question = {'question': f'Walk me through your project "{_headline(project)}". What did you build, what decision or tradeoff did you make, '
                            f'and how does it prepare you for this role\'s need to "{second}"?',
                            'evidence': [cite(project), listing(second)], 'kind': 'project'}
    else:
        project_question = {'question': f'This role asks for "{second}". Tell me about a project, from class, work or your own time, where you did this. '
                            'What did you build, and what tradeoff did you make?', 'evidence': [listing(second)], 'kind': 'project'}
    title = str(job.get('title', '')).strip() or 'saved'
    if team:
        behavioral = {'question': f'This role involves "{team}". Tell me about a time you disagreed with a teammate or had to recover from a setback. '
                      'What happened, what did you do, and what did you learn?', 'evidence': [listing(team)], 'kind': 'behavioral'}
    else:
        behavioral = {'question': f'Tell me about a time you had to learn something quickly or recover from a setback while working toward a goal like those in the {title} role. '
                      'What happened, what did you do, and what did you learn?', 'evidence': [], 'kind': 'behavioral'}
    return {'mode': 'interview', 'problem_id': 'role-specific', 'application_id': application_id,
            'resume_id': resume_id, 'job': copy.deepcopy(job), 'facts': confirmed,
            'questions': [experience, project_question, behavioral],
            'turns': [], 'status': 'active', 'pending': '', 'analysis': {}, 'coaching': {}, 'finished_at': 0}

def answer_text(text) -> str:
    if not isinstance(text, str) or not text.strip() or len(text) > 4000:
        raise ValueError('Review an answer of 1 to 4,000 characters before saving.')
    return text.strip()

def sources(data) -> dict[str, str]:
    return {'answer:' + str(i + 1): t['answer'] for i, t in enumerate(data['turns'])}

def target(data) -> int:
    """The answer per-answer coaching should cover: the latest one still without coaching, else the latest."""
    missing = [i for i in range(len(data['turns'])) if str(i + 1) not in data.get('analysis', {})]
    return missing[-1] if missing else len(data['turns']) - 1

def context(data, revision, final=False, index=None) -> dict[str, Any]:
    """Model context for one answer (the latest, or `index` after a retry) or, when final, every given answer."""
    index = len(data['turns']) - 1 if index is None else index
    turns = data['turns'] if final else data['turns'][index:index + 1]
    return {'job': data['job'], 'resume_id': data['resume_id'], 'fact_overrides': data['facts'],
            'facts': data['facts'], 'session_revision': revision,
            'interview': {'turns': turns, 'answer_sources': sources(data) if final else {
                'answer:' + str(index + 1): data['turns'][index]['answer']},
                'latest_source': 'answer:' + str(len(data['turns'])), 'turn': len(data['turns']) if final else index + 1,
                'unanswered': max(0, len(data['questions']) - len(data['turns'])) if final else 0}}

def _listing_quote(data) -> str:
    return next((e['quote'] for q in data['questions'] for e in q.get('evidence', []) if e.get('source') == 'listing'), '')

def followup(analysis, data) -> str:
    return ('Expand on your last reviewed answer: "' + data['turns'][-1]['answer'] + '". '
            'What did you personally do, how did you verify it, and what would you change? '
            'Relate it to this saved role requirement: "' + _listing_quote(data) + '".')

def correct(data, index, text) -> dict[str, Any]:
    """Replace one reviewed answer (a retry). Earlier versions are kept; only that answer's
    coaching and the overall assessment become stale, since every other answer was coached alone."""
    out = copy.deepcopy(data)
    turn = out['turns'][index]
    text = answer_text(text)
    if text != turn['answer']:
        turn['previous'] = (turn.get('previous', []) + [turn['answer']])[-5:]
    turn['answer'] = text
    # Answered questions are history. Every unanswered generated question may depend
    # on a corrected ancestor; keep only saved-role questions beyond that history.
    count = len(out['turns'])
    out['questions'] = out['questions'][:count] + [q for q in out['questions'][count:] if q['kind'] != 'followup']
    out['analysis'] = {k: v for k, v in out.get('analysis', {}).items() if k != str(index + 1)}
    out.update(coaching={}, pending='')
    return out

def apply(data, revision, step, artifact, task_context) -> dict[str, Any]:
    if revision != task_context['session_revision']:
        raise ValueError('The transcript changed while analysis was running. Saved answers are safe; request analysis again.')
    out = copy.deepcopy(data)
    if step == 'interview_turn':
        out['analysis'][str(task_context.get('interview', {}).get('turn') or len(out['turns']))] = artifact
    else:
        if not out['turns']:
            raise ValueError('An interview without answers has nothing to assess.')
        out['coaching'] = artifact
    out['pending'] = ''
    return out

def client_data(data) -> dict[str, Any]:
    """Plain text aliases for older clients, without inspecting model content.

    Structured coaching keeps its own fields; the aliases only fill what older clients read."""
    out = copy.deepcopy(data)
    for item in out.get('analysis', {}).values():
        if item.get('format') == 'structured':
            item.update(strength=(item.get('strengths') or [item.get('verdict', '')])[0],
                        improvement=item.get('work_on') or item['text'], focus_quote='')
        elif 'text' in item:
            item.update(strength='Coaching', improvement=item['text'], focus_quote='')
    item = out.get('coaching', {})
    if item.get('format') == 'structured':
        for key, value in (('rubric', {}), ('next_exercises', [item['work_on']] if item.get('work_on') else []),
                           ('followup_questions', item.get('follow_ups', [])), ('evidence', []), ('strengths', [])):
            item.setdefault(key, value)
    elif 'text' in item:
        item.update(summary=item['text'], strengths=[], rubric={}, next_exercises=[],
                    followup_questions=[], evidence=[])
    return out
