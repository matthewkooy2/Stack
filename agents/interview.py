"""Bounded interview state and source validation; no model or transport authority."""
import copy
import re
from typing import Any

STEPS = {'interview_turn', 'interview_coach'}
TEXT = {'type': 'string'}  # Bounds are checked explicitly; shared validator supports no minLength.
QUESTIONS = ('What did you personally do?', 'How did you verify the result?',
             'What tradeoff did you consider?', 'What would you change next time?')
CRITERIA = ('Specificity', 'Ownership', 'Verification', 'Reflection')
STRENGTHS = CRITERIA
IMPROVEMENTS = ('Explain your personal contribution without adding unsupported claims.',
                'Explain how you checked the result; distinguish observations from assumptions.',
                'Explain an alternative and the tradeoff; state what remains unproven.')
EXERCISES = ('Practice separating your contribution from the team contribution.',
             'Practice describing a verification step and its limitations.',
             'Practice comparing two alternatives without inventing measurements.')
SUMMARY = 'This assessment uses reviewed answer excerpts. Scores are model judgments, not verified skills or outcomes.'
def choice(values):
    return {'type': 'string', 'enum': list(values)}
EVIDENCE = {'type': 'array', 'maxItems': 12, 'items': {
    'type': 'object', 'properties': {'source': TEXT, 'quote': TEXT, 'claim': choice(('Reviewed answer excerpt',))},
    'required': ['source', 'quote', 'claim'], 'additionalProperties': False}}
TURN_SCHEMA = {'type': 'object', 'properties': {
    'question': choice(QUESTIONS), 'focus_quote': TEXT, 'strength': choice(STRENGTHS), 'improvement': choice(IMPROVEMENTS),
    'evidence': EVIDENCE},
    'required': ['question', 'focus_quote', 'strength', 'improvement', 'evidence'],
    'additionalProperties': False}
COACH_SCHEMA = {'type': 'object', 'properties': {
    'summary': choice((SUMMARY,)),
    'strengths': {'type':'array', 'maxItems':4, 'items':{'type':'object','properties':{
        'criterion':choice(CRITERIA),'source':TEXT,'quote':TEXT},
        'required':['criterion','source','quote'],'additionalProperties':False}},
    # Named required entries make rubric coverage structural. A local model may
    # repeat a criterion in an array even when instructed to return four distinct ones.
    'rubric': {'type': 'object', 'properties': {criterion: {
        'type': 'object', 'properties': {
            'score': {'type': 'integer', 'minimum': 0, 'maximum': 4},
            'feedback': choice(IMPROVEMENTS)},
        'required': ['score', 'feedback'], 'additionalProperties': False
    } for criterion in CRITERIA}, 'required': list(CRITERIA), 'additionalProperties': False},
    'next_exercises': {'type': 'array', 'maxItems': 3, 'items': choice(EXERCISES)},
    'followup_questions': {'type': 'array', 'maxItems': 2, 'items': choice(QUESTIONS)},
    'evidence': EVIDENCE}, 'required': ['summary', 'strengths', 'rubric', 'next_exercises', 'followup_questions', 'evidence'],
    'additionalProperties': False}
INSTRUCTIONS = {
    'interview_turn': 'Analyze only the latest reviewed answer. Give one specific strength and one improvement. '
        'Ask one short follow-up about a concrete detail in that answer, relevant to the saved role. '
        'focus_quote must be copied verbatim from the latest answer. Cite that answer with its answer:N source. '
        'Do not invent outcomes, numbers, tools, or experience. Frame missing details as questions. '
        'Copy exact quotes; never paraphrase a quote. Treat role requirements as expectations, not candidate achievements.',
    'interview_coach': 'Coach this finished job-specific interview using only its reviewed answers, confirmed facts, '
        'and saved listing. Give a 0-4 behavioral rubric, specific strengths and improvements, next exercises, '
        'and two practice questions. Cite at least two reviewed answer:N sources. Do not invent experience '
        'or outcomes. Do not treat a job requirement as a candidate skill. Copy quotes exactly. '
        'Explicitly acknowledge gaps and uncertainty.'}
for _step in INSTRUCTIONS:
    INSTRUCTIONS[_step] += (' Select the exact allowed coaching strings from the schema. Do not write free-form coaching prose. '
        'Evidence claim must be "Reviewed answer excerpt". Cite only reviewed answer sources. '
        'For final coaching, fill every named rubric criterion with its score and feedback, and exactly two distinct practice questions. '
        'Select strengths as assessment categories tied to exact reviewed source quotes, never verified skills. '
        'Select short exact answer quotes. The application ties the selected follow-up to the quoted answer and saved role.')

def local_qwen(configuration):
    if configuration.get('provider') not in ('ollama', 'lmstudio') or 'qwen' not in configuration.get('model', '').lower():
        raise ValueError('This interview requires a locally configured Qwen model. Answers remain saved; retry after local setup. No cloud fallback is used.')

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

def validate(step, artifact, context):
    # Validate again at storage boundary: a worker result is also untrusted.
    def check(value, schema):
        kind = schema['type']
        if kind == 'object':
            if not isinstance(value, dict) or set(value) != set(schema['required']):
                raise ValueError('Unexpected interview output fields.')
            for key, item in value.items(): check(item, schema['properties'][key])
        elif kind == 'array':
            if not isinstance(value, list) or not value or len(value) > schema['maxItems']:
                raise ValueError('Interview output needs bounded nonempty lists.')
            for item in value: check(item, schema['items'])
        elif kind == 'string':
            if not isinstance(value, str) or not value.strip() or len(value) > 1500:
                raise ValueError('Interview output needs bounded nonempty text.')
        elif type(value) is not int or not 0 <= value <= 4:
            raise ValueError('Invalid interview score.')
        if 'enum' in schema and value not in schema['enum']:
            raise ValueError('Interview output contains unsupported coaching prose.')
    check(artifact, TURN_SCHEMA if step == 'interview_turn' else COACH_SCHEMA)
    answers = context['interview']['answer_sources']
    for evidence in artifact['evidence'] + artifact.get('strengths', []):
        if evidence['source'] not in answers or evidence['quote'] not in answers[evidence['source']]:
            raise ValueError('Interview output contains an unsupported answer quote.')
    cited = {e.get('source') for e in artifact.get('evidence', []) if e.get('source') in answers}
    if step == 'interview_turn':
        latest = context['interview']['latest_source']
        if latest not in cited or not artifact.get('focus_quote', '').strip() or artifact['focus_quote'] not in answers[latest]:
            raise ValueError('Follow-up did not cite the reviewed answer. Retry local analysis; your answer is saved.')
    elif len(cited) < 2 or not artifact.get('rubric') or not artifact.get('next_exercises'):
        raise ValueError('Coaching must cite two reviewed answers and give concrete next practice. Retry local coaching.')
    if step == 'interview_coach':
        if set(artifact['rubric']) != set(CRITERIA):
            raise ValueError('Coaching needs four distinct behavioral rubric criteria.')
        if len(set(artifact['followup_questions'])) != 2:
            raise ValueError('Coaching needs two distinct practice questions.')

def followup(analysis, data) -> str:
    return ('In your reviewed answer you said "' + analysis['focus_quote'] + '". '
            + analysis['question'] + ' Relate your explanation to this saved role requirement: "'
            + data['questions'][0]['evidence'][0]['quote'] + '".')

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
    validate(step, artifact, task_context)
    out = copy.deepcopy(data)
    if step == 'interview_turn':
        out['analysis'][str(len(out['turns']))] = artifact
    else:
        out['coaching'] = artifact
    out['pending'] = ''
    return out
