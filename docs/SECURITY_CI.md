# Continuous dependency security

GitHub Actions audits dependencies on every pull request, daily at 09:23 UTC,
and on manual dispatch. The backend deployment workflow calls the same audit
workflow for each main commit, even when production deployment is disabled.
Deployment requires that complete workflow to succeed before accessing the
production environment or credentials.

## Checks and policy

- Native npm: validates `native/package.json` against its committed lockfile
  with `npm ci --ignore-scripts`, then audits the locked tree, including dev
  dependencies. No Expo builds, lifecycle hooks, or signing run during audits.
- Web and mobile declarations: generates disposable npm manifests from
  `jac.toml`, merges root/app dependencies, includes npm dev dependencies and
  mobile native declarations, resolves fresh lockfiles, then audits them.
- Python API: audits root runtime dependencies and dev dependencies with transitive resolution.
- Python browser: independently resolves the dependencies in
  `deploy/browser.jac.toml` and `deploy/browser-requirements.txt`.
- Python discovery: independently resolves `discovery/browser-requirements.txt`.
- Policy tests verify fail-closed report handling and the bounded exceptions.

npm high/critical advisories fail; npm low/moderate findings remain visible in
the complete report. All Python advisories fail because pip-audit does not
provide a consistent severity field. Registry errors, timeouts, unsupported
reports and skipped Python packages fail. Scans never run automatic fixes.

The two reviewed npm exceptions in
[dependency-exceptions.json](dependency-exceptions.json) remain visible.
Acceptance requires the exact GHSA identifier, affected package and every
affected locked instance's exact version. Metavulnerabilities propagated to
Expo packages pass only through that accepted advisory evidence; a new direct
advisory on an Expo package still fails. Every exception requires scope,
reason, mitigation, owner and review date. All scans fail **on** the review
date, even if the advisory is no longer reported. Remove obsolete entries or
review and document a justified renewal; do not extend dates to unblock CI
without reviewing the exposure. No Python exception is implied.

The final **Dependency security gate** check fails if any policy job or scan
fails, is cancelled or is skipped. It has no path filters, so unrelated pull
requests still produce the required check. Pull request scans use hosted
runners, a read-only GitHub token, no inherited production secrets, and
checkout with credentials persistence disabled. Action references and the
Python auditor are pinned. Complete audit JSON and generated manifests or
requirements are uploaded for 14 days, including failed audits.

## Dependabot and repository settings

`.github/dependabot.yml` checks npm in `/native`, Python requirements in
`/deploy`, `/discovery` and `/scripts`, and GitHub Actions weekly. Updates
arrive as pull requests and must pass the same security checks. It does not
automatically merge updates.

Dependabot cannot read Jac dependency tables. For root/web/mobile dependencies
and the Jac compiler, update `jac.toml` and the matching browser/example
configuration where applicable; CI regenerates audit inputs from source.
It does not create a second authoritative set of requirements. Fresh
resolution catches vulnerabilities in the versions selected from ranges;
native dependencies are checked against the committed lockfile.

To enforce the PR gate, configure a `main` branch rule with required pull
requests, **Dependency security gate** as a required status check and branches
up to date before merging. Preserve other existing required checks. Enable
the dependency graph, Dependabot alerts and Dependabot security updates in
repository settings. Workflow YAML alone cannot enforce merge protection or
enable these repository switches. Security checks become available when a
pull request first runs this workflow; the daily schedule starts once it is
on the default branch.

## Local reproduction

Use Python 3.12 and Node 22.22.0, matching CI. Install the auditor into a separate
virtual environment:

```sh
python -m pip install -r scripts/security-requirements.txt
python -m unittest discover -s tests -p test_security_audit.py -v
python scripts/security_audit.py exceptions
python scripts/security_audit.py npm native
python scripts/security_audit.py npm web
python scripts/security_audit.py npm mobile
python scripts/security_audit.py python api
python scripts/security_audit.py python browser
python scripts/security_audit.py python discovery
```

Generated inputs, audit reports and native audit installs stay in the ignored
`.jac/security/` directory. The scanner does not change committed dependency
files or use the generated development workspace's packages.

These checks detect published dependency vulnerabilities. They do not inspect
live hosts, container OS packages, CocoaPods, Chromium binaries or bundled Jac
runtime internals, verify deployed versions, or replace code review and runtime
security tests. A dependency upgrade still needs compatibility testing before
it is merged or deployed.
