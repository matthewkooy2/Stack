# Commit and PR titles

Source: the user's `personal-commit-style/SKILL.md`, verified in
`E:/Projects/Developer/agent-os/skills` and `C:/Users/Ryan/.codex/skills`.
Use `type<scope>: outcome`, a lowercase subject without a final period.
Example: `fix<coaching>: show qwen output without validation`.
Describe the final diff and actual verification. Omit decorative emoji,
em/en dashes, signatures and model/coauthor attribution. Keep the configured
Git author. The checker validates syntax; reviewers assess wording and evidence.

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
merge commits, and new main commits. It does not repair historical messages.
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
