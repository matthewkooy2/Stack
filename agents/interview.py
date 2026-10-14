"""Bounded interview state and source validation; no model or transport authority."""
import copy
import re
from typing import Any

STEPS = {'interview_turn', 'interview_coach'}
INSTRUCTIONS = {
    'interview_turn': 'Give useful coaching on the latest reviewed answer for the saved role. '
        'Describe strengths, improvements, and a useful follow-up to practice. Respond in plain text.',
    'interview_coach': 'Give useful coaching on this reviewed interview for the saved role. '
        'Describe strengths, improvements, and next practice. Respond in plain text.'}

def create(job, facts, application_id, resume_id) -> dict[str, Any]:
    description = str(job.get('description', '')).strip()
    if not description or len(description) > 12000:
        raise ValueError('Choose a saved role with a job description of up to 12,000 characters.')
    confirmed = [copy.deepcopy(f) for f in facts if f.get('verified') and str(f.get('key', '')).startswith('resume.')
                 and (not resume_id or not f.get('resume_id') or f['resume_id'] == resume_id)]
    # A compact exact listing excerpt keeps selection inspectable and within local context.
    sentences = [x.strip() for x in re.split(r'[\n.!?]+', description) if len(x.strip()) > 8]
    requirement = next((x for x in sentences if any(w in x.lower() for w in
        ('require', 'experience', 'build', 'design', 'sql', 'python', 'collaborat'))), description)[:500]
    question = {'question': f'This role asks for "{requirement}". Describe a real example, your contribution, and a tradeoff, or explain what you still need to learn.',
                'evidence': [{'source': 'listing', 'quote': requirement, 'claim': 'Saved role requirement'}], 'kind': 'role'}
    if confirmed:
        fact = confirmed[0]
        quote = str(fact['value'])[:500]
        second = {'question': f'Your confirmed resume says "{quote}". What did you personally do, how did you verify the result, and how would it help in this role?',
                  'evidence': [{'source': 'fact:' + fact['key'], 'quote': quote, 'claim': 'Confirmed resume fact'}], 'kind': 'experience'}
    else:
        second = {'question': 'Tell me about a real collaboration or learning example relevant to this role. Be explicit about what you did and what remains unproven.',
                  'evidence': question['evidence'], 'kind': 'experience'}
    return {'mode': 'interview', 'problem_id': 'role-specific', 'application_id': application_id,
            'resume_id': resume_id, 'job': copy.deepcopy(job), 'facts': confirmed, 'questions': [question, second],
            'turns': [], 'status': 'active', 'pending': '', 'analysis': {}, 'coaching': {}, 'finished_at': 0}

def answer_text(text) -> str:
    if not isinstance(text, str) or not text.strip() or len(text) > 4000:
        raise ValueError('Review an answer of 1 to 4,000 characters before saving.')
    return text.strip()

def sources(data) -> dict[str, str]:
    return {'answer:' + str(i + 1): t['answer'] for i, t in enumerate(data['turns'])}

def context(data, revision, final=False) -> dict[str, Any]:
    turns = data['turns'] if final else data['turns'][-1:]
    return {'job': data['job'], 'resume_id': data['resume_id'], 'fact_overrides': data['facts'],
            'facts': data['facts'], 'session_revision': revision,
            'interview': {'turns': turns, 'answer_sources': sources(data) if final else {
                'answer:' + str(len(data['turns'])): data['turns'][-1]['answer']},
                'latest_source': 'answer:' + str(len(data['turns']))}}

def followup(analysis, data) -> str:
    return ('Expand on your last reviewed answer: "' + data['turns'][-1]['answer'] + '". '
            'What did you personally do, how did you verify it, and what would you change? '
            'Relate it to this saved role requirement: "' + data['questions'][0]['evidence'][0]['quote'] + '".')

def correct(data, index, text) -> dict[str, Any]:
    out = copy.deepcopy(data)
    out['turns'][index]['answer'] = answer_text(text)
    # Answered questions are history. Every unanswered generated question may depend
    # on a corrected ancestor; keep only saved-role questions beyond that history.
    count = len(out['turns'])
    out['questions'] = out['questions'][:count] + [q for q in out['questions'][count:] if q['kind'] != 'followup']
    out.update(analysis={}, coaching={}, pending='')
    return out

def apply(data, revision, step, artifact, task_context) -> dict[str, Any]:
    if revision != task_context['session_revision']:
        raise ValueError('The transcript changed while analysis was running. Saved answers are safe; request analysis again.')
    out = copy.deepcopy(data)
    if step == 'interview_turn':
        out['analysis'][str(len(out['turns']))] = artifact
    else:
        out['coaching'] = artifact
    out['pending'] = ''
    return out

def client_data(data) -> dict[str, Any]:
    """Plain text aliases for older clients, without inspecting model content."""
    out = copy.deepcopy(data)
    for item in out.get('analysis', {}).values():
        if 'text' in item:
            item.update(strength='Coaching', improvement=item['text'], focus_quote='')
    item = out.get('coaching', {})
    if 'text' in item:
        item.update(summary=item['text'], strengths=[], rubric={}, next_exercises=[],
                    followup_questions=[], evidence=[])
    return out
