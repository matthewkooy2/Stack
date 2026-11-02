# Combined review including whole-memory tailoring

Owner: PC consolidation task `01a19c86-bf28-71fb-93f8-208413d060fe`.
Target: `https://dev.stackmvp.top`. Feature PRs and main remain unchanged.

| Source | Exact revision | Included |
| --- | --- | --- |
| Original PC review snapshot | `1080080715fa1e422b9cb799600668c4ce5aa6f0` | Current main, Gmail, scoring, parser/schema prompt, simplified Prep, typed memory, templates, job details and media |
| Verified Mac combined snapshot | `8eaf13b32f60f714d745975b43a3d8da37abd030` | Full-height cards, native photo/logo resources, swipes, saved-job tailoring handoff |
| Claude whole-memory tailoring PR #161 | `e7f299cf941b4318be4c675afe1d1602cf94d033` | Memory reader, chunk screening, factual checks, review actions, interview grounding, context handling |
| Combined integration | `661176c11da014db1c481930e81825b6898721b3` | Resolved import conflict; legacy free-text story sources retain their exact body when no typed fields were supplied |
| Jobs recovery correction | `826ade5ff9d99b48d34277cfd3962b745dec95c3` | Recheck an exhausted deck when returning, even after today's sweep started; malformed jobs payloads raise an error |

The prior build `2026.11.2` was reported installed/launched from `8eaf13b`. It does
not contain Claude tailoring or the Jobs correction. A new signed build is required.
There is no install receipt for this final source yet. Direct Mac execution remains
unavailable to this task; existing signed CI accepts main only and is unchanged.

## Jobs findings

Read-only live metadata showed 6,553 catalog rows, 6,544 active. The restrictive
stored search had nine active matches and three matching saved/pass decisions,
leaving six undecided. Other stored fixture searches had 4,656 matches. No decisions
or preferences were cleared. This establishes available data, not the exact earlier
phone state. The client could retain an exhausted deck after a sweep completed later
in the same day; returning now rechecks it. Successful malformed responses can no
longer silently become an empty deck.

## Backend pairing

Use the exact final commit recorded in `integration-checkpoint.json`. Deploy all
179 runtime files from that source together; never reuse the older `8eaf13b` package.
The integration task prepares source/private-config hashes, idle checks, backup and
source-only rollback. Preserve data, uploads, auth and secrets. Change only the two
ordinary context values to 65,536: `local_model_context_tokens` and
`model_options.local.local_model_context_tokens`. NInfer already reports 65,536 and
serves the existing `qwen3.8-27b-ninfer`; no weights, provider or network change.
Check fresh agent/resume work, daily sweep and NInfer running/waiting counters
immediately before the brief shared-service restart. Read deployment and verification
results from the task checkpoint; this source document is not proof of deployment.

## Verification and Mac action

Integrated compiler/static checks and 12 tailoring unit cases passed. All four
stand-in tailoring API workflows passed. Story API checks passed after the legacy
compatibility correction (one optional real-model story case skipped). Detailed
scoring, Prep, final native checks and deployment results are recorded by the task.
PR #161 separately records four real-Qwen workflows; those are source-branch evidence.
The added native behavior cases require Mac XCTest execution; Windows static checks
do not establish that they passed.

On the authorized Mac, preserve existing edits, fetch the review branch and create
an isolated worktree at its exact published head. Run the existing affected native
checks, including JobDeckFeedTests and TaskDetail review labels, then build/install:

```sh
STACK_API_URL=https://dev.stackmvp.top STACK_BUILD_NUMBER=2026.11.3 scripts/ios-phone.sh
```

Record source SHA, bundle version, endpoint, build result, install/launch receipt,
and the first/cursor feed and save-to-tailoring results. Use another available build
number if 2026.11.3 has already been used. Do not merge main or alter signing policy.
