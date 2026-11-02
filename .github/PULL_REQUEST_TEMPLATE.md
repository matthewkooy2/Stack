## Summary

Describe the concrete problem and resulting behavior. Link the issue and dependencies.

## Verification

- Tested head/base SHAs and environment/configuration:
- Reproduction steps and observed results:
- Checks run, results and elapsed time:
- Backend verified:
- iOS verified or pending (link remaining acceptance):
- Material gaps or untested integrations:

## Performance

Required for every PR. See [performance evidence guidance](https://github.com/matthewkooy2/Stack/blob/main/docs/COMMIT_STYLE.md#performance-evidence-in-every-pr-description).
For changes with no runtime effect, replace the table with **N/A** and a concrete reason.

Backend-only PRs report the affected backend endpoint/job timings; browser rendering and iPhone timings are not required.
Separate server work from transport, and async enqueue time from time until the result is persisted and ready.

| Operation and measurement boundary | Baseline (ms/s) | Candidate (ms/s) | Runs; cold/warm state | Failures/timeouts |
| --- | --- | --- | --- | --- |
| | | | | |

- Baseline/candidate SHAs, fixtures/data size, environment, provider/model and load conditions:
- Raw timings or evidence; median/range and observed change:
- Target and rationale for optimization work; regressions or baseline limitations:

For repeatable local/read-only timings use five runs. Disclose smaller samples and why; do not repeat real external actions for a benchmark.
Only include p95 with a disclosed, adequate sample count.
