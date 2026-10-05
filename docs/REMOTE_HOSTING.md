# Personal iPhone and Windows hosting

Prepared for `codex/integrate-agent-features`, Jac **0.37.21**, Windows 10 Home
22H2, and a free Apple Account first. These files are templates; preparing them
does not install, deploy, sign, migrate, or grant credentials. Main is separate.

## Backend on WSL2

The exact Jac release has Linux x86_64/aarch64 and macOS aarch64 binaries, no
Windows executable. Its runtime bundles Python; the Windows Python/uv versions
are not the hosting runtime. Use **WSL2**, not WSL1. Firmware virtualization must
be enabled first. Host setup, installation and any restarts require a separate
approved step. See [Microsoft's WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install)
and [Jac 0.37.21 release](https://github.com/jaseci-labs/jac/releases/tag/v0.37.21).

Use a systemd-enabled Linux distribution (`deploy/wsl.conf.example`) and put an
ordinary checkout of the selected revision at `/opt/stack` inside Linux's own
filesystem. Do not copy the Mac worktree's Git pointer, PostgreSQL cluster,
virtualenv, caches, native builds or `node_modules`. Keep the service running
as an unprivileged `stack` user, with only `.jac` and `storage` writable.

During approved provisioning, install Jac **0.37.21 Linux x86_64**, PostgreSQL
**16**, Node **22.22.0**, and Tectonic for the integration branch's LaTeX resumes.
Do not run `scripts/setup` or `scripts/dev` on the server: they own Mac/native
builds and the optional Docker browser preview. Prepare backend dependencies
and generated assets separately:

```sh
STACK_JAC_BIN=/usr/local/bin/jac ./scripts/jac install --no-npm
STACK_JAC_BIN=/usr/local/bin/jac ./scripts/jac build --as client workspace
```

Provide private operator-owned environment files based on `deploy/api.env.example`,
`deploy/worker.env.example`, and `deploy/discovery.env.example`. Fill credentials
locally, never in chat or Git. `JAC_DB_URL` identifies the restored database.
Jac 0.37.21 reads `JAC_SERVE_DOCS` and `JAC_SERVE_GRAPH`, not names ending in
`_ENABLED`. The API explicitly binds loopback and uses **one process**: Stack's
write and idempotence locks are process-local.

Use `stack-api.service`, `stack-gateway.service`, `stack-discovery.service` and
`stack-worker.service`. They listen/use private ports 8000 and 8080. Do not enable
`stack-voice.service`, browser automation or the candidate-code sandbox initially.
Leave browser/sandbox URLs and tokens empty and `certified_adapters` empty;
keep external-action quotas zero. Docker is unnecessary for this core setup.
The isolated browser and code-execution features have additional Linux/container
requirements documented in `AGENTS_IMPLEMENTATION.md`.

Systemd starts services within Linux; Windows must also start the WSL distribution
after reboot. `deploy/start-wsl.ps1` is a Task Scheduler action example, to register
only during approved setup under the Windows identity that owns the distribution.
It starts PostgreSQL and the four core services. Test cold boot, worker recovery
and persistent data before treating the PC as available. The PC must stay awake.

## Private HTTPS and phone access

Use the existing Windows Tailscale installation to proxy the **gateway** on
Windows localhost port 8080. First verify Windows can reach the WSL listener:

```powershell
Invoke-WebRequest http://127.0.0.1:8080/
tailscale serve status
```

Inspect the current route on port 443 before changing it. Preserve unrelated
listeners; select an available HTTPS port if necessary, and use its exact origin
in the phone build. Do not reset Serve configuration, expose Jac directly, enable
Funnel, add public port forwarding, or open LAN firewall ports as part of code
preparation. [Windows can access WSL services through localhost](https://learn.microsoft.com/en-us/windows/wsl/networking).
[Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) is private to
the tailnet. The iPhone needs Tailscale connected to the same authorized tailnet
on cellular or other Wi-Fi. Use the `.ts.net` HTTPS origin, not the Mac's `.local`
name or an untrusted IP certificate. This design needs no public DNS or Caddy.

The gateway restricts routes and invitation admission; Tailscale is transport,
not a replacement for Stack login. Keep the restored personal account admitted.
Optional Google OAuth requires its exact HTTPS `/oauth/google` redirect registered
with Google; provider keys, refresh-token encryption and consent are separate setup.

## Codex subscription under the worker identity

The worker template uses `CODEX_HOME=/var/lib/stack-codex`, `HOME` at that same
private location, `StateDirectoryMode=0700`, and write access only to this state
and the project cache. `ProtectHome=true` stays enabled. This grants no access to
the desktop user's home or CLI store. During provisioning, systemd creates the
private state directory for the service user. Populate a private `config.toml`
from `deploy/codex.config.example.toml` only during approved authentication setup.

Install the Linux Codex CLI on the service PATH and check `codex --version` and
`codex exec --help` against `agents/local_cli.jac`. The adapter requires
`--ignore-user-config`, `--ephemeral`, `--output-schema`, `--output-last-message`,
JSON output, read-only sandboxing and its explicit `--disable` feature flags.
An incompatible CLI must be resolved before enabling model work.

Initiate **`codex login` with browser OAuth** under the exact `stack` UID and the
same `HOME`/`CODEX_HOME` as the worker, then check `codex login status` in that
environment. Linux authentication is separate from the Mac/Windows CLI login.
The file credential store must remain service-owned and writable for refresh;
never copy, display or share `auth.json`. Do not enable device authentication or
change account security settings automatically. Device-auth is a fallback only
when already enabled and explicitly approved. Follow [Codex authentication](https://learn.chatgpt.com/docs/auth).

Preserve the provider's explicit Stack account binding and daily request limit;
do not grant all accounts subscription access. Start with model permission only,
without browser/send/calendar/code actions. The API receives no provider credential
store. No live smoke call belongs in ordinary CI. A synthetic coaching acceptance
test consumes a real subscription request and needs separate authorization.

## Data migration before cutover

Choose the authoritative account dataset explicitly. Deploying this branch does
not mean replacing main with preview/feature-worktree data. Stop API, discovery
and agent writers, take a fresh paired logical PostgreSQL backup plus `storage/`,
and preserve `.jac/data/jwt_secret` and connection encryption keys privately.
Use `scripts/backup-agents.py` with private libpq environment/PGPASSFILE; restore
only into an empty separate PostgreSQL 16 database and a new storage destination.
Do not copy the Mac PostgreSQL data directory to Linux. Set `JAC_DB_URL` explicitly:
Jac's automatic database name depends on the checkout path.

The older `.integration-backups/cutover-20260929-142604` archive is a recovery
checkpoint, not a guarantee of current data. Before worker activation, apply the
integration branch's authenticated `agent_upgrade_workflows` locally to the restored
copy. It pauses unfinished legacy workflows; it does not authorize resubmission.
Repeat it to verify idempotence, compare account identities and PDF checksums,
and prove restart persistence. Keep the old code/database/storage backup paired
for rollback. Do not run workflow tests against the live restored account database.

## Self-contained iPhone install

The Mac builds/signs the app; it is not required during normal use afterward.
The current development install depends on Metro. A **Release** build embeds
JavaScript and keeps remote push off by default. After ordinary native setup is
already complete, use the new launcher during a separately approved build/install:

```sh
STACK_API_URL=https://your-pc.your-tailnet.ts.net \
STACK_TEAM=YOUR_TEAM STACK_DEVICE=YOUR_CONNECTED_DEVICE ./scripts/ios-release
```

The launcher validates the explicit HTTPS origin before prebuild/signing, compiles
Jac, updates both Expo configuration and the generated API global from that origin,
synchronizes native configuration, builds Release, checks the embedded `main.jsbundle`,
then installs/launches on the selected connected device. Without `STACK_DEVICE`,
it opens Xcode after building; install the built Release product, not a fresh Debug
Run. It never starts Metro. A stale `stack-host.json` cannot supply a release URL.
Local/loopback/LAN addresses, credentials, paths, queries and fragments are rejected
for release origins. Development builds retain local HTTP behavior.

Bundle ID remains `com.matthewkooy.stack`, minimum iOS **16.4**. A free Personal
Team can install on the user's device, but its provisioning expires after seven
days and requires rebuild/reinstall. See [Apple's Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account).
Local reminders need no APNs entitlement. Keep `STACK_PUSH_ENABLED` unset for this
first install. Later paid-team/TestFlight work can explicitly set
`STACK_PUSH_ENABLED=1`, `STACK_PUSH_ENVIRONMENT=production` and `STACK_EAS_PROJECT_ID`
after APNs/Expo provisioning. Release alone does not enable push. Paid developer
membership, build upload and delivery checks are separate work.

## Verification

Offline preparation checks (no signing/provider/database calls):

```sh
node tests/release-config.cjs
python3 tests/test_ios_release.py
sh -n scripts/ios scripts/ios-release scripts/setup
./scripts/jac check scripts/compile-mobile.jac
./scripts/jac run --no-serve tests/test_gateway.py
./scripts/jac run --no-serve tests/test_agent_providers.py
```

Use an isolated checkout, private test cache and the pinned dependency runtime.
The launcher tests stub every signing/build/install executable. For later server
acceptance, start a separate API on a spare port with a disposable `JAC_DB_URL`,
separate storage/tokens and model/external actions disabled. Point `STACK_API_URL`
at that API for `tests/test_api.py`, catalog/matching/agent checks and `tests/native.cjs`.
Run `tests/workflow_upgrade_tests.jac` only in a separate disposable database.
Verify anonymous access/ownership and gateway rejection of worker/admin/graph routes.

Final acceptance: stop Metro and the Mac backend; use the installed Release app
over cellular with Tailscale connected. Check login/session restore, jobs, saves,
PDF upload/read, prep and local reminders. Reboot Windows and verify service recovery
and unchanged data. A real Release/Xcode/device build, WSL restore, Linux CLI session
and these acceptance checks are not established by offline tests.

## Mac development output storage

On this Mac, keep development files and persistent outputs on the mounted DevSSD in the relevant developer/project folder. Verify the mounted APFS volume is writable and matches the expected local volume identity recorded in the developer folder instructions before creating output directories. If it is unavailable, stop; do not fall back to the internal Codex workspace, Desktop or Downloads. The standing instruction is recorded in `/Volumes/DevSSD/Projects/Developer/AGENTS.md`.

For manual Stack iOS builds, keep logs, exported JavaScript bundles and derived build data under:

```text
/Volumes/DevSSD/Projects/Developer/BuildArtifacts/Stack/ios-release-preflight
```

Pass this exact option to `xcodebuild`:

```text
-derivedDataPath /Volumes/DevSSD/Projects/Developer/BuildArtifacts/Stack/ios-release-preflight/DerivedData
```

The existing `scripts/ios` launcher uses `.jac/xcode-device` relative to the SSD worktree, so its build output already resides on DevSSD. Other Xcode/app caches and macOS swap are independently managed; moving these outputs does not increase RAM or change those global locations.

Native build products, signing assets and local build reports remain outside Git. Check the current local preflight report before installing a build; copied caches do not establish a successful build or device acceptance. See [source synchronization checkpoint](SOURCE_SYNC_CHECKPOINT.md) for the current source-capture boundary.
