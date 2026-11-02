# Stack MVP planning

Backend audit against [MVP scope](MVP_SCOPE.md). Production: `8cc6d80`, November 1, 2026. Status describes implementation, not verification. iOS work is a separate audit.

## Backend features and functionality

### Locked scope

| Area | Implemented | Partial / missing |
| --- | --- | --- |
| Onboarding | Career and matching preferences; resume upload | Guided screens are iOS work |
| Jobs | Discovery, filters, pass/save | A confirmed-details [job score](JOB_SCORE.md) exists for saved jobs; add it to browsing cards |
| Resume | PDF/DOCX import, editing, Jake/Classic, change approval, PDF export | Finish creation without upload and fuller ATS rewriting for PDF/DOCX |
| Applications | Supported-form autofill, notes, reminders, calendar, Gmail sync | Complete agreed stages, Offer detection, manual stage editing and short applicant confirmation; use tailored output for applying and Prep |
| Networking | Contact entry/import, outreach drafts, reviewed Gmail sending | Add job-specific people discovery, contact/application links and referral status; give referral drafts job context |
| Prep | Job-specific questions, transcription, coaching, retries, final assessment | Consistent scores; current backend supports 2–6 answers and requires two before finishing |

**Verify / measure:**

- **Onboarding / Jobs:** saved preferences, relevant fresh results, duplicate-free saves, resume-score accuracy; first-feed and search latency.
- **Resume:** extracted fields, edit persistence, complete guided creation, faithful exports, useful factual rewrites and exact accepted changes; import/tailoring time.
- **Applications:** autofill accuracy and manual effort, exact resume attached, correct Gmail/manual stages, reminder/calendar dates; completion and sync time.
- **Networking:** relevant people with valid sources, correct referral links/status, useful job-specific drafts and exact approved sends; discovery/drafting time.
- **Prep:** relevant questions, transcription accuracy, useful coaching, consistent scores, retries and final assessment; answer-to-coaching time.

### Open scope

- **Implemented:** typed job search, LinkedIn review/rewrites, fixed technical-question catalog, coding exercises, saved feedback retrieval. Coding execution is disabled in production.
- **Partial:** uploaded-layout preservation (requires source files), LinkedIn-to-resume import (capture only), conversational interviewer (separate practice voice backend), attempt comparison (history only). Voice is disabled in production.
- **Missing:** AI resume interview, potential-score prediction, swipe setting, GitHub/portfolio improvements, video interviewer and camera answers. Generic profile writing exists; swipe behavior is primarily iOS work.

Resolve each Open item as **MVP / Later / Drop** in the scope document.

**Verify / measure if included:** field completeness for imports/interviews; layout fidelity; predicted versus actual score; relevant profile edits/technical feedback; coding correctness; voice/video delay and continuity; accurate attempt/history retrieval; swipe-setting persistence.

## Benchmark method

Use fixed examples, human-reviewed AI outputs, median/p95 timings and cold/warm runs. Check repeated requests do not duplicate records or sends. Measure polished end-to-end behavior later on iPhone.

## Demo verification

- **PC availability:** repaired the gateway/model port collision and started the existing WSL keepalive task. Public routing, API health and browser health pass; no resource cleanup needed.
- **Real iPhone:** login and Prep recording/coaching retest pending after the connection repair.
- **Other locked flows:** not user-verified yet.

## Local coaching simplification candidate (November 2, 2026)

Branch `codex/simple-coaching-20261102`, based on `bc49ae0`. SwiftUI Prep now reviews transcription before explicit Get coaching, calls the local model directly, displays feedback, and separately persists its submitted answer/feedback pair. The path no longer saves drafts or edits transcription on the server, creates agent runs, or polls for coaching. Atomic local drafts retain typed edits and unsaved results. Existing account access, input limits and ordinary session revision checks remain.

Verified locally: focused endpoint regression (25.9 seconds), including stale revisions, exact pairing, save replay, failed inference and account isolation; one real Qwen3.8 27B request through the approved bridge (10.843 seconds inference, exact pair persisted in a disposable database); existing Swift structural/backend-call checks and nine checker tests; live API allow-list contract. New Swift XCTest behavior cases cover double taps, edits during inference, late transcription, inference/local/account storage failures and reopening. This PC has no Swift/Xcode toolchain, so those XCTest cases and device behavior remain unverified. No deployment, CI/CD gate, model/network setting or shared-service restart was performed. Publication and deployment through the existing owners require approval; the Mac owner must build/test the native candidate and verify it on iPhone.

## Confirmed-details job score candidate (November 2, 2026)

Publication candidate is based on `1b7c89d`; the latest resume screen layout is preserved. The manual [synthetic benchmark](JOB_SCORE_EVALUATION.md) covers 54 cases: evidence checks improve from 34/46 to 41/46 and ranking pairs from 22/29 to 29/29 against a faithful old-scorer outline. These agent-authored examples do not establish human agreement. Known gaps include not-only negation, valid claims on URL-containing lines, domain-specific tenure and mandatory licenses. Current-head native build and acceptance remain outstanding; keep the PR draft pending those checks and review of the known limitations.

Branch `codex/job-score-confirmed-facts-20261102`, based on `46d5956`. **Score my resume** on a saved job now returns the versioned `stack.job_score` v1 contract ([job score](JOB_SCORE.md)): one deterministic score computed only from the resume's confirmed records (plus chosen confirmed bullet-bank experience), never from unconfirmed imports, uploaded LaTeX alone, tailored text, name/contact lines or negated clauses. Inputs are canonicalized and digested, including an explicit `as_of` month. It replaces the earlier document score for this endpoint, which also scored unconfirmed LaTeX and gave record resumes no title, education or experience credit. `score_resume` keeps a compatibility `score` field for the `mobile/` clients; SwiftUI shows a new job score card. Tailoring's before/after document scores are unchanged.

Verified locally: `tests/test_job_score.py` (10 cases, pinned output, equivalent-input and renumbering invariance, explicit `as_of`, negation/name/contact exclusion, section credit, alternatives, thin listings, invalid inputs) under two hash seeds, and byte-identical output across three processes; `jac check` for the new module, `main.jac` and `mobile/components/Agents.jac`; Swift static checks. API workflow (scratch copy, embedded Postgres, a fake local-model endpoint for the import draft): unconfirmed imports are refused and confirmed PDF/DOCX records score with exact evidence IDs; that test's final account-deletion storage assertion fails identically on unmodified `46d5956`. The LaTeX test in `tests/agent_experience_tests.jac` (updated to expect a refusal for unconfirmed LaTeX) fails on `46d5956` at its upload-format assertion before reaching the score checks, so those updated assertions are unexecuted. This PC has no Swift toolchain, so the SwiftUI card and `JobScoreCopyTests` are uncompiled and unverified on simulator or iPhone. Not yet measured: human-reviewed score accuracy on real listings. Browsing-card scores remain open.
