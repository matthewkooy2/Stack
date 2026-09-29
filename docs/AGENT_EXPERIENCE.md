# Agent experience: access, review, and monitoring

Branch `codex/agent-experience`, based on `a186068` (before the OpenResume work).
This change makes every agentic feature reachable from the screen where it is
relevant, keeps the user in control of outbound actions, and shows progress and
recovery in one place. It does not add a provider, adapter, or new permission.

## Baseline findings

| Area | Baseline behavior | Gap |
| --- | --- | --- |
| Entry point | An "Agent activity" button scrolled away inside each tab; the Network tab embedded the whole hub | No persistent entry, no active/attention counts |
| Right swipe | Saved the job; with standing permissions enabled it also started a full application run | Launch was implicit; success was not confirmed; no follow-up actions offered |
| Contacts | Saving a *selected* contact with `send_email` permission started outreach | Saving triggered outreach |
| Outbound steps | `fill`, `submit`, `send`, `calendar` ran on standing permission alone | No per-action review of the exact payload |
| Monitoring | Hub loaded once; manual refresh; raw `kind · status` rows | No auto-refresh, no step progress, little task context |
| Recovery | Mobile could answer questions only; reconcile existed on web only; failed runs had no retry | Missing retry/dismiss/reconcile on phone; unclear next step for blocked setup |
| Explanations | Scattered one-line captions | No per-feature "what / needs / status / results / alternative" |
| Email and calendar | Ambiguous messages and interviews visible on web only | Not reachable on phone |

## Plan

### 1. Server contracts (Python, stateless)

- `REVIEWED = {fill, submit, send, calendar}`. `review_payload(step, context, artifacts)` returns
  exactly what the worker hashes as `payload_hash`; `review_summary(...)` returns the
  human-readable version (recipient, subject, body; answers and documents; event details).
- `FEATURES`: one catalog of the ten features with what it does, required input, where
  results appear, review points, and the manual alternative. `feature_status(facts)` turns
  account/deployment facts into per-feature readiness checks with fix actions.

### 2. Workflow state (`core/automation.jac`)

- `AgentRun` gains additive fields `approvals`, `review`, `dismissed` (defaults keep old rows valid).
- Claiming a reviewed step first checks the standing permission (so setup problems surface
  before review), then pauses the run in a new `review` status unless an approval exists for
  the *current* payload hash. Approval is bound to that hash; a changed payload asks again.
- `agent_authorize` rejects a reviewed step whose payload hash differs from the approval.
  This is the enforcement point: a worker cannot dispatch anything the user did not see.
- New owner-checked endpoints: `agent_approve` (optional subject/body edits for emails),
  `agent_retry` (failed/blocked), `agent_dismiss` (terminal runs).
- `agent_save_contact` no longer starts outreach. Follow-ups still get scheduled but stop
  at review before sending.
- Run views gain a title, task context label, step progress, status explanation, next
  action, and attention/active flags. The summary reports `active` and `attention` counts
  across all runs and always includes runs needing attention.

### 3. API (`main.jac`)

- `swipe` never starts an agent; `start_agent` is accepted and ignored for older clients.
- `agent_features` (also embedded in `bootstrap().agents.features`) reports readiness from
  model configuration, standing rules, Google scopes, browser/sandbox/voice configuration,
  resumes, confirmed facts, contacts, and applications.
- Notifications also fire for `review` and `blocked`.

### 4. iPhone app

- Header: persistent **Agents** entry with active and attention counts, refreshed by the
  existing 4-second bootstrap poll. The five tabs are unchanged.
- Agents center: *Needs you*, *Features*, *Rules*, *Facts*; task detail with context,
  step progress, answers, review/approve/edit, reconcile, retry, dismiss, cancel, results,
  and where results live. Auto-refreshes without overwriting unsaved answers or rules.
- Jobs: right swipe or **Save** shows a confirmation with optional agent actions.
- Applications: per-application agent panel (fit, tailoring, prepare & apply, interview
  plan) with readiness, live task status, and the manual alternative.
- Network: focused real-contact panel. Saving never sends; "Draft outreach" starts a run
  that stops for review. Email tracking status and ambiguous messages to resolve.
- Resume: fact extraction/confirmation, tailoring per application, profile suggestions.
- Prep: coaching, code runs, and live interviews with requirements, status, and alternatives.
- Email tracking and calendar: messages needing review, interviews, and calendar review
  inside the Agents center.

### 5. Web workspace

- Activity page shows review/approve, retry, and dismiss using the same endpoints, and the
  feature readiness list.

### 6. Verification

- New in-process Jac workflow test (`tests/agent_experience_tests.jac`) using a throwaway
  database: swipe/contact no-launch, review gating and hash binding for application fill and
  submit and for outreach send, retry/dismiss, counts, features, and cross-account ownership.
- Contract unit tests for review payloads/summaries and feature readiness.
- Native screen tests extended for the header entry, swipe confirmation, and agent panels,
  run against a worktree-local API on a separate port.
- `jac check` for changed modules (no new errors).

## Implementation notes

- `agents/experience.py` holds review payloads/summaries, task presentation, and the feature
  catalog with readiness (`ready`, `setup`, `unavailable`, plus `limited` when an optional
  capability such as sending from Stack is off). `bootstrap().agents` carries `active`,
  `attention`, enriched runs, and `features`, so the phone's existing 4-second poll keeps the
  header counts and every contextual panel current.
- Without Gmail sending (or Calendar), a draft (or event) still reaches review so the user
  can copy it, but approval is refused with a fix. The sandbox runs on a separate host, so the
  operator declares it with `"sandbox_available": true` in the agent config (or the API sees
  `STACK_SANDBOX_URL`).
- Unsent task answers, email edits, contact-form drafts, unsaved rules, and unsaved practice
  work survive refreshes; task answers and email edits also survive closing and reopening a task
  during the session.
- Two Jac client codegen issues were avoided: dict literals with computed keys and `+` on
  untyped lists do not compile to correct JavaScript here. Use `withKey` and separate lists.
- Endpoint arguments that are omitted may arrive as the text `"None"`; `agent_approve` accepts
  edits only when it receives a non-empty object.

## Verification (September 28, 2026)

Run from this worktree against its own API (`jac run --no-client --port 8310 Stack`) and its own
embedded Postgres; the main checkout's services were not used.

- `tests/agent_experience_tests.jac` (in-process, throwaway database): swipe with
  `start_agent=True` and a saved selected contact start nothing; application inspect → fit →
  tailor → **review of fill** (exact answers, documents, destination) → owner-only,
  hash-bound approval → `agent_authorize` rejects a tampered payload and accepts the approved
  one → **separate review of submit** → receipt → application Submitted; outreach draft review,
  refused approval without Gmail, cancel; blocked → retry after fixing rules; dismiss rules;
  counts; features; cross-account approve/retry/dismiss refused.
- `tests/test_agent_experience.py`: review payloads match the worker's hash inputs, summaries,
  presentation, readiness classification (10 features, all run kinds covered).
- `tests/native.cjs` with `STACK_TEST_AGENT_CONFIG` (the test plays the worker, so no model,
  browser, or email is contacted): header counts, save confirmation with no run started,
  interview plan from the confirmation, feature guide, rules kept through a refresh, facts,
  contact save without outreach, outreach review with edits kept through refresh and reopen,
  approval disabled without Gmail, cancel, application review of answers/documents, PDF preview,
  approval, answer requests kept through refresh. Existing native suites still pass.
- Existing suites: `provider_workflow_tests`, `catalog_tests`, `agent_documents`, 103 Python
  unit tests, and `test_api`, `test_agents_api`, `test_catalog_api`, `test_matching_api`,
  `test_timeline_api` pass. `jac check main.jac mobile web core agents` reports no errors
  (warnings are pre-existing in kind).
- Visual check in the phone-sized browser preview (390 px): header entry with both counts,
  Needs you list, application review panel, Applications card status line, Network panel.

## Limits

- Not run on a physical iPhone; the browser preview stubs icons and shows modals full-window.
- The web workspace changes type-check and compile to parseable JavaScript but were not
  exercised in a browser.
- Calendar review and follow-up review use the same generic gate as tested steps but were not
  driven end to end (they need Gmail sync fixtures). Mobile resolution of ambiguous email was
  not UI-tested.
- `tests/native.cjs` and `test_agents_api.py` claim the next task from the shared worker queue;
  run them against a server whose queue is otherwise empty.
- No real model, browser worker, Gmail, or Calendar call was made.
