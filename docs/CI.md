# Essential verification and native release

Automatic verification has two paths. `CI` runs backend/security plus its existing
`CI passed` summary; backend deployment still waits only for this workflow.
`Stack SwiftUI app` runs `Native core (Xcode 27)`. Backend deployment does not depend
on native tests. No branch rules, deployment settings or credentials change here.

PRs test GitHub's synthetic merge checkout. Main tests its exact pushed checkout.
Neither workflow uses path filters, so a required result cannot disappear because
an unexpected file changed. Superseded PR runs may be cancelled; main runs and
uploads are not cancelled. Only trusted main code is executed with signing assets.
Native PR tests use disposable GitHub-hosted runners, read-only permissions, no
signing environment and no secrets. There is no `pull_request_target` execution.

## What blocks

The backend job retains the checksum-pinned credential scanner, its complete Git
history scan and both fixture-directory scans with unchanged historical exception
policy. It reuses contributor bootstrap, Jac checks and startup/restart smoke.
`scripts/ci/core-tests.py` is the explicit existing test selection: bootstrap/PDF
resource safety, gateway admission, provider permissions/budgets/credential
isolation, fixture/signing/backend packaging safety, durable resume edits and
transcripts, Google account isolation, safe uploads, model-free autofill ownership
and retired application submission boundaries. These checks prevent credential
exposure, account leakage, lost data, unsafe uploads and unauthorized paid or
external actions. Do not substitute `make test`, which runs the broader selection.

Native core selects the exact 30 unit cases and four UI journeys in
`scripts/ci/ios-core-tests.txt`. They protect account transitions and isolation,
resume draft/revision/save integrity, durable recording and the real modern Speech
bridge, feed session isolation and safe listing URLs. The UI journeys exercise
welcome/login validation, resume save/confirmation, recording pause/stop/retry and
listing open/close. They use controlled transport and fictional loopback pages;
they do not prove live sign-in, microphone hardware, speech assets or phone layout.
Every selected XCTest must execute and pass once. Missing, skipped or duplicate
execution is failure. An unsigned Release compile also remains required because
the fixture UI scenes are Debug-only.

The sole native toolchain is Xcode 27.0 build 27A266a with XcodeGen 2.46.0. Both
verification and archive reject generator drift. The destination is iPhone 18
Pro, iOS 27.0. The proof also binds the installed simulator runtime build, so a
runtime update invalidates reuse. Deployment target remains iOS 17.0.

## Removed duplication and moved coverage

| Previous automatic work | Replacement |
| --- | --- |
| Full native suite on Xcode 15.4 PR/main | Removed older-toolchain lane |
| Full native suite on Xcode 26.6 speech PR lane | Essential speech cases in the single Xcode 27 job |
| PR79's additional full Xcode 27 PR/main lane | One curated Xcode 27 job |
| Full native suite inside signing/upload | Exact-source verification, then archive/sign/upload |
| Four-way backend integration matrix and broad contributor test list | Explicit essential backend cases |
| Separate signing workflow and speech backend job | Essential checks in backend/security |
| Broad Windows, backend and browser/ATS regressions | Existing suites retained in manual regression |
| Legacy Expo unsigned archive on PRs | Explicit manual `validate_legacy` input |

Main contains 168 native unit methods and 45 UI methods. Blocking native selection
is 30 plus four; the other 138 units and 41 UI methods remain intact. Reduced
blocking coverage includes parser/layout variants, full keyboard and accessibility
journeys, browser redirects/history/reload/handoff, filter variants, older compiler
fallbacks, Windows orchestration, push-provider journeys and broad browser rendering.
Moving a test does not erase a known defect or certify its behavior.

Run the existing full backend/browser/Windows suites via `Manual regression`.
Its original integration matrix is preserved, not expanded. Run all native cases
with `Stack SwiftUI app`'s `full_suite` manual input, still on Xcode 27. Legacy Expo
full-suite Safari failure/reload acceptance needs the observed `listing_error_text`
input; missing calibration fails rather than claiming acceptance. Native full-suite
and repeatability jobs retain a 60-minute manual ceiling.
validation/upload remains explicit under `Stack TestFlight deployment`; existing
upload authorization and signing protections are preserved. No nightly schedule
or replacement framework is added.

## Exact-source release proof

The native job publishes a small JSON record bound to its commit/tree, run and
attempt, toolchain and optional originating PR run. The record is not authority:
`ios-native-proof.py` verifies GitHub-owned repository/event/workflow/job/step
results, current-attempt artifact identity, commit tree and PR base/head identities.
It independently reconstructs the PR merge tree. The complete tree binds sources,
tests, fixtures, scripts and workflow policy together. Fork and manual-run evidence
cannot authorize release. Native reuse inspects only the most recent PR run; absent,
expired, ambiguous or different evidence means executing native tests on actual
main. A newer failed/pending attempt cannot be replaced with an older green one.
The main native result may reference one verified PR result; chains are bounded.

Git-history scanning always runs on main: equal final trees can have different
credential-bearing history. Backend/security verification is never skipped by
native reuse.

Swift TestFlight follows a successful native main-push workflow, checks out that
exact commit and validates both native and backend/security results before signing.
It waits at most ten minutes for the same-commit backend result, without delaying
backend deployment. Missing, pending, failed or skipped required results prevent
upload. The commit must still be current main. Automatic docs-only pushes do not
upload; manual upload retains its explicit input. The upload script independently
revalidates evidence for direct invocations. Archive identity, HTTPS configuration,
manual signing, private-file cleanup, upload and exact Apple processing checks
remain. No simulator suite runs in the signing environment. Workflow completion
does not dispatch CI again, so there is no trigger loop.

## Budgets and acceptance evidence

Targets are backend/core under ten minutes and native under fifteen, with respective
15- and 20-minute job ceilings. These are provisional budgets, not measured claims.
The manual native `repeatability` input runs three sequential attempts without
automatic retries, keeps separate logs/result bundles and prints elapsed time.
Initial acceptance needs three clean identical-source runs and independent review.
Known defects must be corrected rather than masked with automatic retry.

Observed baseline on 2026-10-12: run 38233036245 took 38m58s for Xcode 27 and 26m43s
for the older native job; run 38233036142 took 33m44s for speech-native; failed main
TestFlight run 38218268359 took 47m13s. These are job durations, including setup and
build work, not summed wall-clock waits or forecasts of this candidate's runtime.

## Rollback

Before edits, baseline ecb1ee4beca29597c6f483951db4aca6da94e9a9 was preserved as
`ci-baseline-20261012`, with a verified complete-history bundle adjacent to the
isolated checkout: `stack-ci-baseline-20261012.bundle`. The original workflows and
scripts are also recoverable from that immutable commit. Restore them via an
ordinary reviewed revert; do not reset main or remove user data.
