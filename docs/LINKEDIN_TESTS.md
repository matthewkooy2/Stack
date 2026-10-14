# LinkedIn review test inventory

This inventory describes the source on PR #86 at `f81e72bb6654f0f60fd338b9cd3d064a15e60131`, including its captured-section fix. It records what tests assert, not a claim that every suite was executed for this documentation update. See [scan mechanics](LINKEDIN_SCAN.md), [failure gates](LINKEDIN_FAILURE_GATES.md), and the [feature overview](LINKEDIN_PROFILE_REVIEW.md).

## Counts and test methods

| Dedicated coverage | Count | Method |
| --- | ---: | --- |
| [tests/test_linkedin.py](../tests/test_linkedin.py) | 22 test methods | Python `unittest`; real Stack logic with mocked browser and model boundaries. PR #86 adds two methods. |
| [tests/test_linkedin_dom.py](../tests/test_linkedin_dom.py) | 4 test methods | Real Playwright Chromium against synthetic HTML; no live LinkedIn or model calls. |
| [tests/linkedin_workflow_tests.jac](../tests/linkedin_workflow_tests.jac) | 1 named Jac test | Isolated API/database lifecycle with two accounts and controlled browser/model results. Many assertions in one test. |
| [ios/StackTests/LinkedInSetupTests.swift](../ios/StackTests/LinkedInSetupTests.swift) | 11 XCTest methods | Pure Swift setup and URL logic against artificial settings. |
| [tests/native.cjs](../tests/native.cjs) | 3 relevant named function groups | `browserKeyboardTests`, `linkedinScreenTests`, `linkedinWebTests`; component rendering and mocked RPC responses. |

The first four rows contain **38 named test cases**, plus three JavaScript function groups. This is not a single 41-case runner. Loops and assertions inside a case are not additional cases. The earlier **42 focused checks** refers to 22 LinkedIn unit methods plus the 20 methods in `test_agent_providers.py`, not 42 LinkedIn-specific tests. The existing feature overview's historical "4 Jac workflow tests" groups multiple workflow files; this dedicated LinkedIn workflow file itself has one named test.

Tests arrange a known situation, call the production function, and assert the expected result or error. `MagicMock` replaces browser objects; `patch` temporarily replaces model calls, HTTP calls, or configuration. These stand-ins allow exact input inspection and reproducible failure injection without credentials, costs, or external actions. DOM tests instead exercise the real extraction JavaScript and browser timing against fixtures.

## All 22 LinkedIn unit tests

Identifiers below are the exact method names in `tests/test_linkedin.py`. The common capture contains Intro, About, and Experience. The common review has an About finding and an evidence-backed headline rewrite.

| Test | Setup and assertions | Why it matters |
| --- | --- | --- |
| `test_only_explicit_linkedin_profiles_are_accepted` | Normalize a valid profile URL; reject HTTP, lookalike hosts, embedded credentials, non-profile paths, encoded separators, nonstandard ports, loopback, and invalid handles. | Keeps the requested destination an explicit LinkedIn profile. |
| `test_browser_destination_boundary` | Permit LinkedIn login/challenge navigation and a LinkedIn CDN asset; reject other origins and navigation to the asset CDN. | Separates permitted page navigation from permitted resource loading. |
| `test_capture_is_bounded_and_unread_is_not_missing` | Supply oversized sections and unexpected password/message fields; assert the total limit, exclude unexpected fields, preserve unknown sections, and reject a missing Intro. | Prevents unbounded capture and false claims that unread content is missing. It checks the total limit, not every per-section length independently. |
| `test_first_scan_always_waits_for_user_then_captures_and_closes` | First scan opens login without extracting; second returns sections, closes the context, removes sessions/frames, and uses no restored storage state. | Protects user-controlled sign-in and ephemeral session cleanup. |
| `test_capture_waits_for_hydrated_header_and_publishes_progress` | Scan a prepared mock page; assert a header wait, scrolling from the top, at least sixteen published frames, and a returned artifact. | Protects loading coordination and observable progress; it does not prove real DOM timing. |
| `test_resumed_navigation_and_capture_failures_identify_the_actual_stage` | Inject navigation timeout and screenshot failure; assert their stage names and retained session. | Makes failures diagnosable without losing the browser immediately. |
| `test_loading_timeout_pauses_without_fabricated_capture` | Make every header wait fail; expect `needs_input`, no artifact, and an existing session. | Prevents reviewing an unloaded page. |
| `test_public_profile_cannot_be_captured_without_signing_in` | Remove the login cookie; expect user input and no extraction. | Enforces the existing signed-in-session requirement, even for a public profile. |
| `test_mobile_frame_coordinates_and_owner_isolation` | Send a valid click, then an out-of-bounds click; check 430×780 coordinates and another owner's empty frame. | Protects accurate remote clicks and account isolation. |
| `test_login_wall_never_becomes_a_profile_artifact` | Simulate a challenge URL after initial login; expect a pause, no extraction, and a retained session. | Prevents login/challenge content from becoming a profile review. |
| `test_redirect_to_other_profile_is_not_captured` | Simulate another profile URL; expect a pause and no extraction in this mock navigation scenario. | Protects the requested-profile boundary. |
| `test_sessions_are_owner_scoped_and_never_checkpointed` | Create two owners' sessions; check distinct session keys, no checkpoint/storage-state save, independent close, and expiry. | Protects session separation and avoids persisting login state. The mock browser context is shared by the fixture, so this is not a real cookie-isolation proof. |
| `test_purge_removes_only_owners_live_frames` | Purge one of two owners using temporary storage; retain the other's image and session. | Prevents cleanup from affecting another account. |
| `test_missing_header_requests_help_instead_of_fake_review` | Make extraction return no sections; expect user input. | Prevents proceeding without a readable profile header. |
| `test_profile_handoff_refuses_file_upload` | Reject an unsupported `file` event and another owner's snapshot request. | Covers unsupported handoff input and owner lookup; it is not an end-to-end upload test. |
| `test_analysis_quotes_and_rewrite_sources_are_checked` | Accept a good review; reject invented quotes, an unread section, invalid priority, and unsupported rewrite evidence. | Protects the final evidence checks and the returned unread-section metadata. |
| `test_analysis_uses_captured_profile_and_keeps_unknowns` | Mock Codex CLI generation; inspect its prompt for captured sources and "unknown, not missing", and check profile URL metadata. | Checks that the analysis request uses actual captured material. |
| `test_findings_cannot_cite_unread_or_mismatched_sections` **(new in #86)** | Submit Skills quoting Intro, Projects quoting Experience, and About quoting Experience; require the captured-evidence error for all three. | Covers both unread sections and wrong-section quotations. This protects existing validation and can pass without the schema fix. |
| `test_request_schema_offers_only_captured_sections_without_leaking` **(new in #86)** | Generate two mocked Codex requests: Intro/About/Experience, then Intro/Skills. Assert the exact allowed names, matching prompt list and trace schema, and unchanged shared template. | Directly catches the old all-section schema, cross-request mutation, and inconsistent diagnostics. The PR records that this test fails without the fix. It mocks the CLI boundary rather than exercising the executable or every provider. |
| `test_invalid_analysis_is_blocked_without_requesting_answers` | Make provider generation raise a source error; require `blocked`, no answer requests, and an unchanged capture. | Protects retrying analysis from saved evidence instead of asking for another login. |
| `test_review_validation_reports_a_useful_reason` | Return an invented quote from the mock model; require the captured-evidence reason and retry-analysis guidance. | Makes rejection actionable for the user. |
| `test_worker_routes_scan_and_passes_artifact_to_model` | Inspect scan routing to the browser handler, then the saved capture passed to model generation. | Connects the two workflow stages without external services. |

## All four real DOM tests

| Exact method in `ProfileDOM` | Assertions and value |
| --- | --- |
| `test_legacy_sections_and_hidden_private_text` | Extract Intro/About from `h1` and section-marker HTML; omit hidden duplicates, inputs, textareas, navigation, and aside text. Tests extraction behavior rather than mocked section dictionaries. |
| `test_mobile_cards_with_h2_name_and_heading_sections` | Extract Intro, Experience, and Skills from `role=main`, `h2`, and `.artdeco-card` fixtures. Protects the alternate layout supported by the extractor. |
| `test_real_scan_waits_for_delayed_profile_and_completes` | Fulfill every request locally, simulate a login cookie, insert the profile after 3.5 seconds, call real `scan`, and assert text and cleanup. Protects actual hydration timing without LinkedIn traffic. |
| `test_loading_shell_and_section_heading_are_not_a_profile_header` | Reject a loading shell and avoid interpreting an About-only heading as Intro. Protects against a false profile header. |

## Durable LinkedIn workflow test

The named Jac test is **"LinkedIn profile capture waits for sign-in and remains private to its owner"**. It uses an isolated temporary store and real API entry points. Its assertions cover:

- Account-specific saved URL/role, normalization, persistence after reopening the client, and invalid URLs.
- Start rejection with unavailable model/browser setup; two-stage task creation; reuse of an active matching task.
- Watching frames while working; rejection of browser input without control; another account denied task, browser, answer, and log access.
- Sign-in pause, idle claims while waiting, rejection of login details in task answers, and resume with no credential facts.
- Saved scan passed into the review stage; blocked analysis retains the scan and exposes no validated report.
- Response-log worker/lease checks, exact rejected raw output, removal of extra secret fields, owner-only access, and export.
- Retry at `linkedin_review` without recapture; a new response attempt retained alongside the previous one; successful report completion.
- Fresh task after completion, cancellation routed to browser stop, durable logs after API reopening, and deletion isolation.

This is valuable for persistence and ownership behavior across a whole task. Browser HTTP replies, capture input, and finished model results are controlled. It does not execute a real LinkedIn login, provider inference, or the production worker loop end to end.

## All eleven Swift setup tests

| Exact XCTest method | Assertions and value |
| --- | --- |
| `testFullyConfiguredAccountGoesStraightToTheProfile` | Ready account gets only the profile step, avoiding unnecessary setup. |
| `testUnknownReadinessNeverBlocksAndTheServerStaysTheAuthority` | Missing readiness data does not fabricate a client-side block. |
| `testScreenshotStateListsOnlyRequiredUnmetStepsAndSkipsOptionalFacts` | Missing permission/model produces only required steps; optional facts do not prevent review. |
| `testConfiguredAlternativeModelIsOfferedBeforeAnythingElse` | Offer a configured alternative before permission/profile setup. |
| `testSavedSelectionThatIsConfiguredOverridesAStaleSnapshot` | Fresh account model status overrides an older unavailable feature snapshot. |
| `testExpiredPermissionNeedsAllowingAgain` | Expired permission requires renewed model permission. |
| `testBrowserWorkerIsAnOperatorStepAfterTheStepsAPersonCanFinish` | Missing browser setup follows user-manageable permission steps. |
| `testTurningPermissionsOnWouldSurfaceEverySavedChoiceForRulesReview` | Surface dormant email/calendar/Gmail/top-match choices before re-enabling standing permissions. |
| `testAlreadyActivePermissionsAreNotPresentedAsRearming` | Avoid presenting active permissions as newly re-enabled actions. |
| `testProfileAddressAcceptsLinkedInProfilesAndAddsAMissingScheme` | Trim a valid URL and supply missing HTTPS. Server validation remains authoritative. |
| `testProfileAddressRejectsOtherSitesSchemesAndPaths` | Reject empty, unsafe, lookalike, credential-bearing, company, and unsupported subpage URLs. |

These exercise `LinkedInSetup`, not real Swift browser controls, a phone session, or live inference. The current selected native-core list is [scripts/ci/ios-core-tests.txt](../scripts/ci/ios-core-tests.txt); existence in source does not imply inclusion in that selection.

## Web and compiled React Native function groups

| Group in `tests/native.cjs` | Assertions and value |
| --- | --- |
| `browserKeyboardTests` | In embedded and full-screen views, hold a snapshot request open while typing. Require the same editable input instance and preserve unsent input through refresh and attempted submission. Protects local input from refresh loss. |
| `linkedinScreenTests` | Check URL/role save and start, preserved form on failure, saved URL account separation, browser errors and expiry/reopen, coordinate scaling, masked transient input, login routing, empty-answer resume, read-only capture, blocked/legacy analysis retry, visible findings/unread sections, and selectable rewrites. Protects the compiled React Native user flow using mocked RPCs. |
| `linkedinWebTests` | Render the compiled web entry flow; assert task start, same-session browser, ordered text/Enter events, no upload control, resume, report rendering, and closed handoff. Protects web wiring using mocks. |

These require generated compiled assets and the test harness dependencies. They retain assertions against their existing component contracts, including legacy private-input/reopen controls; a changed production component can make them stale. They are not proof of the Swift interface, physical-keyboard behavior, or a real employer/LinkedIn page.

## Shared coverage that also supports LinkedIn

The following files contain general-purpose tests rather than additional dedicated LinkedIn review cases. Do not add all their counts to the dedicated total.

| Source and size | Relevant protection |
| --- | --- |
| [tests/test_agent_providers.py](../tests/test_agent_providers.py), 20 methods | Provider choice and default isolation; unavailable local configuration; CLI owner identity and quota configuration; paid configuration; unchanged source validation; Meta structured routing; subprocess environment/credentials; startup/login failures; tool-free ephemeral Codex/Claude calls; timeout/output limits; configuration-change pause. Interview/story/plain-coaching methods in this file cover other workflows. The new #86 capture-specific schema case is in `test_linkedin.py`, not this file. |
| [tests/test_model_logs.py](../tests/test_model_logs.py), 6 methods | Five non-voice methods cover both CLIs and APIs retaining success/rejection/malformed/incomplete responses, durable per-retry identity, logging failure before generation, and provider errors without output. They use `fit` fixtures; LinkedIn-specific persistence is covered by the Jac workflow above. One method is voice-specific. |
| [tests/provider_transport_tests.jac](../tests/provider_transport_tests.jac), 2 named tests | Meta routing through the fixed HTTP allowlist and rejection of insecure/lookalike destinations. Uses fit results, not LinkedIn-specific captured-section assertions. |
| [tests/test_browser_service.py](../tests/test_browser_service.py), 12 methods | Nine methods directly exercise scan/shared service paths: safe scan-failure diagnostics, preserving sanitized diagnostics in the worker, sanitized transport failures, diagnostic vocabulary restrictions, immediate owner-scoped frames during capture, snapshot thread confinement, purge during a long scan, take interruption, and stop interruption. Two methods exercise autofill; one rejects retired operations. |
| [tests/test_browser_control.py](../tests/test_browser_control.py), 6 methods | Acknowledged takeover; current-controller/ordered input; fencing another viewer; out-of-band stop; single-use account-scoped grants; account revocation of active work/grants. |
| [tests/test_browser_stream.py](../tests/test_browser_stream.py), 3 methods | Latest-frame streaming, disconnect without ending a task, revocation without cached-frame leakage, and owner-authorized gateway streaming. |
| [tests/test_browser_preview.py](../tests/test_browser_preview.py), 9 methods | Preview URL/config preservation, service health/dead process checks, browser build context excludes account data, missing Docker, low disk, Docker startup, cached-image reuse, and LinkedIn gateway exposure without worker authority. |

## Running and interpreting verification

Use the project's pinned runtime and setup described in [CI.md](CI.md) and [README.md](../README.md). From the repository root in the supported shell:

```sh
scripts/jac run --no-serve tests/test_linkedin.py
scripts/jac run --no-serve tests/test_agent_providers.py
scripts/jac run --no-serve tests/test_model_logs.py
scripts/jac test tests/linkedin_workflow_tests.jac
```

Run `scripts/jac run --no-serve tests/test_linkedin_dom.py` in the prepared browser environment with Playwright and Chromium installed. The browser fixture suite intentionally has no LinkedIn credentials. For the generated React Native/web harness after the appropriate compilation/build:

```sh
STACK_TEST_LINKEDIN_UI=1 node tests/native.cjs
STACK_TEST_LINKEDIN_WEB=1 node tests/native.cjs
```

Swift tests need the documented Xcode toolchain; run the `LinkedInSetupTests` class through the existing project test workflow. Do not assume a green backend/native-core check ran these focused suites: [scripts/ci/core-tests.py](../scripts/ci/core-tests.py) and the native selection list define the actual automatic cases. This documentation adds no CI gate.

The original PR records 22 LinkedIn unit tests passing, provider tests passing, and Jac checks with existing annotation warnings. This documentation update does not claim a fresh runtime run. Remaining gaps include real LinkedIn sign-in/current DOM, a live model request, capture-specific request assertions across every provider, device handoff, and some legacy compiled UI fixture contracts.
