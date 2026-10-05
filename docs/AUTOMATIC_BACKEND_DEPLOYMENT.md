# Release format 3 migration required

Automatic deployments are paused unless the repository variable
`STACK_RELEASE_FORMAT` is `3`. Keep it unset until the production host has been
migrated and validated. Merging this removal does not update the running host.

The old root-owned receiver requires the generated parser and its package lock;
it also rejects source deletion. Format 3 removes those requirements and the
parser dependency install. The receiver and promoter must be reviewed and
installed separately by the operator, never by release-supplied privileged hooks.

An attended migration must:

1. Keep automatic deployment paused and make a private source backup.
2. Review and install the updated `backend_release.py`, `promote_backend.py` and
   their existing root-owned wrappers/support modules using the host's established
   installation procedure. Keep ownership, permissions and access checks intact.
3. Stop the API/worker/gateway, install the reviewed format 3 payload, and remove
   the retired `agents/resume_parser.jac`, `agents/parse_check.jac`,
   `integrations/resume-parser/` and `.jac/resume-parser.cjs` from the live source.
   Remove any separately staged upstream vendor copies and stale compiled caches.
   Preserve user data, secrets, browser configuration and service definitions.
4. Refresh `/var/lib/stack-release/source-state.json` from the installed manifest
   only after verifying every live source hash and the reviewed removals.
5. Restart services and verify PDF upload/preview, unavailable detail extraction,
   LaTeX processing, and browser readiness. Retain backups privately; a source
   backup or an old deployed copy still contains its original licensed material.
6. Set `STACK_RELEASE_FORMAT=3` only after the host accepts a format 3 release and
   the checks pass. Other deployment approval variables remain required.

The guidance below describes the original format 2 deployment and is retained
for installation context; its parser build requirements are superseded above.

# Automatic backend deployment

The prepared browser extension is documented in
[Automatic isolated-browser deployment](AUTOMATIC_BROWSER_DEPLOYMENT.md).
Its new host authority needs attended approval/bootstrap before activation;
the historical observations below describe the initial backend-only activation.

`Deploy Stack backend` runs on a push to `main`, including a merged PR. It also
supports a manual retry on `main`. It checks out the exact triggering SHA,
packages source-only backend and matching browser source, connects an ephemeral hosted
Ubuntu runner to Tailscale, and streams the artifact to a fixed SSH command.

There are no PR test workflows, automated test gates, post-deployment health
gates or automatic rollback. A completed run means the install and restart
commands exited successfully; it does not certify application readiness.

## Current activation state

On 2026-10-01, the user approved and configured the deployment account/key,
restricted SSH endpoint/helper, main-only GitHub environment, and narrow
Tailscale grant. The user entered the two SSH secrets locally. Both deployment
flags are enabled, and PR #10 was merged into `main`.

The first workflow run and its second attempt stopped at Tailscale OIDC token
exchange with HTTP 403 before SSH transfer. Attempt three passed authentication
and transferred/installed all 68 source files from main commit
`268d6ef20895d58d8d4a70e1e37956b663cdb571`. Its dependency step failed because
the helper's restrictive umask removed group read access from installed files.
An attended correction restored source mode 0640, completed Jac installation,
and restored the API, worker and gateway. Every installed source hash matched
the received artifact before the deployed baseline was updated. Browser remained
running, and data/private configuration were retained. The helper now explicitly
sets source mode 0640 and new source directory mode 0750 after ownership changes.
No application health checks or broad migration tests were run.

Only `main` runs can reach deployment steps. There is no `pull_request` or
`pull_request_target` trigger and no PC self-hosted runner. Actions are pinned
to exact commit SHAs. Checkout does not persist credentials. Workflow token
permissions are repository read and OIDC issuance for Tailscale federation.

## Scope and retained state

The artifact contains `main.jac`, backend `core`, `agents` and `discovery`
source/data fixtures and the three service entry scripts. It derives the server/web Jac configuration
from the repository manifest while excluding iOS build sections.

The helper preserves `/opt/stack/storage`, Jac graph data/cache, private
configuration in `/etc/stack`, service units, browser runtime/container and
sessions, operator authentication, the existing PC `scripts/jac`, and all
Tailscale routes. It does not replace all of `/opt/stack` or delete data.
Web frontend assets and the signed iPhone app are outside this backend release.
Changing them still needs their separate build/deployment flow.

The host checks incoming digest/commit, a restricted source path list and
source hashes against the last deployed baseline. Unexpected local source
changes and source-file deletions stop deployment for attended review.
These checks protect local work and the privileged transfer, rather than
testing application behavior. Dependencies install as `stack`, never root;
parser dependencies are prepared in a new directory before services stop.

Deployments serialize in GitHub and with a host file lock. The helper keeps a
private source/dependency backup, stops gateway/worker/API, installs source,
installs Jac dependencies with the existing pinned Jac 0.37.21, and starts
API/worker/gateway. Browser/Docker services are unaffected. Ordinary command
failures fail the run; an interrupted install can leave application services
stopped until an attended correction. There is no automatic database restore.

## One-time approval bundle

Approve the following together before activation. Do not put private keys or
credentials in this repository, chat, artifacts or command output.

1. **Hosted runner to private host:** create a Tailscale federated identity
   restricted to this repository, `refs/heads/main`, and environment
   `stack-production`. Grant ephemeral `tag:stack-deploy` nodes access only to
   Ryans-Desktop's designated deployment TCP port. Keep existing HTTPS 8443,
   browser routes and other tailnet grants unchanged. Use OIDC federation;
   there is no need for a reusable Tailscale authentication secret.
   Use the exact issuer subject reported by Tailscale's token-exchange
   diagnostic, rather than assuming the older name-only GitHub subject format.
   For this repository/environment the observed subject was:
   `repo:matthewkooy2@197636470/Stack@1391512975:environment:stack-production`.
   It includes immutable account/repository IDs even though GitHub's repository
   subject customization reports `use_default=true`. Keep the issuer
   `https://token.actions.githubusercontent.com` and custom claim
   `ref = refs/heads/main`. Restrict the credential's auth-key write permission
   to exactly `tag:stack-deploy`; do not replace this restriction with a wildcard.
2. **WSL SSH endpoint:** install/configure Ubuntu OpenSSH and a non-admin
   `stack-deploy` account. Since Windows owns the existing Tailscale node,
   publish only a new private deployment port (recommended 2222) to WSL SSH,
   bound to Windows' Tailscale address and restricted by tailnet/firewall
   policy. This forwarding/firewall change needs explicit approval. Verify
   current endpoint reachability before enabling the workflow.
   This PC uses SSH on WSL `127.0.0.1:2223`, forwarded privately with
   `tailscale serve --bg --tcp=2222 --yes tcp://127.0.0.1:2223` on Windows.
   Existing Serve routes, including HTTPS 8443, were retained. The workflow
   uses `ssh -4` to match the IPv4-only destination grant and keeps the pinned
   `[ryans-desktop.tailfe312e.ts.net]:2222` host-key identity.
3. **Fixed SSH key:** create a dedicated deployment key. Its authorized-key
   entry must use `restrict,command="/usr/bin/python3 -E -s /usr/local/libexec/stack-release/receive_backend.py"`.
   Disable password login, interactive shell, forwarding and PTY for this
   account/key. Retain the existing operator access. Pin the SSH host key
   obtained locally on the host; never trust network `ssh-keyscan` alone.
4. **Narrow privileged helper:** install the four reviewed files
   `backend_release.py`, `receive_backend.py`, `promote_backend.py` and
   `promote-backend` in `/usr/local/libexec/stack-release`, root-owned and
   unwritable by `stack-deploy`/`stack`. Grant sudo only for
   `/usr/local/libexec/stack-release/promote-backend` **with no arguments**
   (sudoers command argument specification `""`). No blanket root/sudo grant.
   This helper may replace allowlisted application source and control only
   `stack-api`, `stack-worker`, and `stack-gateway`; it runs package tools as
   `stack`. Approving it authorizes future merged backend code to execute as
   the existing Stack service user, including that user's existing access.
   The existing `/usr/local/libexec` parent is private; this PC grants only
   directory traversal to `stack-deploy` with a named ACL. Helper files remain
   root-owned and unwritable by service/deployment accounts. The launcher uses
   the existing root-owned `/usr/local/bin` Node/npm tools and explicitly selects
   `/usr/local/bin/jac`, matching the existing application units.
5. **Host state:** create `/var/lib/stack-release` root-owned mode 0755;
   `incoming/` owned by `stack-deploy` mode 0700; `build/` root:stack mode 0750.
   Create `/etc/stack-release` root-owned mode 0700 and a root-owned 0600
   `access.json` containing `{"automatic_main_deploy":true}` only after approval.
   Generate and review the current source baseline with
   `prepare_source_state.py --artifact <reviewed-artifact> --commit <exact-sha>
   --sha256 <digest> --output <review-file>`; install it as root-owned 0600
   `/var/lib/stack-release/source-state.json`. Inspect differences against
   approved source before trusting the baseline. No credentials are included.
6. **GitHub environment:** configure `stack-production` secrets
   `STACK_DEPLOY_HOST`, `STACK_TS_CLIENT_ID`, `STACK_TS_AUDIENCE`,
   `STACK_DEPLOY_SSH_KEY`, and `STACK_DEPLOY_KNOWN_HOSTS`. Keep
   `STACK_DEPLOY_PORT` as a variable. Secrets mask the private hostname and
   identity values even in the runner's pre-step environment listing; the
   approval step also masks the short hostname before Tailscale or SSH runs.
   Do not duplicate these three private values in plain environment variables.
   Enable with `STACK_DEPLOY_ENABLED=true` last.
   Leave branch-protection/test gates for later as requested. Only activate
   after the endpoint/helper/key and an agreed first deployment window are ready.

The saved network grant preserves `autogroup:member` access to all existing
destinations/protocols. The separate `tag:stack-deploy` grant permits only
`100.102.193.64` with `ip: ["tcp:2222"]`. Current status listed three personal
devices and no tagged devices before activation. The existing SSH and
`nodeAttrs` rules were retained. `tagOwners: {"tag:stack-deploy": []}` is valid;
tailnet administrators implicitly own tags, so no additional owner grant was
needed. Future tagged services require their own intended access policy.

## OIDC troubleshooting

Open the Tailscale Trust credentials entry named in the failed action's error
and inspect its latest token-exchange diagnostic. A `Cannot validate subject`
error shows the received subject; copy that exact public value into the Subject
field. Do not weaken the `ref` claim to resolve a subject mismatch. If another
HTTP 403 follows, inspect the updated diagnostic before retrying: subject,
issuer, audience and custom claims are independently checked. Neither token
values nor private keys are needed in chat or logs for this diagnosis.

This is a persistent deployment grant. It is deliberately narrower than an
interactive administrator login, but anyone authorized to change `main` or
the workflow can deploy backend code. Revoke by disabling the workflow flag,
removing the dedicated SSH key, or setting the host access flag to false.

## PC availability and cost

Read-only observation on 2026-10-01: Ubuntu systemd is enabled and Stack,
browser and Docker units are enabled. Windows Tailscale is running with
automatic startup. AC sleep is disabled; DC sleep is 900 seconds. WSL SSH
is not installed. Scheduled-task enumeration was access-denied, so a WSL
boot task and unattended cold-boot availability are **unverified**. WSL
systemd enabled units start only once the distro starts. Power/network/boot
settings were not changed. Confirm an approved startup/forwarding strategy
before expecting deployments after reboot; avoid advertising always-on uptime.
After the approved setup, SSH is installed/enabled on WSL loopback and Windows
Serve forwards private TCP 2222 to it. Unattended cold-boot availability remains
unverified; no power or boot policy changes were made.

GitHub Actions is enabled; no self-hosted runners exist. Billing summary
read returned 404 requiring an additional user scope, and the account plan
was not exposed. No token scopes, budget, billing or paid plan were changed.
One hosted Ubuntu job is bounded to 15 minutes, with one-day source artifact
retention and no test matrix/cache. Usage depends on main pushes/retries and
the existing account allowance. Review allowance/spending before activation.
The user subsequently confirmed the Actions budget displays $0 budget,
$0 spent and Stop usage Yes. That paid-usage cap was preserved. Remaining
included minutes were not shown. The first two attempts ran within the existing
allowance; the timing API reported zero billable milliseconds. If a future run
is blocked for exhausted allowance, report it rather than enabling paid usage.

References: [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[Tailscale GitHub Action/federation](https://tailscale.com/docs/integrations/github/github-action).
