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

## Approval for new gates

Adding any CI/CD gate requires Matt's explicit direct verification and approval
before implementation. A gate is a new blocking check, requirement, matrix or
release condition, including one added to an existing job or workflow. Agents
must not add gates on their own.

First present the proposed gate, the reason it is needed and its runtime/coverage
cost to Matt, including expected added runtime and coverage. Wait for his direct
verification and explicit approval before adding it. Broad permission to implement
or merge does not grant gate approval. Existing gates remain in place.

## Change impact routing

`scripts/ci/affected-checks.py` routes steps inside the existing jobs. Required
check names and workflow triggers stay present for every PR and main push; a
runtime no-op completes successfully and explains its selection in the run summary.
No new job, matrix, required check, schedule or framework is introduced. All three
credential scans still execute, including on documentation-only changes. Backend
bootstrap, Jac checks, safety cases and startup smoke run together when selected.
Native tests, unsigned Release compile and proof publication run together when
selected, retaining the existing identical-tree reuse rules.

| Changed paths | Backend runtime | Native runtime |
| --- | --- | --- |
| Root `README.md`, `AGENTS.md`, `THIRD_PARTY_NOTICES.txt`; `docs/**/*.md` prose | No | No |
| `web/**` only | Yes | No |
| `ios/**`, including tests, project settings and resources | Yes (existing Swift/static safety cases) | Yes |
| Shared API/auth/payload producers: `main.jac`, `core/**`, `agents/**`, `discovery/**`, `mobile/**` | Yes | Yes |
| Dependencies/build/runtime settings: `native/**`, `dependencies/**`, manifests, lockfiles and root config | Yes | Yes |
| Tests/fixtures (including their READMEs), scripts, `.github/**`, deployment, non-prose docs, unknown paths | Yes | Yes |
| Manual run, missing refs/identity, malformed event or unavailable diff | Yes | Yes |

This intentionally uses coarse existing suites. Backend implementation and native
source changes may run extra safety cases because shared contracts, fixtures and
policy are covered together. Narrower dependency partitions need separate evidence.
The native runner still starts to report its existing check; a no-op does not install
XcodeGen, start simulator tests, compile or publish proof.

PR selection verifies the synthetic merge's base/head parents and compares the
merge tree against their common ancestor. This includes base-side updates since
branch divergence as well as branch edits. Main pushes compare `event.before` to
the checked-out `event.after`, including every commit in a multi-commit push.
Local Git avoids API path limits; NUL-separated paths and disabled rename detection
include both old/new names and deleted paths. Any unavailable comparison runs both
existing suites. A routing error cannot turn missing output into a runtime skip.

Native no-op runs publish no proof. An automatic TestFlight follow-up recognizes
the successful GitHub-owned no-op marker with skipped tests/build/publication,
or the successful no-upload marker, and returns `upload=false` before requesting
proof. Upload eligibility keeps the existing native source/script/workflow/feature
RPC path map, using the complete push range rather than only its last commit.
Unavailable routing requires full verification and proof before any upload.
Manual and relevant uploads
still require the complete-tree proof, backend/security success, current main,
signing and Apple processing checks. A routing-only success cannot authorize signing.
The upload script independently uses strict `release-upload` verification: a no-upload
selection exits with failure before it can prepare source, archive, sign or upload.
Selector and release-boundary cases join the existing backend offline selection:
`python -m unittest tests.test_affected_checks tests.test_ios_native_proof -v`.

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

Native core selects the exact 30 unit cases in `scripts/ci/ios-core-tests.txt`. They protect account transitions and isolation,
resume draft/revision/save integrity, durable recording and the real modern Speech
bridge, feed session isolation and safe listing URLs. The three UI journeys that used to
block (welcome/login validation, resume save/confirmation, recording pause/stop/retry) and the Safari
journey now run only in the manual full suite (`full_suite`), because they boot and drive a simulator and
took about ten minutes of a thirteen-minute job. The unit cases do not prove live sign-in, microphone
hardware, speech assets or phone layout.
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
is the 30 unit cases; the other 138 units and all 45 UI methods remain intact in the manual full suite. Safari open,
close, navigation and recovery behavior remain available in the manual full suite.
Reduced blocking coverage includes parser/layout variants, full keyboard and accessibility
journeys, browser redirects/history/reload/handoff, filter variants, older compiler
fallbacks, Windows orchestration, push-provider journeys and broad browser rendering.
Moving a test does not erase a known defect or certify its behavior.

Run the existing full backend/browser/Windows suites via `Manual regression`.
Its original integration matrix is preserved, not expanded. Run all native cases
with `Stack SwiftUI app`'s `full_suite` manual input, still on Xcode 27. Native
full-suite Safari failure/reload acceptance needs the observed `listing_error_text`
input; missing calibration fails rather than claiming acceptance. Native full-suite
and repeatability jobs retain a 60-minute manual ceiling.
The manual `release_only` input compiles unsigned Release without replaying already
verified native tests. It never publishes native proof or authorizes an upload.
Legacy Expo validation/upload remains explicit under `Stack TestFlight deployment`; existing
upload authorization and signing protections are preserved. No nightly schedule
or replacement framework is added.

## Exact-source release proof

The native job publishes a small JSON record bound to its commit/tree, run and
attempt, toolchain and optional originating PR run. The record is not authority:
`ios-native-proof.py` verifies GitHub-owned repository/event/workflow/job/step
results, current-attempt artifact identity, commit tree and the actual checkout SHA
from the pinned checkout action's GitHub-owned log prefix. This survives GitHub
CLI versions that reject ANSI-bearing responses: only captured numeric job logs
opt into that transport flag when supported; raw logs are never printed or executed.
The bounded prefix and hex-only checkout identity checks remain required. This survives GitHub
removing PR associations when a PR closes; missing logs require actual-main testing.
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
remain. Apple confirmation requires the exact unexpired build to be `VALID` and
its beta detail to report `IN_BETA_TESTING` for existing internal or external testers.
Pending processing or tester availability fails after the bounded check. No tester
membership, signing permission or credential setting is changed by that read-only check.
No simulator suite runs in the signing environment. Workflow completion
does not dispatch CI again, so there is no trigger loop.

## Budgets and acceptance evidence

Targets are backend/core under ten minutes and native under fifteen, with respective
15- and 20-minute job ceilings. These are provisional budgets, not measured claims.
The manual native `repeatability` input runs three sequential attempts without
automatic retries, keeps separate logs/result bundles and prints elapsed time.
Initial acceptance needs three clean identical-source runs and independent review.
Known defects must be corrected rather than masked with automatic retry.

Candidate run 38255759216 on 9e6fca1 executed all 34 selected cases three times,
without missing, duplicate, skipped or failed selected cases: 102 passes. Iterations
took 10m44s, 7m33s and 5m38s. Its unsigned Release step failed before xcodebuild
because macOS Bash 3.2 rejected an empty selector array; the invocation now uses
positional arguments. This test success was not release proof. Backend/security
run 38255981715 on that candidate passed in 7m32s plus a 3s summary. Final-head
Release compilation and CI remain necessary after the invocation correction.

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
