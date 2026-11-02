# Commit and PR titles

Source: the user's `personal-commit-style/SKILL.md`, verified in
`E:/Projects/Developer/agent-os/skills` and `C:/Users/Ryan/.codex/skills`.
Use `type<scope>: outcome`, a lowercase subject without a final period.
Example: `fix<coaching>: show qwen output without validation`.
Describe the final diff and actual verification. Omit decorative emoji,
em/en dashes, signatures and model/coauthor attribution. Keep the configured
Git author. The checker validates syntax; reviewers assess wording and evidence.

## Performance evidence in every PR description

Every PR description must include a **Performance** section. Report measured
before/after timings for the affected runtime operations so load-time and
responsiveness regressions are visible. A claim such as "fast" or "no impact"
without evidence is insufficient. For prose-only or other changes with no
runtime effect, write `N/A` and explain why; do not invent measurements.

- **Backend-only PRs:** report backend timings for the affected endpoints or
  jobs. Define the measurement boundary: server request handling, database work,
  queue wait, model/provider work, or request-to-persisted-result for an async
  job. Report a fast enqueue acknowledgement separately from time until the
  result is ready. Browser rendering and iPhone timing are not required for
  backend-only acceptance. If only client-observed RPC time is available, label
  it as including transport; do not present it as server-only time.
- **Web/iOS PRs:** measure the affected client load or interaction and any
  relevant API wait separately. Measure only the changed paths. Native checks
  remain necessary for native claims.
- Use the same fixtures, data size, environment, provider/model and load
  conditions for baseline and candidate. Include tested SHAs, units, sample
  counts, raw timings or linked evidence, median and range; separate cold/startup
  and warm/cache runs when applicable. For repeatable local/read-only work,
  collect five runs. Disclose smaller samples and their reason, especially for
  real external actions; do not repeat sends or submissions just to benchmark.
  Include p95 only with a disclosed sample count and enough observations to
  support it.
- Include failures/timeouts and explain regressions. If no comparable baseline
  exists, report candidate timings and the specific baseline limitation.
  Missing evidence must remain explicit; it is not a passing result. For
  optimization work, state the target and rationale from the baseline and compare
  the measured outcome.

These are author-provided PR evidence requirements. They do not add CI jobs,
required checks, latency gates or branch rules. Use the repository PR template
and keep the evidence current when the measured implementation changes.

## Merging

Verify the current head, current-base acceptance, CI, conflicts, required reviews
and unresolved findings. Pass the reviewed head SHA to the merge operation.
Use an explicit styled commit title and body, regardless of merge method.
GitHub's default `Merge pull request #...` subject does not follow this policy.
Rebase preserves every source commit subject; a merge commit preserves all source
subjects plus its merge subject. Squash permits an explicit styled final subject
but still requires complete review of the source changes.

For example, after all readiness gates pass:

```powershell
gh pr merge <number> --squash --match-head-commit <reviewed-sha> --subject 'fix<scope>: concrete outcome' --body-file <reviewed-body-file>
```

Check the actual resulting commit subject and body after merging. Do not use
automatic default messages or automatic attribution. Repository merge settings
can change and must be inspected when selecting a merge method.

The `Commit style` check inspects PR titles and introduced commits, including
merge commits, new main commits and coauthor trailers. It does not repair historical messages.
Making the check required needs a separately approved branch rule. A passing
check cannot prove that a future GitHub-generated merge message will comply;
the explicit merge message and post-merge verification remain necessary.

## Draft lifecycle

Reuse the issue's existing PR. An initial draft is useful while work or acceptance
is incomplete. Keep its description current with the candidate SHA, verification,
owner and concrete remaining gates. Mark ready only after all requested acceptance
and review pass for the current head and applicable base. Green CI alone is not
acceptance. Resolve conflicts and repeat affected verification first.

For a redundant PR, compare its entire diff with delivered main changes, identify
remaining unique work and confirm the owning task's disposition before closing.
Preserve its branch. Do not bulk close drafts or mark blocked work ready to reduce
the draft count. History rewrites require a coordinated plan and explicit approval.
