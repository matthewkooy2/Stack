# Resume repair handoff

This standalone repair candidate is based on combined source/onboarding patch
`59b27f3cabe823d70d3c920e31a387b63c66bb81`. It is NOT the newest authoritative UI and has NOT been
published to the review branch. Do not build it as the complete current app or replace Mac Swift files.

The user identified `/Volumes/DevSSD/Projects/Developer/Stack/worktrees/review-onboarding-filters-20261102`
and its `2026.11.4` phone build as the authoritative UI. Its exact HEAD and uncommitted diff have not
been provided here. No matching published onboarding/filter branch was found. Preserve that worktree
and apply only the needed focused repair after comparing its code and recording its exact source.

PDF/DOCX upload retains the paper control, responds when Files opens, shows reading/upload progress,
guards repeated taps, retains the file for explicit retry and binds it to the account that picked it.
Tailoring offers the existing designs (Jake plus Awesome-CV, Bill Ryan, Sourabh Bajaj, Deedy and
Jan Kuster), review/confirmation and PDF preview. Continue waits for the design save. No source upload
is required. Existing uploaded-source documents remain supported.

Confirmed imported records now remain the tailoring source for every built-in design. Template choice
only changes rendering. It does not read the original upload or parse generated source on that path.
The record source retains review revision, upload digest, bank sources and selected template; existing
proposal/source digest checks still apply. Derived memory facts are skipped only when their current
key, resume identity, value and provenance prove they belong to the same base resume revision.
Other confirmed facts and memory remain available. No provider or factual verification was changed.

## Verification on Windows / local WSL

- `jac check main.jac`: passed, 56.32 seconds (existing warnings remain).
- `jac run --no-serve tests/test_memory_tailoring.py`: 13 tests passed, 10.631 seconds.
- Focused reuse probe: confirmed edits, exact derived-fact removal, independent/other-resume facts,
  revision mismatch, proof integrity and owner checks passed.
- `python scripts/ci/ios-swift-static.py`: 120 files passed.
- Python compilation and `git diff --check`: passed.

The new `ResumeUploaderTests` and updated `AccountWorkflowTests` have not run: this PC has no Xcode.
No native build, simulator/phone interaction, live API workflow or end-to-end Qwen timing is claimed.
No backend service was restarted or deployed by this task.

## Matching backend

Deploy these three files together over the existing combined `59b27f3` backend using the existing
deployment owner and backup/rollback route, after checking the shared worker is idle:

- `main.jac`
- `agents/memory_access.py`
- `agents/memory_tailoring.py`

The matching backend is needed for the confirmed-record reuse behavior; API availability alone does
not establish that behavior. Existing template assets remain unchanged. Preserve uploads, accounts,
worker/provider configuration and user decisions. Check a disposable confirmed resume with an edit,
select a design, preview, tailor and review; measure complete latency separately from tokens/second.

## Required Mac-local integration before a build

The Mac owner must first record the authoritative worktree's HEAD, branch, status and complete diff.
Create a separate candidate preserving those changes; apply the resume repair by behavior/context,
not by replacing Swift files with this older baseline. Compare upload/setup/formatting and tailoring
views against the authoritative UI. Keep its onboarding/filter behavior. Publish the resulting exact
combined source SHA only after current-source checks. The endpoint is `https://dev.stackmvp.top`.

```sh
# Run from the correctly integrated candidate, not this older standalone source.
STACK_API_URL=https://dev.stackmvp.top bash scripts/ci/ios-swift.sh build
```

Run `ResumeUploaderTests`, `AccountWorkflowTests` and affected resume tests on the existing simulator.
Use the existing local simulator signing and destination options from `CLAUDE.md` where needed to
preserve its session. Never switch the endpoint to localhost for the demo.

For the existing paired phone installation route, after native checks:

```sh
STACK_API_URL=https://dev.stackmvp.top STACK_BUILD_NUMBER=<UNUSED_BUILD_NUMBER> scripts/ios-phone.sh
```

Use another unused build number if necessary. Record source SHA, endpoint, bundle version, build and
install/launch receipts. Exercise one-tap upload, repeated taps, Files cancel, read/upload failure/retry,
PDF/DOCX, confirm/edit once, select/preview each design, Continue during a delayed design save, and
tailor from those confirmed details without another upload. Check actual Qwen elapsed time and source
provenance. This task has no authorized Mac execution surface and did not access one.
