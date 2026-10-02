# Shared browser viewer: review and rollout

The application and LinkedIn agent screens now use the same native browser
viewer. Open browser starts an authenticated live view; Take control pauses the
agent and waits for acknowledgement before allowing input. Resume agent returns
control to the worker; Stop task cancels the task and requests browser cleanup.
Closing the viewer only stops its stream. If the user has control, the task
remains paused. Saved credentials and login persistence are outside this change.

This feature is implemented on `codex/shared-browser-viewer`, based on main
`f9c0c83e7807f7c8734882586759b2e9f009dbd8`. Deployment, signing and device installation remain separate release steps. Existing integration/checkpoint worktrees remain separate.

## Control and concurrency

`agents/browser_control.py` holds per-account/run control generations, a browser
process instance, the current viewer controller, ordered command sequence and
an active-operation flag. A takeover during an operation reports `pausing`;
input unlocks only after that operation reaches a guard and returns. Another
viewer can take over and fence the previous viewer. The old controller, sequence,
generation or process instance cannot issue new browser writes.

The API reserves the task's paused state and clears its worker lease under the
existing database writer lock before requesting takeover. It rechecks ownership,
terminal state and generation after the private RPC. An older response cannot
replace a newer persisted control generation. Remote calls run outside the database
writer lock. A failed takeover RPC leaves the task paused for explicit recovery.
Claims skip paused tasks, and old leased worker completions cannot advance them.

Takeover is denied once an approved submission intent exists. Browser guards
run before navigation/input, between fill fields and between bounded LinkedIn
waits. An in-flight browser call is not forcibly preempted: navigation/click can
consume its timeout, and synchronous page evaluation can stall. Stop cannot undo
an external submission already sent; existing uncertain/receipt handling remains.
The browser uses one Playwright executor and an operation lock, so other sessions
can see stale frames during a long operation. Capture freshness is shown honestly.

Unconfirmed native/web input stays blocked even if a later stream heartbeat
arrives. A confirmed new takeover generation is required to recover. The native
viewer serializes taps, scroll events and text/key commands; taps account for
image letterboxing. Swipes send one wheel event on release. Text is batched,
limited to 8,000 characters and clears on control/lifecycle changes. Actual iPhone
keyboard, IME, gesture and modal layout behavior still needs device validation.

## Stream authentication, revocation and lifecycle

The gateway's authenticated POST `/browser/stream` checks existing admission and
calls `agent_browser_subscribe` with the user's bearer. That API checks current
account/run ownership, capability and nonterminal task state. It creates a
single-use, ten-second grant scoped to that account/run. The browser worker's
private `/stream` consumes the grant; the gateway relays frames without exposing
the grant, worker service key or CDP connection. The authenticated subscribe API
itself returns its grant and the operator-configured private stream URL to the
owning user; it does not return service/CDP credentials.

Each worker connection lasts at most 25 seconds of normal streaming, has a
4 MiB output budget and a five-second socket write timeout. Reconnection rechecks
account authentication and run ownership. Token expiration, policy changes or
revocation not propagated to the browser may therefore leave the current bounded
connection alive until it ends; JWT validity is not rechecked on every frame.
Allow for a blocked final write when interpreting the duration limit. This does
not add a general-purpose immediate JWT revocation service.

Account purge revokes outstanding grants and marks active viewer records revoked
before waiting for the Playwright operation lock. An owner tombstone also rejects
previously queued operations/grants for run keys not yet registered. The next stream iteration
suppresses cached imagery, reports revocation and closes. Capture callbacks skip
stopping/stopped records. Browser cleanup occurs at the next guarded boundary or
idle tick; grants are denied for stopped/revoked runs. Cancellation requests stop
out of band. An idle stop with no context also receives a stopped acknowledgement.
If the browser cannot be reached, task cancellation is durable but physical
cleanup still depends on reconnect/idle expiry, as the existing API message states.

There are at most two viewers per run. Frame delivery retains only the latest
cached frame, limits updates to four per second and sends heartbeats every two
seconds. CDP screencast is scoped to active viewers; failed capture uses a
screenshot fallback. Start/stop failures detach CDP sessions; callbacks from closed
contexts cannot recreate frames. Closing/backgrounding/unmounting or native sign-out
aborts the client stream. Disconnect releases the watch count; the next browser
tick detaches capture. Slow disconnect detection is bounded by stream duration.
Watching a context prevents idle expiry; after disconnect the existing one-hour
idle expiry uses the same full context/CDP cleanup. Control tombstones and counters
remain in process memory until restart; they are not persisted credentials.

The response sends `text/event-stream`, `no-store, no-transform`,
`X-Accel-Buffering: no`, and flushes each record. Local loopback gateway/worker
streaming is tested. [Caddy documents immediate flushing for SSE](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#streaming),
but the live Tailscale HTTPS route, proxy configuration and iPhone network path
have not been tested. No deployed proxy settings were changed.

The installed React Native `XMLHttpRequest.js` enables incremental network events
when `onprogress` is attached before `send`; this viewer uses that path for its
bearer-authenticated POST stream. Real React tests cover incremental chunks,
duplicate progress notifications, 403, reconnect cancellation and viewer input.
This source/fixture evidence does not certify physical-device progressive delivery.

## Packaging and compatibility

`deploy/backend_release.py` discovers allowlisted source from the exact committed
Git tree, including `agents/*.py`. The old main payload has 68 files including the
generated parser. Adding `agents/browser_control.py` and `agents/browser_stream.py`
produces 70; no new privileged allowlist is needed. Untracked/dirty source cannot
be packaged as a valid exact-commit release. Jac stays pinned to 0.37.21 and the
backend dependency/runtime contract is unchanged.

The container preparation tool previously used a hardcoded historical source
path and omitted both Python modules. It now takes an explicit `--source`, requires
a new `--output`, and copies only its public allowlist plus seccomp data. The local
preview image list now includes both modules too. `deploy/browser.Dockerfile`
already copies the staged agents directory. Historical PC bundles/runtime files
are not modified by source preparation.

The prepared source context is under
`/Volumes/DevSSD/Projects/Developer/BuildArtifacts/Stack/shared-browser-viewer/browser-source-context-reviewed-20261002`.
Its metadata hashes all 12 context files plus seccomp. It contains no installer
credentials or live data; it is a build context, not an authorized install bundle.
The earlier `browser-source-context-20261002` and `browser-source-context-final-20261002` are superseded by this reviewed context.

Older apps can continue using their existing task APIs and read-only snapshots,
but their browser writes lack takeover/instance/generation/sequence fields and
are rejected. There is no unsafe legacy write bypass. Existing older UI task
responses may also not offer Resume for a new paused task. Therefore this needs
a coordinated browser/backend/client release. Do not merge this feature to main
before that window: main pushes trigger automatic backend deployment.

## Approved deployment flow needed later

1. Finish the isolated real-browser fixture and native build/device review. Prepare
   and review the exact final source commit and iPhone bundle before changing main.
2. On the PC, compare current source and direct-input patches against the selected
   final commit. Preserve local runtime changes and the existing baseline; unexpected
   source changes cause the backend helper to stop for attended review. Do not copy
   the historical checked-in browser runtime over `/usr/local/libexec/stack-browser/browser_runtime.py`.
3. In an agreed interruption window, rebuild the isolated browser image from the
   reviewed source context with its existing pinned Jac/Playwright dependencies.
   Record the resulting immutable `sha256:` image identity. An attended administrator
   must update root-owned `/etc/stack/browser-image-id` and restart only
   `stack-browser.service` using the existing controller. Preserve auth/session keys,
   runtime, network/egress policy, seccomp, quotas, mounts, service hardening and
   controller state. Restarting loses in-memory LinkedIn/login contexts; users must
   explicitly recover control after the process instance changes. Do not run the old
   bootstrap installer merely to swap this image.
4. Deploy the exact backend commit through the existing main-only release workflow.
   It installs allowlisted backend source/parser and restarts API, worker and gateway.
   It does not rebuild/restart the browser container, publish web assets or install
   the iPhone app. No new CI tests/gates were added. Existing helper protections stay.
5. Build/deploy web assets separately if the web viewer is used. Deliver the reviewed
   new iPhone build in the same window, then perform authorized functional checks.
   Keep the old reviewed image/source identifiers for an attended rollback; there
   is no new automatic rollback or data restore.

The mobile sources compile and `scripts/compile-mobile.jac` stages the shared
`browser-viewer.js` beside `device.js`. There are no new npm/Pod dependencies,
entitlements or APNs requirements for this viewer. A new native JavaScript bundle
is required; the older installed Release does not contain it. Xcode Release build,
current provisioning/paid membership, signing, installation and TestFlight readiness
are unverified. Any later iOS build must use the existing SSD preflight/DerivedData
location and a serial resource guard. No signing/password/device prompts were run.

## Local validation and installed test tools

Logs under the SSD artifact directory show six controller tests, five threaded
worker service tests, three stream tests, five capture cleanup tests, one
authenticated Jac API fixture and the native React/stream fixture passing. The
unchanged LinkedIn suite has 19 passes and gateway suite one pass. Pinned Jac
checks pass for browser, service, main and web; mobile source staging passes.

With explicit user approval, official Playwright 1.58.0 wheels and matching
Chromium headless shell 145.0.7632.6 (revision 1208), plus the installer's FFmpeg
helper, were installed only under
`/Volumes/DevSSD/Projects/Developer/BuildArtifacts/Stack/shared-browser-viewer/playwright-validation`.
Measured footprint is about 334 MiB. The project venv and dependency manifests
were not changed. Installed transitive package versions are recorded separately
in `installation-state.json`. No full Chrome/Firefox/WebKit install occurred.

The network-denied real test produced a 600 by 400 JPEG screencast (3,481 bytes),
with the first frame after 636.1 ms, and a later CDP frame after changing the
page. Ordered real browser click and text commands set the DOM input to
`Synthetic input`. Last-viewer disconnect detached CDP; Resume advanced to
generation two; Stop closed the context and acknowledged stopped. The sole
synthetic external image request was aborted by the browser context route.
No account, credentials or saved profile were used.

The test also ran under a local macOS sandbox denying outbound IP connections;
the wrapper first verified that even a local IP connect was denied. Chromium's
own Mac sandbox cannot initialize nested inside that sandbox (GPU process
sandbox initialization returned EPERM). The fixture therefore disables its
inner Chromium sandbox only when the wrapper opts in after verifying outer
network denial. Production `BrowserPool`/container sandbox settings are unchanged.
These results validate real capture and control semantics on Mac, not the PC's
Linux seccomp/process isolation.

The pinned Jac launcher ignores ambient `PYTHONPATH`, so the successful test uses
the SSD-only `run-real-capture.jac` wrapper to add the isolated wheel site and
checkout to its import path. Earlier failed import/nested-sandbox diagnostics
remain in the validation directory; they required no dependency reinstall.
The successful evidence is `real-capture-result.log`, `real-capture-result.json`
and `real-capture-result.jpg`. No test browser processes remained after cleanup.

Reproduction after checking resource limits (no reinstall needed):

```sh
STACK_VIEWER_VALIDATION=/Volumes/DevSSD/Projects/Developer/BuildArtifacts/Stack/shared-browser-viewer/playwright-validation
export TMPDIR="$STACK_VIEWER_VALIDATION/tmp"
export PLAYWRIGHT_BROWSERS_PATH="$STACK_VIEWER_VALIDATION/browsers"
export PYTHONDONTWRITEBYTECODE=1
export STACK_VIEWER_PLAYWRIGHT_SITE=$("$STACK_VIEWER_VALIDATION/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
export STACK_VIEWER_CAPTURE_REPORT="$STACK_VIEWER_VALIDATION/real-capture-result.json"
/usr/bin/sandbox-exec -f "$STACK_VIEWER_VALIDATION/no-outbound-network.sb" ./scripts/jac run --no-serve "$STACK_VIEWER_VALIDATION/run-real-capture.jac"
```

[Official browser installation guidance](https://playwright.dev/python/docs/browsers)
explains the matching headless shell and custom browser path; the
[versioned wheel page](https://pypi.org/project/playwright/1.58.0/) identifies the
Mac ARM64 package. Installation and caches/temp remained on verified DevSSD.

Native fixture/source compatibility is verified, but physical iPhone progressive
XHR delivery over the deployed HTTPS/Tailscale path, Image rendering, IME/keyboard,
gestures and modal layout remain untested. A signed iPhone binary/device install,
Linux container capture under retained production policies, and live proxy streaming
also remain outside completed validation. At the real-browser validation checkpoint, no merge, deployment, signing,
device installation or live credential actions had occurred.

## Assessment of a staged compatible rollout

The current branch cannot be deployed backend-first without rejecting the older
app's browser writes. A bridge client first also needs additional code: this
branch's new viewer does not retain the old viewer as a fallback when the old
backend lacks browser capabilities.

Safe coexistence is feasible as a separate compatibility change, with a pinned
server-owned protocol per run. Existing/legacy-created runs would remain on the
legacy attention-state workflow, while explicitly negotiated v2 runs would use
the current controller/instance/generation/sequence authority. Legacy requests
must always be rejected for v2 runs; absence of fields must never downgrade a
run. No legacy and v2 client may write the same browser context. Moving a run to
v2 must drain old work and close/fence its legacy context before creating the new
one. A client bridge needs both viewers, capability negotiation and a clear
upgrade path for old clients encountering v2 runs. Coexistence preserves legacy
behavior on legacy runs; it does not give that older protocol v2's ordering and
exclusive-viewer guarantees.

A potential staged order would be: release a dual-compatible client; deploy a
legacy-compatible browser/backend with v2 dormant; opt supported clients into
new v2 runs while existing runs stay legacy; retire v1 only after the migration
window. Protocol routing must be selected from persisted server state, never
merely from the incoming command shape. This avoids an unfenced legacy bypass
into a v2 session. It requires an explicit additional design/implementation and
its tests; no such shim, flag, migration, new service or authority relaxation was
implemented in this pass. If all unchanged old apps must control the same v2 run,
that cannot be promised without losing the guarantees their protocol cannot
express. The current coordinated rollout remains the available implementation.

Stop local validation if DevSSD is absent/read-only, memory pressure reaches
critical or internal free storage falls below 10 GiB. Continue using serial jobs.
