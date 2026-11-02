# Resume repair handoff

The review branch includes the combined Mac UI, whole-memory tailoring and onboarding patch
`59b27f3cabe823d70d3c920e31a387b63c66bb81`, followed by this repair. Do not substitute main.

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

## Authorized Mac-local build

Preserve existing Mac edits. Fetch the published review branch and create an isolated worktree at the
exact repair SHA supplied with this handoff. Verify `git rev-parse HEAD` before building. The endpoint is
`https://dev.stackmvp.top`.

```sh
git fetch origin codex/consolidated-review-20261102
git worktree add ../Stack-resume-review <EXACT_REPAIR_SHA>
cd ../Stack-resume-review
STACK_API_URL=https://dev.stackmvp.top bash scripts/ci/ios-swift.sh build
```

Run `ResumeUploaderTests`, `AccountWorkflowTests` and affected resume tests on the existing simulator.
Use the existing local simulator signing and destination options from `CLAUDE.md` where needed to
preserve its session. Never switch the endpoint to localhost for the demo.

For the existing paired phone installation route, after native checks:

```sh
STACK_API_URL=https://dev.stackmvp.top STACK_BUILD_NUMBER=2026.11.4 scripts/ios-phone.sh
```

Use another unused build number if necessary. Record source SHA, endpoint, bundle version, build and
install/launch receipts. Exercise one-tap upload, repeated taps, Files cancel, read/upload failure/retry,
PDF/DOCX, confirm/edit once, select/preview each design, Continue during a delayed design save, and
tailor from those confirmed details without another upload. Check actual Qwen elapsed time and source
provenance. This task has no authorized Mac execution surface and did not access one.
