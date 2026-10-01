# Automatic backend deployment

`Deploy Stack backend` runs on a push to `main`, including a merged PR. It also
supports a manual retry on `main`. It checks out the exact triggering SHA,
builds the existing OpenResume parser with Node 22.22.0 and its npm lockfile,
packages backend source plus the parser bundle, connects an ephemeral hosted
Ubuntu runner to Tailscale, and streams the artifact to a fixed SSH command.

There are no PR test workflows, automated test gates, post-deployment health
gates or automatic rollback. A completed run means the install and restart
commands exited successfully; it does not certify application readiness.

## Current activation state

Prepared only. No deployment account, SSH service/key, Tailscale grant,
GitHub environment variables/secrets, root helper, live restart or live trial
has been configured by this change. Until approved access is configured, a
run fails at the first step with a clear setup message. It does not deploy.

Only `main` runs can reach deployment steps. There is no `pull_request` or
`pull_request_target` trigger and no PC self-hosted runner. Actions are pinned
to exact commit SHAs. Checkout does not persist credentials. Workflow token
permissions are repository read and OIDC issuance for Tailscale federation.

## Scope and retained state

The artifact contains `main.jac`, backend `core`, `agents` and `discovery`
source/data fixtures, the three service entry scripts, parser source and a
built `.jac/resume-parser.cjs`. It derives the server/web Jac configuration
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
2. **WSL SSH endpoint:** install/configure Ubuntu OpenSSH and a non-admin
   `stack-deploy` account. Since Windows owns the existing Tailscale node,
   publish only a new private deployment port (recommended 2222) to WSL SSH,
   bound to Windows' Tailscale address and restricted by tailnet/firewall
   policy. This forwarding/firewall change needs explicit approval. Verify
   current endpoint reachability before enabling the workflow.
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
5. **Host state:** create `/var/lib/stack-release` root-owned mode 0755;
   `incoming/` owned by `stack-deploy` mode 0700; `build/` root:stack mode 0750.
   Create `/etc/stack-release` root-owned mode 0700 and a root-owned 0600
   `access.json` containing `{"automatic_main_deploy":true}` only after approval.
   Generate and review the current source baseline with
   `prepare_source_state.py --artifact <reviewed-artifact> --commit <exact-sha>
   --sha256 <digest> --output <review-file>`; install it as root-owned 0600
   `/var/lib/stack-release/source-state.json`. Inspect differences against
   approved source before trusting the baseline. No credentials are included.
6. **GitHub environment:** configure `stack-production` variables
   `STACK_DEPLOY_HOST`, `STACK_DEPLOY_PORT`, `STACK_TS_CLIENT_ID`, and
   `STACK_TS_AUDIENCE`; secrets `STACK_DEPLOY_SSH_KEY` and
   `STACK_DEPLOY_KNOWN_HOSTS`. Enable with `STACK_DEPLOY_ENABLED=true` last.
   Leave branch-protection/test gates for later as requested. Only activate
   after the endpoint/helper/key and an agreed first deployment window are ready.

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

GitHub Actions is enabled; no self-hosted runners exist. Billing summary
read returned 404 requiring an additional user scope, and the account plan
was not exposed. No token scopes, budget, billing or paid plan were changed.
One hosted Ubuntu job is bounded to 15 minutes, with one-day source artifact
retention and no test matrix/cache. Usage depends on main pushes/retries and
the existing account allowance. Review allowance/spending before activation.

References: [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[Tailscale GitHub Action/federation](https://tailscale.com/docs/integrations/github/github-action).
