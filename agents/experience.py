"""What each agent does, what it needs, and what the user must review. No state or IO."""
import time
from typing import Any
from urllib.parse import urlsplit
from agents.contracts import EXTERNAL, answers

# Steps whose exact payload the user approves before the worker may dispatch it.
REVIEWED = {'fill', 'submit', 'send', 'calendar'}
ATTENTION = {'needs_input', 'blocked', 'uncertain', 'review'}
ACTIVE = {'queued', 'running', 'waiting'}

KIND_TITLES = {
    'application': 'Prepare & apply', 'jobs': 'Job-fit analysis', 'resume': 'Resume tailoring',
    'linkedin': 'LinkedIn profile review',
    'network': 'Networking outreach', 'profile': 'Profile suggestions', 'prep': 'Interview coaching',
    'code': 'Code practice run', 'live': 'Live interview', 'sync': 'Email tracking', 'calendar': 'Calendar assistant',
}
STEP_LABELS = {
    'linkedin_scan': 'Sign in and read your profile', 'linkedin_review': 'Analyze recruiter appeal',
    'inspect': 'Read the application form', 'fit': 'Analyze job fit', 'tailor': 'Tailor your resume',
    'fill': 'Fill the application', 'submit': 'Submit the application', 'research': 'Read the contact source',
    'draft': 'Draft the message', 'send': 'Send the email', 'profile': 'Draft profile suggestions',
    'coach': 'Coach your answer', 'sync': 'Check Gmail for updates', 'execute': 'Run your code',
    'calendar': 'Add the interview to Calendar', 'interview': 'Live practice interview',
}
RESULTS = {
    'application': 'Applications → this job → Agent help. Submission receipts update the application status.',
    'jobs': 'Applications → this job → Agent help, and this task.',
    'resume': 'This task: tailored PDF, what changed, and suggested edits. Your original PDF is never modified.',
    'linkedin': 'Network → LinkedIn profile review, and this task. Copy suggested edits into LinkedIn yourself.',
    'network': 'Network → your contacts, and this task. Sent emails appear in your Gmail Sent folder.',
    'profile': 'This task. Copy the suggestions you like into your profile yourself.',
    'prep': 'Prep → your practice session → Coaching.',
    'code': 'Prep → your practice session → Test results.',
    'live': 'Web workspace → Practice → your session transcript.',
    'sync': 'Applications (status history) and Agents → Needs you (messages to confirm).',
    'calendar': 'Your Google Calendar, in “Stack interviews and preparation”, after you approve.',
}
STATUS_TEXT = {
    'queued': 'Waiting for the agent worker. It starts automatically.',
    'running': 'Working now.',
    'waiting': 'Ready to start.',
    'needs_input': 'Stack needs information from you to continue.',
    'blocked': 'Paused by setup or limits. Fix the item below, then retry.',
    'review': 'Nothing has been shared yet. Review exactly what will happen, then approve or cancel.',
    'uncertain': 'An outbound action may already have happened. Confirm what happened before anything else runs.',
    'failed': 'This task stopped after repeated errors. Retry it or dismiss it.',
    'completed': 'Finished. Results are below.',
    'cancelled': 'Cancelled. Nothing further will run.',
}
NEXT_ACTION = {'needs_input': 'answer', 'blocked': 'retry', 'review': 'review', 'uncertain': 'reconcile', 'failed': 'retry', 'completed': 'results'}


def review_payload(step: str, context: dict[str, Any], artifacts: dict[str, Any]) -> Any:
    """The value the worker hashes as payload_hash for this step (see agents.worker.dispatch)."""
    if step in ('fill', 'submit'):
        return [context, artifacts]
    if step == 'send':
        return artifacts.get('draft', {})
    if step == 'calendar':
        return context.get('event', {})
    raise ValueError('This step does not need review.')


def _host(url: str) -> str:
    return (urlsplit(url).hostname or '') if url else ''


def review_summary(step: str, context: dict[str, Any], artifacts: dict[str, Any]) -> dict[str, Any]:
    job = context.get('job', {})
    employer = job.get('company', 'the employer')
    if step == 'fill':
        verified = answers(context.get('facts', []))
        fields = artifacts.get('inspect', {}).get('fields', [])
        rows, documents, notes = [], [], []
        tailored = artifacts.get('tailor', {})
        for f in fields:
            label = str(f.get('label', '') or f.get('name', 'Field'))
            if f.get('type') == 'file':
                kind = 'cover_letter' if 'cover' in label.lower() else ('pdf' if any(x in label.lower() for x in ('resume', 'cv')) else '')
                pdf = tailored.get(kind, {}) if kind else {}
                if pdf:
                    documents.append({'label': label, 'name': pdf.get('name', 'Document.pdf'), 'pages': pdf.get('pages', 0)})
                elif f.get('required'):
                    notes.append('No document is attached for “' + label + '”. Complete it in the browser handoff.')
            elif f.get('type') not in ('checkbox', 'radio') and f.get('key') in verified:
                rows.append({'label': label, 'value': verified[f['key']]})
        return {'step': step, 'title': 'Share answers and documents with ' + employer,
                'destination': _host(job.get('url', '')), 'answers': rows, 'documents': documents,
                'diff': str(tailored.get('pdf', {}).get('diff', ''))[:6000], 'notes': notes,
                'consequence': 'Stack fills and checks the form. It does not submit. You approve submission separately.'}
    if step == 'submit':
        return {'step': step, 'title': 'Submit your application to ' + employer, 'destination': _host(job.get('url', '')),
                'answers': [], 'documents': [], 'notes': ['The completed form was verified in the browser session.'],
                'consequence': 'Stack clicks Submit once and saves the confirmation. This cannot be undone.'}
    if step == 'send':
        draft = artifacts.get('draft', {})
        contact = context.get('contact', {})
        return {'step': step, 'title': ('Send follow-up to ' if context.get('followup') else 'Send email to ') + str(contact.get('name', 'your contact')),
                'to': contact.get('email', ''), 'subject': draft.get('subject', ''), 'body': draft.get('body', ''),
                'followup': bool(context.get('followup')), 'notes': [],
                'consequence': 'Stack sends this exact email from your Gmail. You can edit the subject and body first.'}
    if step == 'calendar':
        event = context.get('event', {})
        return {'step': step, 'title': 'Add “' + str(event.get('summary', 'Interview')) + '” to Google Calendar',
                'event': {'summary': event.get('summary', ''), 'start': event.get('start', {}).get('dateTime', ''),
                          'end': event.get('end', {}).get('dateTime', ''), 'location': event.get('location', ''),
                          'status': event.get('status', '')},
                'notes': [], 'consequence': 'Stack adds or updates this event in its own “Stack interviews and preparation” calendar.'}
    raise ValueError('This step does not need review.')


def context_label(kind: str, context: dict[str, Any]) -> str:
    job = context.get('job', {})
    if job.get('title'):
        return str(job['title']) + ' · ' + str(job.get('company', ''))
    if context.get('contact'):
        c = context['contact']
        return str(c.get('name', 'Contact')) + (' · ' + str(c['company']) if c.get('company') else '')
    if context.get('problem'):
        return str(context['problem'].get('title', 'Practice session'))
    if context.get('event'):
        return str(context['event'].get('summary', 'Interview'))
    if kind == 'linkedin':
        return context.get('linkedin_url', '') + (' · ' + context['target_role'] if context.get('target_role') else '')
    if kind == 'profile':
        return 'Your professional profile'
    if kind == 'sync':
        return 'Gmail'
    return ''


def present(kind: str, status: str, index: int, steps: list[str], context: dict[str, Any], next_at: float = 0.0, now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    position = min(index, len(steps) - 1)
    title = KIND_TITLES.get(kind, kind.title())
    if kind == 'network' and context.get('followup'):
        title = 'Follow-up email'
    explanation = STATUS_TEXT.get(status, '')
    if status == 'queued' and next_at > now:
        explanation = 'Retrying automatically in about ' + str(max(1, int((next_at - now + 59) // 60))) + ' min.'
    return {'title': title, 'context_label': context_label(kind, context), 'step_label': STEP_LABELS.get(steps[position], steps[position]),
            'step_number': position + 1, 'step_total': len(steps), 'steps': [STEP_LABELS.get(s, s) for s in steps],
            'explanation': explanation, 'next_action': NEXT_ACTION.get(status, ''), 'results_where': RESULTS.get(kind, ''),
            'attention': status in ATTENTION, 'active': status in ACTIVE}


FEATURES = [
    {'key': 'linkedin', 'kinds': ['linkedin'], 'title': 'LinkedIn profile review', 'where': 'Network or web workspace → Network',
     'summary': 'Reads your profile after you sign in, identifies recruiter-facing weaknesses, and suggests evidence-backed rewrites.',
     'input': 'Your LinkedIn profile URL, optional target role, and sign-in inside the agent browser on your task.',
     'review': 'You confirm the profile before capture. Profile text goes to your configured model; login details stay in the browser session. You apply edits yourself.',
     'alternative': 'Use Profile suggestions on Resume to draft a headline and About from your confirmed facts.'},
    {'key': 'applications', 'kinds': ['application'], 'title': 'Application assistant', 'where': 'Applications',
     'summary': 'Reads a supported application form, explains fit, tailors your resume, fills the form, and submits once.',
     'input': 'A saved real job on Greenhouse, Lever, or Ashby, your resume, and confirmed answers.',
     'review': 'You approve the exact answers and documents before they are shared, then approve submission separately.',
     'alternative': 'Open the application page, apply yourself, then tap Mark as submitted.'},
    {'key': 'networking', 'kinds': ['network'], 'title': 'Networking & follow-ups', 'where': 'Network',
     'summary': 'Drafts a short email to a contact you chose, from your confirmed facts, and schedules polite follow-ups that stop on reply.',
     'input': 'A contact you add with a verified email, and Gmail sending permission.',
     'review': 'Every email and follow-up waits for your approval. Saving a contact never sends anything.',
     'alternative': 'Drafts work without Gmail sending: open the task, copy the draft into your own email, then cancel the task.'},
    {'key': 'tailoring', 'kinds': ['resume'], 'title': 'Resume tailoring', 'where': 'Resume',
     'summary': 'Reorders your confirmed resume facts for a specific job and renders a new PDF, with suggested rewrites kept separate.',
     'input': 'An uploaded PDF, confirmed resume facts, and a saved job.',
     'review': 'The tailored PDF is only shared with an employer inside an application you approve.',
     'alternative': 'Use the sample preview and edit your resume yourself.'},
    {'key': 'fit', 'kinds': ['jobs'], 'title': 'Job-fit analysis', 'where': 'Applications',
     'summary': 'Explains strengths, gaps, and unknowns for a saved job, quoting the listing and your confirmed facts.',
     'input': 'A saved real job. Confirmed resume facts make the analysis specific.',
     'review': 'Nothing is shared outside Stack.',
     'alternative': 'Open Full details on a job card to see the deterministic requirement checks.'},
    {'key': 'profile', 'kinds': ['profile'], 'title': 'Profile suggestions', 'where': 'Resume',
     'summary': 'Suggests a headline and about section from your confirmed facts, with the evidence for each edit.',
     'input': 'At least one confirmed fact.',
     'review': 'Suggestions are drafts. Stack never edits LinkedIn or any other site.',
     'alternative': 'Write your headline yourself using your confirmed facts.'},
    {'key': 'coaching', 'kinds': ['prep'], 'title': 'Interview coaching', 'where': 'Prep',
     'summary': 'Scores a saved practice answer against a rubric and suggests what to practice next.',
     'input': 'A saved practice session with your answer, code, or transcript.',
     'review': 'Nothing is shared outside Stack.',
     'alternative': 'Use Show practice guide on the Prep questions to check your own answer.'},
    {'key': 'code', 'kinds': ['code'], 'title': 'Code practice runs', 'where': 'Prep',
     'summary': 'Runs your Python, C++, or SQL practice code against tests in an isolated sandbox.',
     'input': 'A coding practice session with code.',
     'review': 'Your code runs only in a networkless sandbox.',
     'alternative': 'Walk through the test cases by hand using the practice guide.'},
    {'key': 'live', 'kinds': ['live'], 'title': 'Live interviews', 'where': 'Prep',
     'summary': 'Holds a timed voice mock interview about your practice session and saves the transcript for coaching.',
     'input': 'The web workspace, a microphone, and a practice session.',
     'review': 'You review the transcript before requesting coaching.',
     'alternative': 'Type or dictate your answer, then use Get coaching.'},
    {'key': 'email', 'kinds': ['sync'], 'title': 'Email tracking', 'where': 'Applications',
     'summary': 'Checks Gmail every few minutes for application replies, assessments, interviews, and rejections, and updates status.',
     'input': 'Gmail read access and the Gmail tracking permission.',
     'review': 'Unclear messages wait for you to confirm the application and status.',
     'alternative': 'Update application status yourself after reading your email.'},
    {'key': 'calendar', 'kinds': ['calendar'], 'title': 'Calendar assistant', 'where': 'Applications',
     'summary': 'Adds interview invitations found in Gmail to a Stack calendar and prepares a matching study plan.',
     'input': 'Gmail tracking plus Google Calendar access.',
     'review': 'Every calendar change waits for your approval.',
     'alternative': 'Accept the invitation in your email, and use Build interview plan on the application.'},
]
ACTION_NAMES = {'model': 'Model', 'browser_fill': 'Browser fill', 'submit_application': 'Submit application',
                'send_email': 'Send email', 'calendar_write': 'Calendar write', 'gmail_read': 'Gmail read'}


def feature_status(facts: dict[str, Any]) -> list[dict[str, Any]]:
    """facts: plain account/deployment facts; returns per-feature readiness and fix actions."""
    now = facts.get('now', time.time())
    policy = facts.get('policy', {})
    model = facts.get('model', {})
    scopes = set(facts.get('google_scopes', []))
    rules_on = bool(policy.get('enabled')) and policy.get('expires_at', 0) > now

    def check(key, label, ok, fix, action='', user=True, optional=False):
        return {'key': key, 'label': label, 'ok': bool(ok), 'fix': '' if ok else fix, 'action': '' if ok else action,
                'user_fixable': user, 'optional': optional}

    def rules():
        return check('rules', 'Standing permissions on', rules_on,
                     'Turn on standing permissions in Agents → Rules. They expire after 30 days.', 'rules')

    def permission(action, optional=False, prefix=''):
        ok = action in policy.get('actions', []) and (action not in EXTERNAL.values() or policy.get('daily_limits', {}).get(action))
        return check('perm:' + action, prefix + 'Permission: ' + ACTION_NAMES[action], ok,
                     'Allow “' + ACTION_NAMES[action] + '” with a daily limit in Agents → Rules.', 'rules', optional=optional)

    def operator(action, optional=False, prefix=''):
        return check('operator:' + action, prefix + ACTION_NAMES[action] + ' enabled on this server', facts.get('operator_limits', {}).get(action, 0) > 0,
                     'The operator has not enabled “' + ACTION_NAMES[action] + '” for this deployment.', '', user=False, optional=optional)

    def provider():
        return check('model', 'Model provider connected', model.get('configured'),
                     str(model.get('message', 'The operator has not configured a model provider.')), '', user=False)

    def google(scope, label, optional=False):
        if not facts.get('google_client'):
            return check('google:' + scope, label, False, 'Google sign-in is not configured on this server.', '', user=False, optional=optional)
        return check('google:' + scope, label, scope in scopes, 'Connect Google in Agents → Rules.', 'connect:' + scope, optional=optional)

    model_checks = [provider(), rules(), permission('model')]
    table = {
        'linkedin': model_checks + [
            check('browser', 'Browser worker available', facts.get('browser'), 'The operator must configure the isolated browser worker.', '', user=False),
            check('facts', 'Confirmed facts for stronger rewrites', facts.get('verified_facts', 0) > 0, 'Confirm resume facts to support your suggestions.', 'facts', optional=True)],
        'applications': model_checks + [
            check('applications', 'A saved real job', facts.get('applications', 0) > 0, 'Swipe right on a job to save it.', 'jobs'),
            check('resume', 'An uploaded resume', facts.get('resumes', 0) > 0, 'Upload a PDF on the Resume tab.', 'resume'),
            check('facts', 'Confirmed resume facts', facts.get('resume_facts', 0) > 0, 'Extract and confirm your resume facts.', 'facts'),
            permission('browser_fill'), operator('browser_fill'), permission('submit_application', optional=True),
            check('browser', 'Browser worker available', facts.get('browser'), 'The operator has not configured the isolated browser worker.', '', user=False),
            check('certified', 'Automatic submission certified', facts.get('certified_adapters'),
                  'No application site is certified for automatic submission yet. You submit through the browser handoff or the employer site.', '', user=False, optional=True)],
        'networking': model_checks + [
            check('contacts', 'A contact you selected', facts.get('contacts_selected', 0) > 0, 'Add a contact with a verified email on the Network tab.', 'contacts'),
            # Drafting works without these; sending from Stack needs all of them.
            permission('send_email', optional=True, prefix='To send: '), operator('send_email', optional=True, prefix='To send: '),
            google('send', 'To send: Gmail sending connected', optional=True),
            check('domains', 'To send: recipient domains allowed', len(policy.get('domains', [])) > 0, 'Add each recipient’s email domain to allowed destinations in Rules.', 'rules', optional=True)],
        'tailoring': model_checks + [
            check('resume', 'An uploaded resume', facts.get('resumes', 0) > 0, 'Upload a PDF on the Resume tab.', 'resume'),
            check('facts', 'Confirmed resume facts', facts.get('resume_facts', 0) > 0, 'Extract and confirm your resume facts.', 'facts'),
            check('applications', 'A saved real job', facts.get('applications', 0) > 0, 'Swipe right on a job to save it.', 'jobs')],
        'fit': model_checks + [
            check('applications', 'A saved real job', facts.get('applications', 0) > 0, 'Swipe right on a job to save it.', 'jobs'),
            check('facts', 'Confirmed resume facts', facts.get('resume_facts', 0) > 0, 'Confirm resume facts for a more specific analysis.', 'facts', optional=True)],
        'profile': model_checks + [
            check('facts', 'Confirmed facts', facts.get('verified_facts', 0) > 0, 'Confirm at least one fact in Agents → Facts.', 'facts')],
        'coaching': list(model_checks),
        'code': [check('sandbox', 'Code sandbox available', facts.get('sandbox'), 'The operator has not configured the isolated code sandbox. Your code is still saved.', '', user=False)],
        'live': [check('voice', 'Voice service available', not facts.get('voice_error'), str(facts.get('voice_error', '')), '', user=False),
                 check('web', 'Web workspace available', facts.get('web_url'), 'The web workspace is not hosted yet.', '', user=False),
                 rules(), permission('model')],
        'email': [rules(), permission('gmail_read'), google('read', 'Gmail tracking connected')],
        'calendar': [rules(), permission('calendar_write'), operator('calendar_write'), google('read', 'Gmail tracking connected'),
                     google('calendar', 'Google Calendar connected')],
    }
    out = []
    for feature in FEATURES:
        checks = table[feature['key']]
        missing = [c for c in checks if not c['ok'] and not c['optional']]
        state = 'ready' if not missing else ('unavailable' if any(not c['user_fixable'] for c in missing) else 'setup')
        # Ready, but an optional capability (such as sending from Stack) is still off.
        limited = state == 'ready' and any(not c['ok'] and c['optional'] for c in checks)
        out.append({**feature, 'state': state, 'limited': limited, 'checks': checks,
                    'ready_count': len([c for c in checks if c['ok'] or c['optional']]), 'total': len(checks)})
    return out
