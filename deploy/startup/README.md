# Windows/WSL startup and maintenance acceptance

These are preparation files for MAT-31, based on `53d9bd305319fae690e32e3c0ac2a10329ab72e4`.
They have not been installed or run against production. They contain no registration,
security-setting, deployment, reboot or WSL shutdown operation. MAT-30 separately
owns deployment healthchecks/rollback. This launcher verifies startup only.

## Observed host configuration (read-only, 2026-10-06)

The existing `Stack-WSL-Host` task is running. It has an enabled **logon** trigger
scoped to the Windows owner of `Ubuntu-24.04`, `Interactive` logon type, `Limited`
run level, `IgnoreNew` multiple-instance policy, unlimited execution time, three
retries one minute apart, and `StartWhenAvailable=true`. Its hidden PowerShell
action waits for `wsl.exe -d Ubuntu-24.04 --exec /usr/bin/sleep infinity`.
The exact principal was checked locally against the owner; retain that principal
privately in the operator worksheet rather than publishing machine/account IDs.
The default Linux user is the existing ordinary distro user; service commands
explicitly use root within that owner's distribution, never a SYSTEM-owned distro.

`/etc/wsl.conf` has `systemd=true`. PostgreSQL 16, Docker, API, gateway, worker and
browser are active; Stack units are enabled. Discovery and Linux tailscaled are
not installed. The API binds 127.0.0.1:8000, gateway 127.0.0.1:8080, browser 8011.
Windows Tailscale is running with Automatic start; its backend reports Running
and existing Serve routes are configured. These observations do not prove recovery.

**Current recovery requires owner login. Unattended boot recovery remains unmet.**
Do not call a login-only task unattended or silently enable auto-login. WSL
distributions belong to their Windows account. Changing the task to SYSTEM would
select a different account's distributions. A boot-triggered task under the distro
owner requires an operator-approved, locally supported noninteractive logon method
and an actual logged-out boot test. This work creates/stores no credentials and
does not assume S4U works for WSL on this host.

## Launcher behavior

`../start-wsl.ps1` requires the exact distribution and existing private HTTPS phone
origin, so it cannot silently select the default distro. It uses a single total
budget (default 240 seconds, max 900), bounded native processes/HTTP calls, sanitized
stage diagnostics, and nonzero exit on failure. It checks distribution ownership
through the selected Windows user's WSL list, then invokes the installed Python
helper. The helper starts **existing** units through systemd with `--no-block`;
repeated `start` uses the existing instances. It never enables, resets, restarts,
installs or clears units, migrates data, changes tokens, resets Serve, or runs work.
Missing/failed units fail; restarting a failed service is a separate operator action.

Ordering is PostgreSQL/Docker → API health (`POST /function/health`, Stack status
ok) → gateway/browser/worker active → gateway HTTP 200 HTML → authenticated browser
`ready=true` → running process IDs. Discovery is opt-in on the Linux helper only;
the current Windows launcher intentionally uses the observed host set.
Browser health reads only the existing token from `/etc/stack/browser.env` in
memory, with no body/credential output. The API-only mode needs no credentials.

Windows then checks localhost gateway forwarding, Tailscale backend Running, and
HTTP 200 HTML at the operator-supplied private origin with valid TLS and no redirects.
Those are host-route observations. They do not prove authentication, worker job
completion, browser security policy, the deployed revision, or an actual phone path.
Every success explicitly reports `phone_acceptance=not_run`.

Systemd activity alone does not keep WSL alive. **Retain the existing lifetime
keeper** and its IgnoreNew policy. This finite readiness action is separate from
the keeper; never replace its infinite sleep with a finite readiness command.
Task Scheduler actions are sequential, so appending this action after infinite
sleep would never execute it. During approved setup use one separately named
`Stack-WSL-Readiness` task with IgnoreNew, the same owner/approved trigger semantics,
and a finite execution limit greater than the startup budget (e.g. five minutes for
240 seconds). Inspect all existing matching registrations first; update an existing
readiness task in place instead of creating another. Keep the keeper as the sole
lifetime process; the readiness task starts no second API/worker/browser process.
No scheduled-task installer is included because boot/logon selection is unresolved.

## Explicit operator setup gate

Before any live write, obtain approval for the exact file installation, drop-ins,
task definition, trigger/logon method and maintenance window. The current code
review does not grant that approval. Prepare and review this private worksheet:

1. Exact Windows owner, distribution, Windows launcher directory, existing phone
   origin, existing keeper/readiness task XML exports, file hashes and ACLs.
   Confirm the owner sees the intended distro and that all referenced paths are
   trusted, immutable to ordinary app/service users. Preserve registration exports
   privately (they contain account/machine identifiers). Inspect other Startup
   folder/Run registrations for WSL/Stack before registration. The current owner's
   and machine Run keys had no matching WSL/Stack values, and the ordinary Startup
   folders had no WSL/Stack-named files in this inspection. Shortcut targets,
   services and other users' registrations were not exhaustively inspected.
2. Choose accepted login-only recovery or required unattended boot recovery. If
   unattended is required, validate the owner logon method during attended setup,
   without new persistent access credentials or weakening security. If this is
   impossible within that restriction, report the blocker for an operator decision.
3. Back up exact current unit/drop-in/helper files and task definitions privately.
   Install `stack-startup.py` as root-owned, mode 0755 at
   `/usr/local/libexec/stack-startup.py`. Copy the Windows launcher and adjacent
   `startup/windows-startup.ps1` to an operator-controlled directory preserving
   layout. Do not run scripts from an untrusted/shared writable checkout as root.
4. Existing enabled units may start before this finite launcher. To enforce API
   readiness for automatic systemd starts, review the three `units/*.conf` templates
   and install them as `startup.conf` under the matching
   `/etc/systemd/system/stack-<name>.service.d/` directories. Preserve any existing
   drop-ins. They add the real PostgreSQL dependency to API and API health gates
   to gateway/worker. Browser's existing Docker requirement stays intact.
   Review effective merged units and run `systemd-analyze verify` before an approved
   `daemon-reload`. No restart is needed merely to stage these for the next boot;
   readiness gates are bounded at 90 seconds and failures remain visible in journal.
5. Review a hidden, noninteractive PowerShell task action using `-File` with the
   exact launcher path, `-Distribution` and `-PhoneOrigin`. Do not bypass execution
   policy, broaden privileges, reset Tailscale, or create extra keeper tasks. Reuse
   existing registration where applicable and compare readback XML/ACLs afterward.
   Capture sanitized stdout to a private bounded/rotated operator log; retain Task
   Scheduler result/history. Do not put secrets in arguments, logs, source or Git.

An approved invocation after installing the helper (placeholders, not a command
to execute on the live host during implementation):

```powershell
& 'C:\operator-controlled\stack\deploy\start-wsl.ps1' `
  -Distribution 'Ubuntu-24.04' -PhoneOrigin 'https://YOUR-EXISTING-NODE.ts.net' `
  -TimeoutSeconds 240
```

## Disposable verification

From the checkout root:

```powershell
python -m unittest discover -s deploy/startup -p test_startup.py -v
pwsh -NoProfile -File deploy/startup/test-windows-startup.ps1
```

Python tests replace every systemctl and service HTTP operation, exercise dependency
and missing-unit failures, ordering, repeated-start instance reuse, delayed/permanent
readiness, credential preservation and sanitized failure reports. The Windows
suite uses only disposable child PowerShell processes plus mocked WSL/Tailscale/HTTP
for missing distribution, helper failure and delayed/permanent network failure.
It also verifies real child timeout and nonzero exit handling. A disposable HTTP
server regression verifies that trickling response bodies cannot extend the Linux
helper/API gate's wall deadline. This verifies the
startup mechanism, not the persistence behavior of the actual database/queue.

## Real reboot acceptance (scheduled maintenance only)

Obtain separate explicit approval to reboot Windows at the agreed time, after host
setup approval. Use an independent observer on a phone or another computer that
will stay powered and connected. Never trigger a reboot from merge CI.

1. Record privately: deployed revision/manifest (currently reported `53d9bd3`),
   launcher/helper/drop-in hashes, effective tasks/units and trigger mode, Windows
   boot time, WSL boot ID, service PIDs/restart counts, existing Tailscale routes,
   observation timestamps and the agreed recovery deadline (startup budget plus
   measured Windows/network boot allowance, e.g. ten minutes total). Check fresh
   recoverable backups without replacing the live database or storage.
2. Use a permitted disposable test account/job to record a queued item and stable
   IDs, input-file/config hashes, expected resumption and duplicate-work criteria.
   Do not queue a real external send/purchase/application. Preserve all real queued
   work. If no safe queued item exists, record this acceptance as unexecuted; do
   not substitute mocked unit tests for queued-work recovery.
3. Observer records the last usable authenticated phone operation. Operator reboots
   once, manually, at the approved time. For unattended acceptance leave the owner
   logged out until the deadline. A login during this interval invalidates an
   unattended-boot result; it may establish only login recovery.
4. Observer records connection loss/return and HTTPS recovery. Operator compares
   Windows boot time and WSL boot ID to baseline; unchanged timestamps do not pass.
   Confirm expected revision through the installed release manifest/source hashes,
   no second keeper task or API/worker/browser instance, bounded launcher result,
   and effective unit health. Remote reconnection alone does not pass.
5. On a real phone with the intended Tailscale path, authenticate and complete one
   safe end-to-end Stack operation, including browser/worker where expected. Confirm
   the queued item resumed with its same ID and one result, no duplicate external
   work, preserved files/config/account access and expected durable queue state.
   Record redacted observer evidence, elapsed timing, result and unperformed checks.
6. If the deadline expires, observer reports failure. Use attended console access;
   inspect Task Scheduler result/history and targeted journal entries locally.
   Restore only the changed task/helper/drop-ins from their backups after approval,
   retain the original keeper, and start existing units only with operator approval.
   Never restore an older database/storage snapshot over newly accepted work,
   delete queues, repeatedly reboot, or terminate shared WSL as an automatic fix.

MAT-31 remains open until accepted trigger semantics, installed configuration,
physical reboot, independent observer, actual phone path and durable queue evidence
are recorded. Local tests and code review alone do not satisfy those gates.
