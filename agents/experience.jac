"""What each agent does, what it needs, and what the user must review. No state or IO."""
import time;
import from agents.contracts { EXTERNAL }
with entry {
    REVIEWED = {'approve_resume', 'send', 'calendar'};
    ATTENTION = {'needs_input', 'blocked', 'uncertain', 'review'};
    ACTIVE = {'queued', 'running', 'waiting'};
    KIND_TITLES = {
        'linkedin': 'LinkedIn profile review',
        'application': 'Archived application assistant',
        'jobs': 'Job-fit analysis',
        'resume': 'Resume tailoring',
        'network': 'Networking outreach',
        'profile': 'Profile suggestions',
        'prep': 'Interview coaching',
        'stories': 'Behavioral story drafting',
        'code': 'Code practice run',
        'live': 'Live interview',
        'sync': 'Email tracking',
        'calendar': 'Calendar assistant'
    };
    STEP_LABELS = {
        'linkedin_scan':'Sign in and read your profile', 'linkedin_review':'Analyze recruiter appeal',
        'inspect': 'Read the application form',
        'fit': 'Analyze job fit',
        'tailor': 'Tailor your resume',
        'approve_resume': 'Approve resume changes',
        'fill': 'Fill the application',
        'submit': 'Submit the application',
        'research': 'Read the contact source',
        'draft': 'Draft the message',
        'send': 'Send the email',
        'profile': 'Draft profile suggestions',
        'coach': 'Coach your answer',
        'story': 'Organize your reviewed event into STAR',
        'sync': 'Check Gmail for updates',
        'execute': 'Run your code',
        'calendar': 'Add the interview to Calendar',
        'interview': 'Live practice interview'
    };
    RESULTS = {
        'linkedin':'Network → LinkedIn profile review, and this task. Copy suggested edits into LinkedIn yourself.',
        'application': 'Saved results from the retired application assistant.',
        'jobs': 'Applications → this job → Agent help, and this task.',
        'resume': 'Review job-specific changes before generating your resume. Reviewed PDF/DOCX content produces a PDF and editable DOCX in a Stack template; uploaded LaTeX keeps its format and source. Your original is preserved.',
        'network': 'Network → your contacts, and this task. Sent emails appear in your Gmail Sent folder.',
        'profile': 'This task. Copy the suggestions you like into your profile yourself.',
        'prep': 'Prep → your practice session → Coaching.',
        'stories': 'Your private story bank API and this task. Review source quotations and fill missing details.',
        'code': 'Prep → your practice session → Test results.',
        'live': 'Web workspace → Practice → your session transcript.',
        'sync': 'Applications (status history) and Agents → Needs you (messages to confirm).',
        'calendar': 'Your Google Calendar, in “Stack interviews and preparation”, after you approve.'
    };
    STATUS_TEXT = {
        'queued': 'Waiting for the agent worker. It starts automatically.',
        'running': 'Working now.',
        'paused': 'You have browser control. Resume the agent when you are done.',
        'waiting': 'Ready to start.',
        'needs_input': 'Stack needs information from you to continue.',
        'blocked': 'Paused by setup or limits. Fix the item below, then retry.',
        'review': 'Nothing has been shared yet. Review exactly what will happen, then approve or cancel.',
        'uncertain': 'An outbound action may already have happened. Confirm what happened before anything else runs.',
        'failed': 'This task stopped after repeated errors. Retry it or dismiss it.',
        'completed': 'Finished. Results are below.',
        'cancelled': 'Cancelled. Nothing further will run.'
    };
    NEXT_ACTION = {
        'needs_input': 'answer',
        'blocked': 'retry',
        'review': 'review',
        'uncertain': 'reconcile',
        'failed': 'retry',
        'completed': 'results'
    };
}
"""The value the worker hashes as payload_hash for this step (see agents.worker.dispatch)."""
def review_payload(
    step: str, context: dict[(str, any)], artifacts: dict[(str, any)]
) -> any {
    if (step == 'approve_resume') {
        tailored = artifacts.get('tailor', {});
        return {
            'changes': tailored.get('changes', []),
            'rejected': sorted(tailored.get('rejected', [])),
            'dropped': tailored.get('dropped', []),
            'plan': tailored.get('plan', {}),
            'source': tailored.get('source_digest', '')
        };
    }
    if (step == 'send') {
        return artifacts.get('draft', {});
    }
    if (step == 'calendar') {
        return context.get('event', {});
    }
    raise ValueError('This step does not need review.');
}
def review_summary(
    step: str, context: dict[(str, any)], artifacts: dict[(str, any)]
) -> dict[(str, any)] {
    job = context.get('job', {});
    employer = job.get('company', 'the employer');
    if (step == 'approve_resume') {
        tailored = artifacts.get('tailor', {});
        return {
            'step': step,
            'title': ('Review your tailored resume for ' + employer),
            'summary': tailored.get('summary', ''),
            'changes': tailored.get('changes', []),
            'rejected': tailored.get('rejected', []),
            'dropped': tailored.get('dropped', []),
            'pages': tailored.get('pdf', {}).get('pages', 0),
            'notes': `list(tailored.get('notes', [])),
            'score': tailored.get('score', {}),
            'consequence': 'Stack keeps the changes you accept, rebuilds the PDF in your format, and fits it to one page. Nothing is shared.'
        };
    }
    if (step == 'send') {
        draft = artifacts.get('draft', {});
        contact = context.get('contact', {});
        return {
            'step': step,
            'title': (
                ('Send follow-up to ' if context.get('followup') else 'Send email to ') + str(contact.get('name', 'your contact'))
            ),
            'to': contact.get('email', ''),
            'subject': draft.get('subject', ''),
            'body': draft.get('body', ''),
            'followup': bool(context.get('followup')),
            'notes': [],
            'consequence': 'Stack sends this exact email from your Gmail. You can edit the subject and body first.'
        };
    }
    if (step == 'calendar') {
        event = context.get('event', {});
        return {
            'step': step,
            'title': (
                'Add “'
                + str(event.get('summary', 'Interview'))
                + '” to Google Calendar'
            ),
            'event': {
                'summary': event.get('summary', ''),
                'start': event.get('start', {}).get('dateTime', ''),
                'end': event.get('end', {}).get('dateTime', ''),
                'location': event.get('location', ''),
                'status': event.get('status', '')
            },
            'notes': [],
            'consequence': 'Stack adds or updates this event in its own “Stack interviews and preparation” calendar.'
        };
    }
    raise ValueError('This step does not need review.');
}
def context_label(kind: str, context: dict[(str, any)]) -> str {
    job = context.get('job', {});
    if job.get('title') {
        return (str(job['title']) + ' · ' + str(job.get('company', '')));
    }
    if context.get('contact') {
        c = context['contact'];
        return (
            str(c.get('name', 'Contact')) + ((' · ' + str(c['company'])) if c.get('company') else '')
        );
    }
    if context.get('problem') {
        return str(context['problem'].get('title', 'Practice session'));
    }
    if context.get('event') {
        return str(context['event'].get('summary', 'Interview'));
    }
    if kind == 'linkedin' { return context.get('linkedin_url', '') + (' · ' + context['target_role'] if context.get('target_role') else ''); }
    if (kind == 'profile') {
        return 'Your professional profile';
    }
    if (kind == 'sync') {
        return 'Gmail';
    }
    return '';
}
def present(
    kind: str,
    status: str,
    index: int,
    steps: list[str],
    context: dict[(str, any)],
    next_at: float = 0.0,
    now: (float | None) = None
) -> dict[(str, any)] {
    now = time.time() if (now is None) else now;
    position = min(index, (len(steps) - 1));
    title = KIND_TITLES.get(kind, kind.title());
    if ((kind == 'network') and context.get('followup')) {
        title = 'Follow-up email';
    }
    explanation = STATUS_TEXT.get(status, '');
    if ((status == 'queued') and (next_at > now)) {
        explanation = (
            'Retrying automatically in about '
            + str(max(1, int((((next_at - now) + 59) // 60))))
            + ' min.'
        );
    }
    return {
        'title': title,
        'context_label': context_label(kind, context),
        'step_label': STEP_LABELS.get(steps[position], steps[position]),
        'step_number': (position + 1),
        'step_total': len(steps),
        'steps': [STEP_LABELS.get(s, s) for s in steps],
        'explanation': explanation,
        'next_action': NEXT_ACTION.get(status, ''),
        'results_where': RESULTS.get(kind, ''),
        'attention': (status in ATTENTION),
        'active': (status in ACTIVE)
    };
}
with entry {
    FEATURES = [
        {
            'key': 'linkedin',
            'kinds': ['linkedin'],
            'title': 'LinkedIn profile review',
            'where': 'Network or web workspace → Network',
            'summary': 'Reads your profile after you sign in, identifies recruiter-facing weaknesses, and suggests evidence-backed rewrites.',
            'input': 'Your LinkedIn profile URL, optional target role, and sign-in inside the agent browser on your task.',
            'review': 'You confirm the profile before capture. Profile text goes to your configured model; login details stay in the browser session. You apply edits yourself.',
            'alternative': 'Use Profile suggestions on Resume to draft a headline and About from your confirmed facts.'
        },

        {
            'key': 'networking',
            'kinds': ['network'],
            'title': 'Networking & follow-ups',
            'where': 'Network',
            'summary': 'Drafts a short email to a contact you chose, from your confirmed facts, and schedules polite follow-ups that stop on reply.',
            'input': 'A contact you add with a verified email, and Gmail sending permission.',
            'review': 'Every email and follow-up waits for your approval. Saving a contact never sends anything.',
            'alternative': 'Drafts work without Gmail sending: open the task, copy the draft into your own email, then cancel the task.'
        },
        {
            'key': 'tailoring',
            'kinds': ['resume'],
            'title': 'Resume tailoring',
            'where': 'Resume',
            'summary': 'Edits your LaTeX resume for a specific job (reorders, rewords, and trims to one page) and keeps your format.',
            'input': 'A reviewed PDF/DOCX or uploaded LaTeX, and a saved job.',
            'review': 'You accept or reject each change before the PDF is final. Download the finished PDF and use it when you apply yourself.',
            'alternative': 'Edit your resume in Overleaf yourself using the job-fit analysis.'
        },
        {
            'key': 'fit',
            'kinds': ['jobs'],
            'title': 'Job-fit analysis',
            'where': 'Applications',
            'summary': 'Explains strengths, gaps, and unknowns for a saved job, quoting the listing and your confirmed facts.',
            'input': 'A saved real job. Confirmed resume facts make the analysis specific.',
            'review': 'Nothing is shared outside Stack.',
            'alternative': 'Open Full details on a job card to see the deterministic requirement checks.'
        },
        {
            'key': 'profile',
            'kinds': ['profile'],
            'title': 'Profile suggestions',
            'where': 'Resume',
            'summary': 'Suggests a headline and about section from your confirmed facts, with the evidence for each edit.',
            'input': 'At least one confirmed fact.',
            'review': 'Suggestions are drafts. Stack never edits LinkedIn or any other site.',
            'alternative': 'Write your headline yourself using your confirmed facts.'
        },
        {
            'key': 'coaching',
            'kinds': ['prep'],
            'title': 'Interview coaching',
            'where': 'Prep',
            'summary': 'Scores a saved practice answer against a rubric and suggests what to practice next.',
            'input': 'A saved practice session with your answer, code, or transcript.',
            'review': 'Nothing is shared outside Stack.',
            'alternative': 'Use Show practice guide on the Prep questions to check your own answer.'
        },
        {
            'key': 'code',
            'kinds': ['code'],
            'title': 'Code practice runs',
            'where': 'Prep',
            'summary': 'Runs your Python, C++, or SQL practice code against tests in an isolated sandbox.',
            'input': 'A coding practice session with code.',
            'review': 'Your code runs only in a networkless sandbox.',
            'alternative': 'Walk through the test cases by hand using the practice guide.'
        },
        {
            'key': 'live',
            'kinds': ['live'],
            'title': 'Live interviews',
            'where': 'Prep',
            'summary': 'Holds a timed voice mock interview about your practice session and saves the transcript for coaching.',
            'input': 'The web workspace, a microphone, and a practice session.',
            'review': 'You review the transcript before requesting coaching.',
            'alternative': 'Type or dictate your answer, then use Get coaching.'
        },
        {
            'key': 'email',
            'kinds': ['sync'],
            'title': 'Email tracking',
            'where': 'Applications',
            'summary': 'Checks Gmail every few minutes for application replies, assessments, interviews, and rejections, and updates status.',
            'input': 'Gmail read access and the Gmail tracking permission.',
            'review': 'Unclear messages wait for you to confirm the application and status.',
            'alternative': 'Update application status yourself after reading your email.'
        },
        {
            'key': 'calendar',
            'kinds': ['calendar'],
            'title': 'Calendar assistant',
            'where': 'Applications',
            'summary': 'Adds interview invitations found in Gmail to a Stack calendar and prepares a matching study plan.',
            'input': 'Gmail tracking plus Google Calendar access.',
            'review': 'Every calendar change waits for your approval.',
            'alternative': 'Accept the invitation in your email, and use Build interview plan on the application.'
        }
    ];
    ACTION_NAMES = {
        'model': 'Model',
        'send_email': 'Send email',
        'calendar_write': 'Calendar write',
        'gmail_read': 'Gmail read'
    };
}
"""facts: plain account/deployment facts; returns per-feature readiness and fix actions."""
def feature_status(facts: dict[(str, any)]) -> list[dict[(str, any)]] {
    now = facts.get('now', time.time());
    policy = facts.get('policy', {});
    model = facts.get('model', {});
    scopes = `set(facts.get('google_scopes', []));
    rules_on = bool(policy.get('enabled')) and (policy.get('expires_at', 0) > now);
    def check(
        key: any,
        label: any,
        ok: any,
        fix: any,
        action: any = '',
        user: any = True,
        optional: any = False
    ) -> any {
        return {
            'key': key,
            'label': label,
            'ok': bool(ok),
            'fix': '' if ok else fix,
            'action': '' if ok else action,
            'user_fixable': user,
            'optional': optional
        };
    }
    def rules() -> any {
        return check(
            'rules',
            'Standing permissions on',
            rules_on,
            'Turn on standing permissions in Agents → Rules. They expire after 30 days.',
            'rules'
        );
    }
    def permission(action: any, optional: any = False, prefix: any = '') -> any {
        ok = (
            (action in policy.get('actions', []))
            and (
                (action not in EXTERNAL.values())
                or policy.get('daily_limits', {}).get(action)
            )
        );
        return check(
            ('perm:' + action),
            (prefix + 'Permission: ' + ACTION_NAMES[action]),
            ok,
            (
                'Allow “'
                + ACTION_NAMES[action]
                + '” with a daily limit in Agents → Rules.'
            ),
            'rules',
            optional=optional
        );
    }
    def operator(action: any, optional: any = False, prefix: any = '') -> any {
        return check(
            ('operator:' + action),
            (prefix + ACTION_NAMES[action] + ' enabled on this server'),
            (facts.get('operator_limits', {}).get(action, 0) > 0),
            (
                'The operator has not enabled “'
                + ACTION_NAMES[action]
                + '” for this deployment.'
            ),
            '',
            user=False,
            optional=optional
        );
    }
    def provider() -> any {
        return check(
            'model',
            'Model provider connected',
            model.get('configured'),
            str(
                model.get(
                    'message', 'The operator has not configured a model provider.'
                )
            ),
            '',
            user=False
        );
    }
    def google(scope: any, label: any, optional: any = False) -> any {
        if not facts.get('google_client') {
            return check(
                ('google:' + scope),
                label,
                False,
                'Google sign-in is not configured on this server.',
                '',
                user=False,
                optional=optional
            );
        }
        return check(
            ('google:' + scope),
            label,
            (scope in scopes),
            'Connect Google in Agents → Rules.',
            ('connect:' + scope),
            optional=optional
        );
    }
    model_checks = [provider(), rules(), permission('model')];
    table: dict[str, any] = {
        'linkedin': (
            model_checks
            + [
                check(
                    'browser',
                    'Browser worker available',
                    facts.get('browser'),
                    'The operator must configure the isolated browser worker.',
                    '',
                    user=False
                ),
                check(
                    'facts',
                    'Confirmed facts for stronger rewrites',
                    (facts.get('verified_facts', 0) > 0),
                    'Confirm resume facts to support your suggestions.',
                    'facts',
                    optional=True
                )
            ]
        ),

        'networking': (
            model_checks
            + [
                check(
                    'contacts',
                    'A contact you selected',
                    (facts.get('contacts_selected', 0) > 0),
                    'Add a contact with a verified email on the Network tab.',
                    'contacts'
                ),
                permission('send_email', optional=True, prefix='To send: '),
                operator('send_email', optional=True, prefix='To send: '),
                google('send', 'To send: Gmail sending connected', optional=True),
                check(
                    'domains',
                    'To send: recipient domains allowed',
                    (len(policy.get('domains', [])) > 0),
                    'Add each recipient’s email domain to allowed destinations in Rules.',
                    'rules',
                    optional=True
                )
            ]
        ),
        'tailoring': (
            model_checks
            + [
                check(
                    'resume',
                    'An uploaded resume',
                    (facts.get('resumes', 0) > 0),
                    'Upload a PDF on the Resume tab.',
                    'resume'
                ),
                check(
                    'facts',
                    'Default resume is ready for tailoring',
                    (facts.get('tailor_source', '') in ('latex', 'builtin', 'records')),
                    (
                        'Review and confirm imported records for '
                        + (facts.get('tailor_resume') or 'your default resume')
                        + ', or upload its LaTeX on the Resume tab.'
                    ),
                    'resume'
                ),
                check(
                    'applications',
                    'A saved real job',
                    (facts.get('applications', 0) > 0),
                    'Swipe right on a job to save it.',
                    'jobs'
                )
            ]
        ),
        'fit': (
            model_checks
            + [
                check(
                    'applications',
                    'A saved real job',
                    (facts.get('applications', 0) > 0),
                    'Swipe right on a job to save it.',
                    'jobs'
                ),
                check(
                    'facts',
                    'Confirmed resume facts',
                    (facts.get('resume_facts', 0) > 0),
                    'Confirm resume facts for a more specific analysis.',
                    'facts',
                    optional=True
                )
            ]
        ),
        'profile': (
            model_checks
            + [
                check(
                    'facts',
                    'Confirmed facts',
                    (facts.get('verified_facts', 0) > 0),
                    'Confirm at least one fact in Agents → Facts.',
                    'facts'
                )
            ]
        ),
        'coaching': `list(model_checks),
        'code': [
            check(
                'sandbox',
                'Code sandbox available',
                facts.get('sandbox'),
                'The operator has not configured the isolated code sandbox. Your code is still saved.',
                '',
                user=False
            )
        ],
        'live': [
            check(
                'voice',
                'Voice service available',
                not facts.get('voice_error'),
                str(facts.get('voice_error', '')),
                '',
                user=False
            ),
            check(
                'web',
                'Web workspace available',
                facts.get('web_url'),
                'The web workspace is not hosted yet.',
                '',
                user=False
            ),
            rules(),
            permission('model')
        ],
        'email': [
            rules(),
            permission('gmail_read'),
            google('read', 'Gmail tracking connected')
        ],
        'calendar': [
            rules(),
            permission('calendar_write'),
            operator('calendar_write'),
            google('read', 'Gmail tracking connected'),
            google('calendar', 'Google Calendar connected')
        ]
    };
    out = [];
    for feature in FEATURES {
        checks: list[dict[str, any]] = table[str(feature['key'])] as list[dict[str, any]];
        missing = [
            c
            for c in checks
            if (not c['ok'] and not c['optional'])
        ];
        state = 'ready'
            if not missing
            else 'unavailable'
                if `any(not c['user_fixable'] for c in missing)
                else 'setup';
        limited = (
            (state == 'ready') and `any((not c['ok'] and c['optional']) for c in checks)
        );
        out.append(
            {
                ** feature,
                'state': state,
                'limited': limited,
                'checks': checks,
                'ready_count': len(
                    [
                        c
                        for c in checks
                        if (c['ok'] or c['optional'])
                    ]
                ),
                'total': len(checks)
            }
        );
    }
    return out;
}

