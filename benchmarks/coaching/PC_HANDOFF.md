# PC coaching benchmark handoff

## Outcome and authority

Matt requested the benchmark and explicitly asked to dispatch its execution to a
new chat on the PC so his only remaining work is setting up API keys. Prepare the
PC environment, run the provider comparisons when keys are available, investigate
runner/API compatibility failures, and report the evidence-backed model choice.
Do not ask Matt to transfer files, install packages manually, or assemble data.
Do not merge, deploy, change Stack's production AI provider, alter CI, or create
Linear issues as part of this task.

## Transfer and ownership

- Repository: `https://github.com/matthewkooy2/Stack.git`.
- Branch: `codex/ai-coaching-benchmark`, based on `859fa64`.
- Mac worktree: `/Volumes/DevSSD/Projects/Developer/Stack/worktrees/ai-coaching-benchmark`.
- PC project: `E:/Projects/Developer/stack` on `Ryans-Desktop`.
- Owned changes: `benchmarks/coaching/` only; preserve all other work and local state.
- This checkpoint is included with the benchmark commit. Use the full candidate
  SHA in the dispatch prompt and verify it after fetching; do not assume a branch
  tip remains unchanged. The portable benchmark can run outside the app checkout.
- Root `AGENTS.md` records the Stack account routing. No Linear operations are needed.

## Already complete

- 66 cases representing 60 distinct questions: 24 behavioral, 36 technical, six
  meaning-preserving variants, provisional expected scores and review guidance.
- Four cheap API adapters, repeated calls, spending estimates, failure accounting,
  manifest-protected resumes, cross-provider judges, and blinded review artifacts.
- Twelve offline tests passed on macOS; archive extraction also passed validation
  and all twelve tests. These used simulated provider responses, not live results.
- Baseline documentation, key names, Windows commands, and model prices are in
  `README.md`; evidence boundaries are in `VALIDATION.md`.

## Next action on the PC

Inspect PC project instructions and local changes first. Fetch the exact published
candidate and stage a separate benchmark checkout/folder without disturbing other
tasks. Validate the dataset, run the twelve tests, and prepare a secure way for Matt
to configure `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `GEMINI_API_KEY` locally.
Never ask him to paste keys into chat or expose key values in logs. Re-read
persistent user environment variables in a fresh process after setup: a running
agent may have inherited an older environment.

Then run per-provider smoke tests, the complete 792-request comparison (66 cases,
four candidates, three repeats), and semantic reviews of the first repeat.
Use the documented $5 candidate allowance and $25 combined candidate/judge stop
estimate; do not increase those without asking Matt. Verify live usage against
provider billing because application estimates are not invoice guarantees.

If keys are absent, complete all independent preparation and make key setup the
only user action. Continue automatically when keys become available if the local
tools support it; do not imply that an idle task watches keys unless a real watcher
or scheduled continuation has been configured. Preserve resumable task/run state.

## Acceptance and limitations

No live provider benchmark has run yet. Model access, current API dialects, Windows
execution, actual latency/cost, and coaching quality remain unverified. Use current
official docs to correct API incompatibilities, rerun affected offline tests, and
start a fresh manifest directory after protocol changes. Do not mix versions or
silently replace unavailable models.

Compare equivalent coverage, invalid responses, reference agreement, exact quotes,
per-track results, repeat/variant stability, semantic correctness/actionability,
latency and production inference cost. Review critical issues and a common blinded
sample; cross-provider judges differ across candidates, so their raw averages are
not a standalone ranking. Synthetic author judgments are provisional, not human
gold. Keep failures and uncertainty visible. Deliver the measured comparison and
a reasoned recommendation, without changing the production backend.
