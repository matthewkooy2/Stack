# Presence and Network acceptance

## Scope and recovery

The approved Presence B and Network B surfaces are implemented inside the existing
Network bottom-tab destination. The top labels are exactly `Your Presence` and
`Your Network`; the screen and its bottom bar use the existing Brand tokens
(`#F5F3F0`, `#2563FF`, `#111111`). Ordinary tab navigation keeps the selected
surface. Explicit network/contact navigation selects the roster.

This work is on the same `codex/jobs-swipe-browser` branch, based on
`claude/ios-sim` commit `33f78667c86dd933d275175e663d888f6d8e0858`.
The previously delivered Jobs patch was recovered and verified byte-for-byte
before this work. Nine of its ten files remain byte-identical. The shared
`RootView.swift` retains all prior Jobs changes with exactly two Network-only
additions: explicit network route selection and the Network bottom-bar branding.
No unmerged PR was integrated. All changes remain local and uncommitted.

## Data and preserved actions

- Your Network reads real `agent_contacts`, not the sample people catalog in
  account bootstrap. Missing roles or companies are omitted, never filled from
  the concept art. Initial loading, failure/retry, empty, and cached refresh
  failure are handled explicitly.
- Each roster row opens that contact's existing outreach/review tools. Your
  contacts opens the complete existing contact manager. Opening a row sends no
  message. Contact creation/import, saved unfinished forms, task review and
  follow-up controls remain available.
- The overflow retains Profile, LinkedIn review, public-profile drafts and the
  explicitly labeled Discovery catalog. Catalog notes/drafts/reminders remain
  usable, including legacy contact notifications while real-contact loading is
  unavailable. Sample profiles never appear in the real roster.
- Presence expands LinkedIn inline. A real structured rewrite renders its
  Current and Suggested rewrite and reuses the existing rewrite editor. Current
  is populated only by an explicitly captured matching profile section; it is
  not guessed from a role, evidence quote or full-page text. Missing current
  capture is labeled honestly.
- **Backend limit:** the current LinkedIn implementation returns raw coaching,
  not guaranteed field-level rewrites. Those results show Open review rather
  than inventing a headline or presenting the whole report as a rewrite. The
  approved expanded headline layout is used when real structured artifacts are
  available. No new rewrite service or backend schema was added.
- No-review, running/failed review, loading/error/retry, empty edited rewrite,
  and session reset states are explicit. LinkedIn setup/browser/scan remain the
  existing flow. GitHub and Portfolio open the existing local draft editor on
  the correct platform. These drafts never publish to an external provider.

## Verification performed in this cloud Linux worktree

- Existing Swift structural validation: 99 Swift files passed (balanced syntax
  delimiters, unique types, published backend functions, project inclusion).
- Existing Python suites `test_ios_swift_static`, `test_ios_core`, `test_card`:
  16 tests passed.
- `git diff --check`: passed.
- Independent source/design/data review found and corrected legacy notification
  routing and retry-completion issues; final re-review found no remaining
  concrete source-level blocking defect.
- Added manual-only XCTest coverage: 8 Presence presentation cases and 6 roster
  cases. Updated Network XCUITest flow for the new tabs, empty real-contact
  roster, retained contact form and LinkedIn setup navigation. Added a separate
  GitHub/Portfolio destination and draft-retention UI test.
- Native build attempted through the existing script; it exits at its macOS /
  Xcode prerequisite on Linux. **Swift type-check/compile, XCTest, XCUITest and
  simulator/device visual acceptance have not run.** Structural checks do not
  establish any of those outcomes.
- No workflow, CI selection, project configuration, blocking test selection,
  gate, release condition, commit, push, PR, merge or deployment was added.

## Native acceptance still required

Use an authorized macOS/Xcode environment and the repository's existing workflow.
These are manual acceptance steps, not a request or authorization to add a gate.

1. Build Debug and Release. Run `PresencePresentationTests`,
   `NetworkRosterTests`, `RewriteReviewTests`, `ProfileDraftTests`, the two
   Presence/Network methods in `ScreenFlowUITests`, and the prior Jobs suites
   listed in `JOBS_UI_ACCEPTANCE.md`.
2. Compare both screens with the approved images on compact and larger iPhones.
   Verify the status/safe areas, pill tabs, overflow hit target, row spacing,
   blue contact CTA and branded Network bottom-tab state. Check all Dynamic Type
   sizes, VoiceOver, Reduce Motion, long names/roles/company text, and missing
   contact metadata. The top labels must remain fully available.
3. Verify real-contact loading, initial failure/retry, empty state, stale cached
   rows after failed refresh, successful retry, pull-to-refresh and repeated
   taps. A failed read must not silently show an empty successful roster.
4. Open a real roster row, review existing actions, close, open Your contacts,
   type an unfinished contact, close/reopen and switch both top/bottom tabs.
   The form and selected surface must survive. Check unknown/deleted contact
   targets and real-contact notifications.
5. Open the legacy Discovery catalog and a saved profile's notes/draft. Check
   its reminder notification resolves to that same profile, including while
   `agent_contacts` is unavailable. Confirm no catalog sample appears in Your
   Network.
6. Verify no-review setup, cancel/back, browser/login interruption, scan retry,
   raw-coaching review, real structured review, missing captured current text,
   long rewrite, edit/blank edit, approve/copy and close/reopen. Refresh and
   newer runs must not attach old drafts to changed source rewrites.
7. Open GitHub and Portfolio directly from their rows, save distinct drafts,
   cancel edits, close/reopen, and switch tabs. Check correct platform and
   isolation between platforms. Overflow public-profile drafts must still
   support the LinkedIn local editor too.
8. Sign out or replace the account during slow reads and while sheets are
   open. No prior user's contacts, review or local draft may survive or reappear
   when late responses return. Opening a contact or previewing a rewrite must
   not send/publish anything.
