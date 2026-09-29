# Phone Previews Across Worktrees

From `/Users/matthewkooy/Developer/Stack`:

```sh
./dev status
./dev agent-experience
./dev mainworktree
./dev stop
```

The `dev` symlink points to `worktrees/mainworktree/scripts/worktree-dev.py`.
Only one worktree occupies the phone's standard API/Metro ports (8000/8081).
Reload Stack after switching; the server address does not change. Sign in with
your usual main account. Every feature-worktree activation automatically copies
main's account data and CLI settings, including when that worktree is already running.
The existing Mac Codex/Claude subscription login is reused and checked before the
current preview is stopped; no provider credentials are copied into the worktree.

The launcher compiles before stopping the previous preview, verifies startup,
and restarts the previous checkout if the new one fails. A lock prevents two
agents switching the phone simultaneously. It only stops recognized Stack
development supervisors in registered worktrees, not unrelated port owners or
independent test APIs. It does not merge, commit, clean, or reset working files.

Each worktree keeps its own `.jac`, database, uploads, tokens, provider settings,
and generated native files. The database and uploaded PDFs are copied from main before each feature activation.
Do not share writable `node_modules` through a symlink between worktrees.
New worktrees need their one-time `./scripts/setup`; worktrees with changed native
dependencies can also require rebuilding the installed iPhone development client.

Parallel agents should run test APIs on separate ports with worktree-local data.
Switch the shared phone preview only when the user asks to review that branch.
`agent-experience` currently predates OpenResume; switching does not bring the
newer resume features from `mainworktree` into that branch.

## Automatic Account and CLI Setup

`./dev agent-experience` replaces that preview's data with a snapshot of `mainworktree`.
The old `--refresh-from-main` flag remains a compatibility alias; it is no longer
required. Old preview sessions expire automatically, so sign in with your usual
main username and password. Your profile, uploaded PDFs, contacts,
applications and history are copied; preview edits never sync back to main.
Each feature activation replaces preview edits; the previous database and storage
are retained in the private backup described below. Keep useful test feedback before switching.

The launcher stops the managed preview and refuses other active database
connections. The launcher starts or initializes the worktree-local Jac PostgreSQL clusters
without starting API workers. Main must already contain the account and a valid
CLI owner link; the account is never guessed or granted to every test user. No external
database/config overrides or shared data symlinks are accepted. Refreshing main
itself is prohibited. Source code is never copied, merged or reset.

The copied main CLI owner receives model-only permission for seven days, using
main's selected Codex/Claude CLI and model, capped at 20 requests/day (or main's
lower configured limit). Each worktree has its own budget; this is not a combined
subscription-wide cap. Refresh keeps the greater source/preview count for each
usage key, so existing preview usage cannot be reset by refreshing.
The CLI account link uses Jac's canonical UUID hex format; equivalent hyphenated
operator IDs are also accepted, without allowing a different account to use it.
Imported unfinished runs are blocked, tickets and notifications cancelled,
Google connections disconnected, push tokens removed, and automatic follow-ups
disabled. No discovery/provider API credentials or browser state are copied.
API spending, external action quotas, certified submission adapters and sandbox
execution stay disabled. Explicit new model requests can use your local CLI
subscription; refresh itself makes no model calls.

Before cutover, both databases are dumped and uploaded PDFs are checksum-checked.
Serialized Jac module names are relocated to the target worktree. The old preview
database is retained under a `stack_previous_*` name, with private dumps, original
storage and a manifest under `<preview>/.jac/preview-backups/<timestamp>/`.
Startup failure restores the previous database, storage, and session signing key
before restarting the previous preview. Successful refreshes rotate only the
preview signing key so sessions from replaced identities cannot linger. Main
login sessions and CLI credentials are never copied or changed. Backups include personal data and password hashes; keep them
private and never commit them. `.jac` is never deleted, and main's graph, identity
records and PDF checksums are verified unchanged after cutover.
