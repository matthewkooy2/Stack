# Agent feature integration

## Sources and account authority

Main source checkpoint: `bb6bc92`. Agent-experience source: `816f9dd` only;
network-agent source: `f477c75` only. Later feature worktree edits are excluded.
Design worktrees and the Jev experiment are excluded. Integration branch:
`codex/integrate-agent-features`. No source worktrees are removed or published.

Main accounts, identities, provider configuration, budgets, and uploads remain
in main. The baseline private backups are outside Git under
`.integration-backups/20260929-133639`, with separate database archives and storage
archives for main, agent-experience, and network-agent and SHA256 manifests.
Feature databases are never imported into main.

## Combined behavior

- Persistent agent access, contextual launches, readiness and activity counts,
  progress, retry, dismissal, reconciliation, and drafts preserved while polling.
  Saving a job or contact does not launch an outbound action.
- Uploaded LaTeX/Overleaf and built-in templates, source validation, compile
  recovery, one-page fitting, per-change review, deterministic scoring and parser
  comparisons. Tailored source/PDF copies stay separate from uploads and retain
  job association. Main's parser confirmation and feedback controls remain.
- Saved LinkedIn URL/target role, bounded capture, cited findings and rewrites,
  manual private sign-in, browser handoff, session reopening, cancellation, and
  analysis retry using an existing capture.
- Automatic private model response history plus opt-in bounded/redacted prompt
  and stage tracing. One provider lifecycle feeds both; attempt identifiers
  correlate them. Raw responses persist before parsing, failures stop acceptance,
  and diagnostics stay outside action approval hashes. Feedback identifies the
  reviewed output version. Export/deletion cover sources, tailored copies, logs,
  feedback, and traces.

## Workflow compatibility

`AgentRun.workflow_version` defaults to 1 for old stored records. New runs use 2.
All step presentation, claim, authorization, completion, trace and reconciliation
paths use the record's version. Completed/cancelled/failed records and their
artifacts are unchanged by migration.

Legacy unfinished resume/application tasks pause idempotently. Any unresolved
external dispatch becomes uncertain and requires reconciliation. Explicit retry
regenerates preparation through version 2, discarding incompatible intermediate
artifacts and requiring a LaTeX source and fresh review. Confirmed submission
receipts finish the old task without dispatching again. Worker-only
`agent_upgrade_workflows` is deliberately absent from the public gateway. Reads
and claims also guard legacy tasks, so interruption cannot bypass migration.

## Language boundaries

Jac 0.37.21 is pinned. All new/affected agent application logic is `.jac`, with
`agents.*` pinned to server placement. Python standard/library dependencies are
imported directly; no duplicate Python implementations or inline Python blocks
are present in migrated modules.

Retained boundaries:

- Vendored OpenResume TypeScript and its narrow Node PDF bridge.
- Browser-executed DOM JavaScript and native/web bindings for platform APIs.
- LaTeX templates, static data, CSS, manifests, and deployment configuration.
- Existing Python regression/development/backup tooling; the old agent-admin
  Python command only forwards arguments to its Jac implementation.
- Existing discovery modules and sandbox exercise supervision were outside this
  integration; they have not been rewritten or replaced with duplicate code.

The browser image installs checksum-verified native Jac 0.37.21 Linux assets,
loads Jac modules directly, runs as `pwuser`, retains Chromium's sandbox and a
single Playwright execution thread with an independently readable frame cache.
Its filesystem is read-only apart from temporary storage. `/tmp` must permit
execution for Jac's bundled interpreter; it remains `nosuid`. Only explicitly
listed browser sources enter its build context. The cached image carries no
model credentials, account databases, or browser sign-in state.

## Validation and local cutover

Use fresh disposable PostgreSQL databases per workflow suite when setting
`JAC_DB_URL`: global subscription quotas intentionally span all accounts in a
database. Do not run those suites against main. Native screen tests similarly
use a separate API and an empty provider configuration. Tests make no live sends
or submissions.

Checks include compiler validation, frozen-revision differential helpers, real
Tectonic compilation, private diagnostics, approval and recovery workflows,
legacy restart/idempotence, controlled Chromium DOM fixtures, gateway allowlists,
phone/web rendering, and preview rollback. Differential cases explicitly cover
conditional-expression grouping: the converter can drop required parentheses.

Real LinkedIn sign-in, live model/provider operation, native phone delivery and
external sends/submissions require separate acceptance exercises. Fixture and
renderer tests do not claim those have been certified.

Before main cutover, recheck its Git state, take a new paired database/storage
backup, stop its managed workers, merge the verified integration, run the
idempotent migration, rebuild clients, and verify health. Never refresh main
from a feature database. If startup fails, stop the new processes and restore
the checkpointed code and its matching database/storage backup together.

Verification recorded on September 29, 2026: 29 agent/core/application compiler
checks; 13 frozen-source parity tests; helper regressions including 17 real
LaTeX cases, 11 scoring cases, all gateway allowlisted routes, and 19 LinkedIn
validation cases; all three complete resume workflows; all three diagnostic
tests; LinkedIn and provider-quota workflows; legacy migration across context
restart; native screen, tailoring screen, LinkedIn phone/web checks; and 30
preview-tool tests (one pre-existing skip). The first Jac browser image passed
authenticated health and four controlled Chromium DOM cases. Final image and
main cutover results are recorded separately after completion.

## Current integration checkpoint

Combined implementation: `117e145` (following the resume/experience integration
at `fbc5195`). The integration checkout is clean. Main remains `bb6bc92`; it has
not been merged or restarted. No feature-worktree edits after the pinned source
revisions were consumed.

The final source passed the three resume workflows, LinkedIn settings/workflow
persistence, and three diagnostic tests in separate disposable databases. A
copy of main's real backup was also upgraded twice: account identities and all
four terminal run records remained byte-for-byte unchanged, and the second
upgrade paused zero tasks. Test API/gateway processes and the disposable database
cluster have been stopped; the authoritative backups remain.

A fresh paired main backup is in
`.integration-backups/cutover-20260929-142604`, including 31 upload files and the
login secret. Its database archive and file checksums were verified.

**Remaining cutover gate:** load and cold-start the final browser image with the
explicit cryptography dependency, repeat health/DOM/encrypted-session checks,
then recheck main, merge, run compatibility handling and start the main preview.
The earlier image passed authenticated health (anonymous requests denied) and
all four controlled DOM tests. The final image export was interrupted by disk
exhaustion. Docker was recovered only after logs and process checks established
that its VM had already stopped. A subsequent guarded build refused to start
with less than 3 GB free. Free at least 10 GB before resuming; do not delete user
worktrees, account data, or unrelated Docker images to obtain it.

Live LinkedIn sign-in, live providers and physical-device delivery remain
unverified. No live messages, calendar actions, or applications were submitted.
