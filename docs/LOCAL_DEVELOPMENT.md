# Local contributor development

The supported public development path is Ubuntu 24.04 on Linux or inside Windows
WSL2, on x86_64 or aarch64. Run every project and provider command in that Linux
environment. The backend, browser workspace, discovery worker, and agent worker
run locally. Docker, a model login, Google credentials, and Apple tools are
optional integrations. Native Windows development outside WSL2 is not supported.

## Machine prerequisites

On Windows, open PowerShell **as Administrator** and install WSL2:

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows if requested, complete Ubuntu's first-run username/password setup,
and check `wsl --list --verbose` shows version **2**. Hardware virtualization must
be enabled; managed PCs may require an administrator to enable it. These operating
system changes are prerequisites, not actions performed by Stack setup. After
this step, use the Ubuntu terminal for the commands below.

On Ubuntu 24.04, install the machine prerequisites:

```sh
sudo apt-get update
sudo apt-get install -y git make python3 python3-venv ca-certificates curl tar xz-utils libfontconfig1
```

Python 3.12 or newer is required to run the bootstrap. Keep a WSL checkout in the
Linux filesystem, such as `~/src/Stack`, rather than a Windows-mounted folder; it
avoids Windows line-ending, file-permission, and filesystem-performance issues.
Setup needs internet access to the pinned tool and package registries. No private
repository, production account, signing identity, or maintainer secret is needed.

## Prepare and start

```sh
mkdir -p ~/src
cd ~/src
git clone https://github.com/matthewkooy2/Stack.git
cd Stack
make setup
make doctor
make dev
```

Leave `make dev` running and open **http://127.0.0.1:8080** in your browser (the
Windows browser can use the same localhost URL for WSL2). The API listens on
**127.0.0.1:8000**. Services default to loopback. The API always remains on
`127.0.0.1`; broader browser-gateway exposure requires an explicit `--host`
together with `--expose`, and is for a trusted local development network. The
Mac/iOS launcher below is a separate path with explicit device-network access.

Choose **Create an account**, enter a new local username and password, and select
**Continue**. A fresh contributor installation does not require an invitation.
Open **Practice**, start a session, enter a synthetic answer, and **Save**. Saving
and reloading a session works without a model. **Get coaching** requires the
provider and permission steps below. The **Account** page shows your Stack
**Account ID**; it is the explicit owner used when configuring a CLI provider.

Setup provisions Jac **0.37.21**, Node **22.22.0**, Tectonic **0.17.0**, and
PostgreSQL **18.6.0** in the ignored `.jac` tool directories. Binary downloads are
checksum verified. Python
requirements and browser JavaScript dependencies use committed lock inputs. You
do not need to install these tools globally. Rerunning `make setup` refreshes
generated dependencies and initializes missing local configuration without
replacing existing accounts, provider settings, worker tokens, or uploads.
Initial setup and startup do not authenticate a provider or make a model call.

Every Make command has a Python equivalent, useful if Make is unavailable:

| Command | Python equivalent |
| --- | --- |
| `make setup` | `python3 scripts/contributor.py setup` |
| `make doctor` | `python3 scripts/contributor.py doctor` |
| `make dev` | `python3 scripts/contributor.py dev` |
| `make login PROVIDER=codex OWNER=YOUR_ACCOUNT_ID DAILY_LIMIT=10` | `python3 scripts/contributor.py login --provider codex --owner YOUR_ACCOUNT_ID --daily-limit 10` |
| `make test` | `python3 scripts/contributor.py test` |
| `make clean` | `python3 scripts/contributor.py clean` |

`make test` runs synthetic offline regressions. For a startup, authentication,
and gateway smoke check that stops its own children afterward, run:

```sh
python3 scripts/contributor.py dev --smoke
```

Neither command calls a real model or needs production secrets. The smoke check
uses disposable synthetic account data. It does not certify native-device
rendering, third-party integrations, or live provider capacity.

## Use your own Codex or Claude subscription

Install the supported Codex or Claude CLI in the **same Ubuntu/WSL2 environment**
as the Stack worker. A Windows-side login is not the WSL worker's login. Run
`make doctor` to check installed versions and isolation/structured-output flags;
missing optional CLIs do not prevent ordinary development. Follow the CLI's own
installer and subscription-login guidance linked in [model providers](AGENT_PROVIDERS.md).

With your local account ID from **Account**:

```sh
make login PROVIDER=codex OWNER=YOUR_ACCOUNT_ID DAILY_LIMIT=10
# Alternatively:
make login PROVIDER=claude OWNER=YOUR_ACCOUNT_ID DAILY_LIMIT=10
```

Stop and restart `make dev` after changing the provider configuration.
This invokes the selected CLI's own sign-in flow and saves the explicit owner
binding and request cap locally. Authentication remains in the CLI's private
home configuration; no OAuth tokens are copied into the checkout. Never copy
`~/.codex`, `~/.claude`, or their credential files into the project. The login
command does not make a model request and does not grant Model permission.

In **Account**, select **Enable Model for up to 24 hours**. A fresh policy grants
only Model. If other standing permissions are already active and expire within
24 hours, their existing expiry and settings are preserved. If those permissions
are disabled, expired, or last longer than 24 hours, the control refuses the
change; manage those permissions in the iPhone app first. **Revoke Model** removes
only Model. Account ownership checks, durable provider request caps, and approval
of exact external-action content continue to apply. There is no automatic paid
API fallback after a CLI failure.

To authorize one real subscription request, start a behavioral practice session,
enter a synthetic answer, **Save**, then select **Get coaching**. Inspect the task
in **Activity**, retrieve the coaching result, and reload the session to confirm
persistence. This consumes your subscription capacity. Repeat separately after
binding the other provider to verify both; authentication or a configured badge
alone does not establish live model success. Provider acceptance evidence and
known platform gaps belong in the issue/PR, separate from ordinary offline CI.

## Optional capabilities

The ordinary `make dev` path deliberately excludes inherited deployment settings,
API keys, paid job-source credentials, and Google credentials. It disables `.env`
loading. Exporting external credentials or placing them in `.env` does not enable
these integrations in the contributor launcher. Configure them using the advanced
worker/deployment workflow in [remote hosting](REMOTE_HOSTING.md) and the
capability-specific guides below, in a separate installation.

- **Isolated application browser:** Docker and the browser-service configuration
  are separate prerequisites for LinkedIn/browser handoffs. See
  [LinkedIn setup](LINKEDIN_PROFILE_REVIEW.md). Core startup does not launch Docker.
- **Google email/calendar:** require your own OAuth application, allowed redirects,
  and explicit account authorization. See [agent setup](AGENT_EXPERIENCE.md).
  Fresh local setup leaves outbound actions and API budgets disabled.
- **Paid job sources:** require your own provider credentials and accepted terms.
  Public feeds need no paid-source credentials; see [job discovery](JOB_DISCOVERY.md).
- **API model providers:** require explicitly configured credentials, pricing, and
  positive budgets; see [model providers](AGENT_PROVIDERS.md). They are separate
  from a subscription CLI login.
- **Native iOS:** requires a Mac, Xcode, CocoaPods, and an Apple signing identity.
  From a Mac checkout use `./scripts/setup --ios`, then `./scripts/dev` and
  `./scripts/ios` in separate terminals. See [README](../README.md).

## Troubleshooting and safe cleanup

`make doctor` checks tool compatibility, local configuration, and occupied ports
without printing secret values or calling a model. A configured CLI provider also
has its subscription authentication status checked; provider capacity still
requires an explicitly authorized live request. Stop your existing Stack
launcher before checking for free ports; use
`python3 scripts/contributor.py doctor --running` when intentionally inspecting a
running installation. Inspect local logs under `.jac/logs` after a startup failure.
Do not paste logs or account exports publicly without checking for personal data.

Contributor commands refuse a checkout containing `jac.local.toml` and preserve
that existing override file. Keep the installation using those overrides intact
and create a separate public clone for contributor work:

```sh
cd ~/src
git clone https://github.com/matthewkooy2/Stack.git Stack-contributor
cd Stack-contributor
make setup
```

Do not copy the other installation's `jac.local.toml`, `.env`, databases, or private
configuration into this clone. If its services own 8000/8080, use the alternate
ports below.

If another application or Stack installation already owns the default ports,
leave it running and select unused ports for both diagnostics and startup:

```sh
python3 scripts/contributor.py doctor --api-port 18000 --web-port 18080
python3 scripts/contributor.py dev --api-port 18000 --web-port 18080
# Or run the startup smoke check on those ports:
python3 scripts/contributor.py dev --smoke --api-port 18000 --web-port 18080
```

Open **http://127.0.0.1:18080** for that installation; its API remains on
**127.0.0.1:18000**. Use the same port pair for diagnostics and startup. Ordinary
commands and CI retain the default free-port requirement on 8000/8080.

Browser source edits require `make setup` to rebuild the browser assets, followed
by a restart of the development launcher.

For a download or checksum failure, fix registry/network access and rerun setup;
do not disable checksum checks. For WSL permission or shell-launch problems,
clone into `~/src/Stack` using Linux Git. If localhost is unreachable from Windows,
verify the WSL2 distribution is running and the WSL networking/firewall policy
permits localhost forwarding. Test inside Ubuntu with
`curl http://127.0.0.1:8080/` before changing bind addresses. Use the doctor output
for the exact missing tool or incompatible CLI flag; signing in alone does not
fix an unsupported CLI release.

Stop development with **Ctrl-C** before cleaning. `make clean` removes generated
build outputs only. It preserves `.jac` tool/data directories, the Jac PostgreSQL
cluster, `storage/`, worker tokens, and your CLI login. **Do not delete `.jac` or
`storage/` as routine cleanup**: they contain accounts, uploads, and private
configuration. Stop services before backing up the database and storage together.

Secrets belong in the CLI's private home configuration, ignored `storage/`, or
ignored local environment files for advanced workflows; the contributor launcher
does not load `.env`. `.jac/`, `storage/`, `.env*` (except the sanitized
example), and credential/key files are excluded from Git. Keep examples synthetic,
review `git diff --cached` before committing, and never force-add ignored private
files. If a secret was ever committed, ignoring it afterward cannot remove it
from history: revoke it and arrange a deliberate history cleanup. Do not include
private databases, logs, exports, tokens, or provider-login output in bug reports.

The contributor CI workflow runs clean Ubuntu setup, repeat setup, diagnostics,
offline tests, and startup smoke checks. A second setup/startup verifies that the
synthetic account and saved practice session survive setup and restart. CI does
not use deployment credentials,
make model calls, or certify WSL2. Actual WSL2 onboarding and live checks for each
provider are recorded separately with their tested revision and any unavailable
credential/platform checks; historical Mac evidence is not a WSL2 pass.
