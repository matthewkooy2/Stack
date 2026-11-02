# Shared development through Cloudflare Tunnel

Use one isolated Stack development backend for teammates' app accounts, uploads,
and MVP testing. Cloudflare publishes only the normal app gateway over HTTPS;
teammates do not install Tailscale. PostgreSQL, the raw Jac API, storage files,
admin RPCs and worker services remain private. Resume metadata is written through
the API to the account's database graph; original PDFs and generated artifacts
live in private server storage. A SQL login is not needed for this flow.

This is PC hosting with a tunnel, not a cloud migration. The PC, WSL, Stack and
`cloudflared` must stay running. This runbook and the example configuration do not
create a tunnel, change DNS, grant access, install services or activate on merge.
Do not publish the personal Stack instance or reuse its database, uploads, keys,
provider login or completed environment files.

## Confirm before activation

The maintainer must obtain approval for the exact account, hostname, access and
data boundary before running provisioning or activation commands below:

- Cloudflare account and a domain/zone controlled by that account; the public
  hostname, such as `stack-dev.example.com`.
- A new isolated development clone and fresh database/storage containing only
  synthetic data and data teammates deliberately upload to this environment.
- Named teammates who will receive their own Stack accounts and invitations;
  which maintainers can access the host, private data and backups.
- Stack username/password authentication and invite admission for the initial
  web/native MVP. A Cloudflare browser-login challenge is not added to the API:
  it would require a separate authentication integration in the native client.
- Installation/authentication of the connector, tunnel credential creation, DNS
  routing and starting the public connection. Check current Cloudflare plan
  eligibility, limits and any cost before accepting a charge.

No raw SQL endpoint, SQL editor or teammate database credentials are part of this
setup. Do not add public port 5432 or a route to the raw Jac API. If SQL access is
requested later, treat that as a separate access decision.

## Prepare the isolated backend

After approval, use a new clone inside the Linux/WSL filesystem, following
[local contributor prerequisites](LOCAL_DEVELOPMENT.md). For example:

```sh
mkdir -p ~/src
git clone https://github.com/matthewkooy2/Stack.git ~/src/Stack-team-dev
cd ~/src/Stack-team-dev
# Select the agreed shared development revision before setup.
make setup
```

Setup creates this clone's own ignored `.jac` database/runtime and `storage/`
configuration. Do not copy or symlink either from another instance. Do not use
`scripts/worktree-dev.py` to populate this environment: that personal-preview
workflow can copy personal account data. Do not override `JAC_DB_URL` to point at
an existing database. The contributor launcher clears inherited deployment
configuration and uses the clone-local database.

Before starting the new instance, edit only its ignored
`storage/agents/config.json`: set `invite_only` to `true` and `web_url` to the
approved HTTPS origin. Retain disabled spending/outbound actions and leave model
providers and optional integrations unconfigured initially. Keep this completed
file private. Enable a provider only during a separately approved provider test;
ordinary upload/storage verification needs no model, Qwen or GPU workload.

Use separate loopback ports and confirm they are free; these example values are
not a reservation. Do not stop an existing service to free them:

```sh
python3 scripts/contributor.py doctor --api-port 18082 --web-port 18081
python3 scripts/contributor.py dev --api-port 18082 --web-port 18081
```

Leave the launcher running. The gateway is `http://127.0.0.1:18081`; the single
Jac API writer is `http://127.0.0.1:18082`. Do not use `--expose` or bind either to
`0.0.0.0`. The connector must run in this same Linux/WSL environment so its
loopback upstream reaches this gateway. Core workers are supervised by the
contributor launcher; optional browser integrations are separate setup.

Generate invitations locally with the existing operator command, after approval
of the recipients, from the new clone in another terminal:

```sh
STACK_WORKER_API=http://127.0.0.1:18082 \
  ./scripts/jac run --no-serve scripts/agent-admin.jac invite
```

This uses the new clone's worker-token file, never a teammate-supplied worker
credential. Treat the returned invitation as private and distribute it only by
an approved channel. Teammates create their own Stack accounts and accept their
invitations. Account ownership checks still apply after admission; invitations
are not shared login credentials.

## Configure and validate the tunnel

After approval, install `cloudflared` using Cloudflare's supported instructions
in the Linux/WSL environment. Follow the official [locally managed tunnel
setup](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/)
to authenticate and create a tunnel named `stack-team-dev`. Its login certificate
and tunnel JSON credentials stay outside Git and must be readable only by the
operator/connector identity. Do not paste them into chat, PRs or client builds.

Copy [the tunnel example](../deploy/cloudflare/config.example.yml) to
`~/.cloudflared/stack-team-dev.yml`. Replace its placeholder UUID, absolute
credentials-file path and hostname. Keep the gateway port aligned with the
isolated launcher. Do not point it at the personal backend, raw API or database.
The final `http_status:404` rule rejects unmatched hostnames.

Validate without opening a connection:

```sh
cloudflared tunnel --config ~/.cloudflared/stack-team-dev.yml ingress validate
cloudflared tunnel --config ~/.cloudflared/stack-team-dev.yml ingress rule https://stack-dev.example.com/
cloudflared tunnel --config ~/.cloudflared/stack-team-dev.yml ingress rule https://unmatched.example.com/
```

The approved hostname must match the gateway rule; the unmatched hostname must
match the final 404 rule. Local validation does not certify authentication or
public reachability. Review the completed routing and confirm that the isolated
instance has `invite_only: true` before the activation step.

## Activate only after the exact action is approved

The following commands change public routing/start external exposure. Present the
actual hostname, tunnel, upstream and authentication/data boundary for approval
immediately before executing them; placeholders are not approval:

```sh
cloudflared tunnel route dns TUNNEL_UUID stack-dev.example.com
cloudflared tunnel --config ~/.cloudflared/stack-team-dev.yml run TUNNEL_UUID
```

No router port forwarding, LAN firewall opening, Tailscale Funnel or changes to
existing Tailscale Serve routes are needed. Keep both foreground processes alive.
Persistent service registration and Windows/WSL startup integration are separate
approved operations, not a consequence of merging this configuration.

## Teammate development

Open the approved HTTPS URL, create a new Stack account, accept your invitation
and upload a synthetic resume. The API writes account-owned records and the
server stores the associated files; a teammate needs no database password. Use
synthetic resumes while testing because authorized host maintainers can inspect
server data and backups. Keep uploaded resumes and account exports out of Git.

For native builds, set `STACK_API_URL` to the same HTTPS origin with the existing
[native build tooling](../ios/README.md). A previously installed app using the private Tailscale URL must
be rebuilt/reconfigured. Google/Apple sign-in and Google email/calendar integration
require separately configured credentials/redirects; use password sign-in for
this initial setup. Do not embed tunnel or provider credentials in clients.

The hosted browser workspace uses the same origin as its API. For a locally
served browser frontend, proxy the existing gateway routes through that local
development server; the current gateway does not implement CORS preflight.
Do not solve this by exposing the raw API or adding wildcard CORS. An optional
Cloudflare Access layer needs deliberate browser/native/session handling first.

A shared backend runs one agreed revision. Local branch changes do not change
it. Backend developers should use their own clone-local database/storage for
schema and server changes, then arrange an explicit shared development update.
Back up the shared database and storage together before a migration; do not run
migrations against the personal instance. Do not share writable runtime folders
between worktrees. Keep the API at one writer until its process-local locking
assumptions change. Optional provider/browser/action permissions are separate
from successful login or upload and must be enabled and verified separately.

## Verification and rollback

Repository regressions use disposable accounts and the committed synthetic PDF:

- `tests/test_gateway.py`: admitted app routes, login rate limits, private worker
  RPC rejection and account authentication on the LinkedIn path.
- `tests/pdf_upload_security_tests.jac`: rejected unsafe PDFs create no records or
  files; valid uploads preserve bytes, idempotency and cross-account isolation.
- `tests/test_resume_processing.py`: durable resume import, record edits,
  reload/persistence and stale/other-owner rejection.

Run these in a disposable source copy with the pinned backend Python dependencies
installed, an isolated `STACK_JAC_CACHE_HOME`, and scratch data. For example, from
that copy after preparing its tools:

```sh
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 ./scripts/jac run --no-serve tests/test_gateway.py
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 JAC_TEST_STRICT=1 ./scripts/jac test tests/pdf_upload_security_tests.jac
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 STACK_CORE_SUITE=resume ./scripts/jac run --no-serve scripts/ci/core-tests.py
```

Never point these at a running shared/personal database. These are repository
checks, not proof of an activated tunnel. No new CI job, gate or deployment hook
is required.

After approved activation, verify from a device outside the tailnet with
Tailscale off. Use two disposable Stack accounts and a synthetic resume:

1. Anonymous personal/upload calls are denied; a registered account still needs
   invitation admission for the normal upload flow. Invalid invitations fail.
2. Account A uploads the PDF, sees one resume record after retry, opens matching
   original bytes, signs out/in and still sees the record. Reopen after a planned
   restart to verify persistence; do not restart unrelated services.
3. Account B has its own empty resume list and cannot read A's resume by its ID.
4. Graph/admin/worker routes are not reachable through the gateway. The database
   and filesystem have no direct public route. Check upload/read and any long
   browser/agent response through the proxy rather than assuming transport works.
5. Repeat the agreed native app account/upload flow using the public origin.

A successful page load or tunnel connection alone does not pass these checks.
Record the tested revision, client and result. Confirm both initial rejection
and authorized success; do not use real resumes or model calls for this smoke.

To stop sharing, stop only this `cloudflared` process. Stop the isolated launcher
with Ctrl-C when no longer needed. Preserve its database/storage; do not delete
`.jac` to reset access. Remove only the approved development DNS/tunnel resources
if a later cleanup is authorized. Existing private routes and personal data are
not part of this rollback.

## Official references

- [Published applications](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/)
- [Ingress configuration and validation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [Cloudflare Access and CORS](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/cors/)
