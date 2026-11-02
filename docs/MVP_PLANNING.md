# Stack MVP planning

Backend audit against [MVP scope](MVP_SCOPE.md). Production: `8cc6d80`, November 1, 2026. Status describes implementation, not verification. iOS work is a separate audit.

## Backend features and functionality

### Locked scope

| Area | Implemented | Partial / missing |
| --- | --- | --- |
| Onboarding | Career and matching preferences; resume upload | Guided screens are iOS work |
| Jobs | Discovery, filters, pass/save | Resume scoring exists for saved jobs; add it to browsing cards |
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
