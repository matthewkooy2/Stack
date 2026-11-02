# Mac handoff for the consolidated review

This is a local source handoff, not an installable app. The intended source is branch
`codex/consolidated-review-20261102`. The accompanying Git bundle contains that
branch and its history. The exact tip is recorded in the external checkpoint file.
The snapshot manifest is `docs/CONSOLIDATED_REVIEW_20261102.md`.

## Preserve current Mac work

Do this only on the authorized Mac. Do not reset, clean, switch, stash away edits,
stop another task, or overwrite its branch. First record its current branch, full
HEAD, status and owner. Export a binary tracked diff and the untracked source
files into a private temporary handoff directory. Preserve original bytes and
SHA-256 hashes. Include the current `codex/jobs-photo-deck` full-height card,
photo feed/cache consumers, swipe-to-tailoring behavior and their tests. Verify
whether the typed memory or tailoring UI has additional active edits. Do not
copy ignored credentials, private runtime state, databases or uploads.

Create an isolated checkout from the bundle:

```sh
git clone --branch codex/consolidated-review-20261102 /path/to/consolidated-review.bundle Stack-review
cd Stack-review
git rev-parse HEAD
```

Import the preserved Mac source as a separately identified local snapshot commit,
then reconcile it into the review branch. Keep the new Mac renderer and gestures;
the PC snapshot renderer is historical. Preserve the media contract in
`discovery/job_photos.json` and the page-level employer logo map. Compare Models,
JobDeckFeed and JobFeedCache rather than overwriting them. Include both sides'
independent backend dependencies. Do not merge any feature PR into main.

## Verify and build

Run the existing Swift checks, affected XCTest/UI flows, and unsigned build against
the final source. Verify job photos/logos on first and cursor pages, swipe-to-tailor,
Google/Gmail, resume review, the format picker, scoring and reviewed-answer Prep.
The existing signed TestFlight workflow is main-only. Do not edit that policy or
create a signing workaround for this preview.

Use the existing authorized local device signing route, with the phone unlocked:

```sh
STACK_API_URL=https://dev.stackmvp.top scripts/ios-phone.sh
```

This script installs and launches on the paired phone. Report the exact final
commit, build number, endpoint, and actual install result. A source bundle,
successful simulator test or available build is not a verified phone installation.

## Pair backend before review

The shared backend is currently `/home/mkooy/src/Stack-team-dev` at `bc49ae04`
plus preserved local patches. The PC task prepared `backend-candidate.tar` from
its integration tip, plus `deploy-review.py` with preflight, source backup and
rollback. Nothing has been deployed by this consolidation task. If Mac integration
changes backend dependencies, regenerate the archive from the final source before
deployment; do not deploy the older archive.

Coordinate this single deployment owner. Recheck exact live file hashes and service
PID immediately before changing source. Preserve storage, credentials, auth,
Qwen3.8 27B NInfer, private network boundaries and `dev.stackmvp.top`. Roll back source
only if acceptance fails; never restore a stale database over current user data.
Verify public health and protected routes plus authenticated first/cursor feed,
resume import/confirmation, typed memory, scoring and Prep on the final backend.

Publishing this branch was denied by automatic approval review. It has not been
pushed. Obtain explicit publication approval before pushing or opening a PR;
do not retry through another tool to bypass the denial.
