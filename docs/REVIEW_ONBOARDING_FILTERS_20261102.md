# Review build with onboarding and Jobs filters

Base: published review commit `e43a17ccaf8208d71c5f79cc50a1e12c43ba1ace`.
Branch: `codex/review-onboarding-filters-20261102`.
Target: `https://dev.stackmvp.top`, build `2026.11.3`.

Includes the selected onboarding C and Jobs filters C implementation preserved in
`ios-onboarding-job-filters`: optional role/location setup, the fixed O*NET title
list, Apple Maps location suggestions, and focused filter editors. The Jobs filter
actions stay at the bottom, and controls remain available during feed loading.
The existing local Jobs recovery correction from `69c8c53` is included.

New accounts receive onboarding. Existing accounts can use the debug handle's
Preview > Job onboarding; that preview uses the offline fixture account. The Jobs
filter button edits the signed-in account's real search.

Existing Swift structural checks passed for 120 files. The 59 existing Jobs card,
cache, feed and filter model cases passed in a temporary Mac host harness using
the current model source; resource lookups use the host package bundle. This does
not establish native layout or live API acceptance. No simulator or automated
phone UI interactions were run. Phone build/install evidence is stored under
`.jac/ci-ios-device`, outside the source commit.

The phone build embeds its exact source commit. Its debug launch writes
`tmp/stack-build-receipt.json` in the app container with the commit, build number,
and API origin for on-device readback. The backend and main are unchanged.
