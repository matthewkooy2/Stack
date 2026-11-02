# Consolidated review snapshot, November 2

Owner: Consolidate Stack review build (PC task `01a19c86-bf28-71fb-93f8-208413d060fe`).
Review branch: `codex/consolidated-review-20261102`. Backend target: `https://dev.stackmvp.top`.
Original feature branches and PRs are preserved. No feature PR is merged by this task.

| Change | Source owner / branch | Exact source commit | Decision |
| --- | --- | --- | --- |
| Current main, including Gmail #159, scoring #158, Google/native resume #156/#157 and parser #152 | Repository main | `a1b1cd4540320c8890216490ca3b9eea6e6e4198` | Included as baseline |
| Resume model schema prompt #160 | Fix shared resume parser / `codex/resume-schema-prompt-20261102` | `6d81191d5cc843d9c606ba0e2730acb53f988a59` | Included |
| Reviewed-answer Prep coaching | Simplify Stack coaching flow / `codex/simple-coaching-20261102` | `16fd8e0864fe39fc0d8eb26e63080c1d12e3c8b4` | Included; Google routes retained in conflict resolution |
| Typed memory entries, fields and attachments | Add typed memory bank entries / `codex/typed-memory-bank-20261102` | Preserved snapshot `4b719a5d3946e9bec4eaccc22e58f5a4af6f658d` | Included; source worktree untouched |
| Posting extraction, accurate details, employer logos, location photos and existing PC card renderer | Fix missing job card details / `codex/job-card-source-details` | Preserved snapshot `6265cefc05bcb8fa7083b56addc510316298f7d1` | Included; Mac renderer still pending |
| Five additional resume templates and native format picker | Find popular open-source LaTeX resumes / `codex/resume-template-library-20261102` | Preserved snapshot `0b6150cd413b722951e5c6df41c48814d3e8fb64` | Included |
| Existing shared backend selective patches | `/home/mkooy/src/Stack-team-dev`, base `bc49ae04c2518a689edb4da28d6638b76f9c7d23` | Preserved snapshot `18d03d055d62790035c2625ed7e193757a83de07` | Reconciled: main/integration already includes each applicable override; retained newer structured interview behavior and search projection |
| Full-height photo deck and swipe-to-tailoring | Mac `codex/jobs-photo-deck`, known base `4632bf87817bdd10922d1f7db1bb9d28c0a19dbc` | Unpushed, exact current content unavailable | Pending Mac access; PC renderer is not a replacement for this work |
| Additional memory tailoring | Active `claude/memory-tailoring-20261102` | `ac0cc428da0f31be7963abae6384c9acc3919b0c` plus an untracked helper at inventory | Incomplete work excluded; its typed-memory dependency is included from its owning feature snapshot |
| Older web parity, parser and deployment drafts | PRs #143, #23, #29, #30, #38 | See original PRs | Excluded: unrelated older work; #23 parser superseded by current model import |

## Verification and build boundary

Existing Swift static checks passed for 116 files. `jac check main.jac` passed with warnings.
Existing scoring tests passed 10/10. Further integrated API and backend deployment results are recorded by the integration task.
The integrated `tests/test_simple_coaching.py` API regression passed (1 case, 112.456 seconds, disposable database and mocked provider). It covers exact submitted-answer/feedback pairing, stale revisions, replay, inference failures and account isolation.
The first plain-Python resume check used the wrong interpreter and lacked dependencies; a second runtime check passed 33 cases but could not import Jac for two workflow cases. These are not successful full API runs.

The existing signed TestFlight workflow explicitly requires `refs/heads/main`. It cannot release this branch. No workflow, gate, signing asset or security setting is changed.
After enabling Mac access, preserve its uncommitted work as an exact snapshot, reconcile its native files into this branch, run native tests/build, then use the existing `scripts/ios-phone.sh` route with `STACK_API_URL=https://dev.stackmvp.top`.
Build, installed-app and phone-flow verification remain pending. Do not present this source snapshot as an installable app or complete Mac consolidation.

Backend source preflight passed for 177 candidate runtime files against the unchanged live service (PID 378863, base `bc49ae04`). Deployment is held until the pending Mac snapshot can be paired. No source installation, restart, migration or database write has been performed by this task.
Publishing the integration branch to GitHub was denied by automatic approval review: it considered publishing a new branch an external repository commitment beyond the user's build-only request. The denied command did not execute. No push or PR was created. User-message evidence was checked; no later publication approval was available. Explicit approval is required before retrying that push.
