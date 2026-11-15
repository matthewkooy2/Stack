# Consolidated review snapshot, November 2

This historical PC snapshot is superseded by [the combined tailoring review](CONSOLIDATED_TAILORING_REVIEW_20261102.md), which includes the verified Mac source and Claude PR #161.

Owner: Consolidate Stack review build (PC task `01a19c86-bf28-71fb-93f8-208413d060fe`).
PC base: `codex/consolidated-review-20261102` at `1080080715fa1e422b9cb799600668c4ce5aa6f0`.
Final Mac branch: `codex/consolidated-review-mac-20261102`. Backend target: `https://dev.stackmvp.top`.
Mac owner: Simplify Gmail application setup, chat `01a19c1b-a3c5-7f70-9e43-06c7665fd040`.
Original feature branches and PRs are preserved. No feature PR is merged by this task.

| Change | Source owner / branch | Exact source commit | Decision |
| --- | --- | --- | --- |
| Current main, including Gmail #159, scoring #158, Google/native resume #156/#157 and parser #152 | Repository main | `a1b1cd4540320c8890216490ca3b9eea6e6e4198` | Included as baseline |
| Resume model schema prompt #160 | Fix shared resume parser / `codex/resume-schema-prompt-20261102` | `6d81191d5cc843d9c606ba0e2730acb53f988a59` | Included |
| Reviewed-answer Prep coaching | Simplify Stack coaching flow / `codex/simple-coaching-20261102` | `16fd8e0864fe39fc0d8eb26e63080c1d12e3c8b4` | Included; Google routes retained in conflict resolution |
| Typed memory entries, fields and attachments | Add typed memory bank entries / `codex/typed-memory-bank-20261102` | Preserved snapshot `4b719a5d3946e9bec4eaccc22e58f5a4af6f658d` | Included; source worktree untouched |
| Posting extraction, accurate details, employer logos, location photos and existing PC card renderer | Fix missing job card details / `codex/job-card-source-details` | Preserved snapshot `6265cefc05bcb8fa7083b56addc510316298f7d1` | Backend/media included; native renderer reconciled with the Mac snapshot below |
| Five additional resume templates and native format picker | Find popular open-source LaTeX resumes / `codex/resume-template-library-20261102` | Preserved snapshot `0b6150cd413b722951e5c6df41c48814d3e8fb64` | Included |
| Existing shared backend selective patches | `/home/mkooy/src/Stack-team-dev`, base `bc49ae04c2518a689edb4da28d6638b76f9c7d23` | Preserved snapshot `18d03d055d62790035c2625ed7e193757a83de07` | Reconciled: main/integration already includes each applicable override; retained newer structured interview behavior and search projection |
| Full-height photo deck, media/cache consumers and refined swipe motion | Generate three Stack UI candidates / Mac `codex/jobs-photo-deck`, base `4632bf87817bdd10922d1f7db1bb9d28c0a19dbc` | Exact preserved snapshot `a5059d4b1210a32ae591406e9cf22eedd981264e`; reconciled import `4f1819a` | Included. Backend extraction, bundled photos, page-level logo map, feed and persistent cache already match the PC base; native photo/brand consumers and latest full-height renderer retained |
| Saved-job tailoring handoff | Final Mac integration | Final commit containing this manifest | Completed in isolation: offer Tailor resume after confirmed save, retain the exact application ID while browsing, select the default resume and support PDF upload when none exists |
| Older Mac resume/review and Prep variants | Preserved `origin-main` and `iphone-shared-dev` working copies | Inventory below | Compared, not overlaid: base already includes the resume design with newer keyboard/review fixes, typed memory and reviewed-answer Prep. Retained those newer independent changes |
| Older onboarding, LinkedIn preview and checkpoint work | Other dirty Mac worktrees | Inventory below | Preserved unchanged; excluded as unrelated to this review integration |
| Additional memory tailoring | Active `claude/memory-tailoring-20261102` | `ac0cc428da0f31be7963abae6384c9acc3919b0c` plus an untracked helper at inventory | Incomplete work excluded; its typed-memory dependency is included from its owning feature snapshot |
| Older web parity, parser and deployment drafts | PRs #143, #23, #29, #30, #38 | See original PRs | Excluded: unrelated older work; #23 parser superseded by current model import |

## Verification and build boundary

Existing Swift static checks passed for 116 files. `jac check main.jac` passed with warnings.
Existing scoring tests passed 10/10. Further integrated API and backend deployment results are recorded by the integration task.
The integrated `tests/test_simple_coaching.py` API regression passed (1 case, 112.456 seconds, disposable database and mocked provider). It covers exact submitted-answer/feedback pairing, stale revisions, replay, inference failures and account isolation.
The first plain-Python resume check used the wrong interpreter and lacked dependencies; a second runtime check passed 33 cases but could not import Jac for two workflow cases. These are not successful full API runs.

The existing signed TestFlight workflow explicitly requires `refs/heads/main`. It cannot release this branch. No workflow, gate, signing asset or security setting is changed.
The Mac reconciliation is complete. Run the existing `scripts/ios-phone.sh` route with
`STACK_API_URL=https://dev.stackmvp.top STACK_BUILD_NUMBER=2026.11.2` from the final Mac branch.
The script's optional build number override does not change signing, CI or release policy.
Actual installation and backend pairing evidence are recorded outside the source commit to avoid a self-referential commit ID.

Backend source preflight passed for 177 candidate runtime files against the unchanged live service (PID 378863, base `bc49ae04`). Deployment is held until the pending Mac snapshot can be paired. No source installation, restart, migration or database write has been performed by this task.
The original publication attempt was denied by automatic approval review. The PC owner subsequently published the explicitly approved base at `1080080`. The Mac finalization does not rely on permission to publish another branch: its exact final commit can be transferred privately as a checksum-verified Git bundle.

## Mac preservation inventory

All original worktrees were inventoried before integration. Binary full-index patches and raw untracked source bytes were saved under the private directory `/private/tmp/stack-review-mac-preserve-20261102-0hoinf9m` (mode 0700), with individual file SHA256 values. No ignored credentials, database, uploads or runtime configuration were copied. Inventory manifest SHA256: `ba4bbd8a99fad50b9e3713b21b15e3fcd935bd04d0efda77971d81b3c4edd301`.

| Dirty worktree | Original full HEAD | Tracked patch SHA256 |
| --- | --- | --- |
| `jobs-photo-deck` | `4632bf87817bdd10922d1f7db1bb9d28c0a19dbc` | `50e9b3c95a71727191d183d5277718e7c03d49405b0ba4170fc327337b2c1983` |
| `origin-main` | `8cc6d803eaaf971888c4ca225eaae35a2c53cae2` | `35436a6e035679557657fc1ccf846c1a4e7c63992b7890493d5191e58cbce123` |
| `iphone-shared-dev` | `85c622b9b1ffc62bbdfbff6e7d8b35e76019d3ef` | `5c527f96f99a3f9756d8293086ad10efb8ab80ab56a395e49be443adef7d7d0d` |
| `ios-onboarding-job-filters` | `a1995a7a4887c1fc731c0ecfa569525823a6f53c` | `5db18bd765e4c22b9f12e34f35b8c7fe5478f50a5164193086517f413fba3c6b` |
| `linkedin-ui-flow` | `4cdee4a0adaf223eb29b393847d3973aa338b5cc` | `1f97014be26211938a108f3b6af36715c998915679dd592eb77b144fcb9563e5` |
| `linkedin-rework` | `b63f784c5e4d4d5bc9afbb38905a76b3465f9083` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (untracked checkpoint only) |

The 138-file job-deck capture was imported and byte-verified in `codex/mac-jobs-snapshot-20261102`, then cherry-picked into a separate `worktrees/consolidated-review-mac-20261102` checkout. No original worktree was reset, stashed or cleaned.

## Mac affected verification

- Existing Swift static checks: 118 files passed; shell syntax and `git diff --check` passed.
- Existing media/discovery/matching/branding/photo tests: 52 passed in 0.664 seconds.
- Existing job-card, cache and paging XCTest cases: 31 passed on the Mac in 2.560 seconds using a temporary host harness. It copies the source models, extracts the view-independent card/request-gate logic, and adapts `Bundle.main` to the Swift package resource bundle. This is model evidence, not iPhone UI acceptance.
- `jac check main.jac`: passed in 38.65 seconds with existing type warnings. No backend runtime source changed from `1080080` during Mac integration.
- Signed physical-device app and existing test targets compile with Xcode 27.0 (27A266a), XcodeGen 2.46.0. The built app includes 55 photos and both media JSON contracts, with the review endpoint and build number above.
- No simulator or automated phone UI tasks were run. Device interaction acceptance remains manual, following the user's instruction to stop phone automation.
- The PC backend owner is Diagnose iOS roles and jobs, chat `01a19a1c-ee3b-7782-b5d1-243265e6c5bd`. Pairing uses the exact final Mac commit, regenerated archive, fresh live-source/settings fingerprints and source rollback; never a database restore.
