# Backend health and compatible rollback (MAT-30)

Installing trusted helpers and establishing the first healthy baseline require
separate privileged activation approval. Routine source delivery cannot activate
this protocol on the existing host by itself.

## Promotion contract

The existing format-3 receiver and host deployment lock remain in use. The
workflow additionally requires `STACK_RELEASE_HEALTH_PROTOCOL=1`, so a host with
the old restart-only helper cannot silently deploy this protocol. Helpers are
root-owned and installed separately; no release hook receives new authority.

The promoter verifies a healthy prior before any writer stops, backs up each
managed source plus prior source policy, revision marker, browser image ID and
browser policy, then stops and confirms all API/worker/gateway/browser writers
are inactive. It changes only managed source and browser image selection.
It does not run `jac install`, modify dependencies, restore databases, rewrite
user storage, replace configuration, or reinstall service units. Jac may compile
source in its existing runtime caches. Dependency/database/runtime contract
changes require attended migration; automatic rollback is not offered for them.

The API and gateway capture `.release-identity.json` at module load. The real
worker polling loop must answer a fresh nonce through the token-authorized API
`release_smoke` endpoint. That endpoint checks existing worker authority, touches
no personal graph data and calls no external adapter/provider. Gateway checks
its loaded revision and API health. Browser readiness checks the exact selected
immutable image and its approved isolation, then exercises the serving Chromium
in a new memory-only context, with all requests aborted, reading a fixed DOM
element and closing the context. No existing session is inspected or changed.
Browser fingerprint/image may remain the prior identity when browser source did
not change; shared source equality is enforced by format-3 packaging. Static web
assets, models, PDF/LaTeX features, and phone access are separate acceptance checks.

Readiness is bounded by 20 attempts, 3-second retry spacing, and a 60-second
deadline per prior/candidate/recovery gate. HTTP runs in a child process with a
hard timeout of at most 3 seconds, IPC at most 2 seconds, Docker inspection at
most 2 seconds; late successes fail. One final bounded IPC operation can exceed
the gate deadline by at most 2 seconds. Service commands are bounded to 30 seconds,
image build to 180 seconds; receiver is bounded to 1200 seconds, SSH to 17 minutes,
and CI to 20 minutes. A forcibly killed or power-interrupted transaction cannot
promise recovery: its durable journal blocks the next deployment until reviewed.

Any failed candidate automatically quiesces all writers again, restores old
source, identity, source policy, and browser
image selection, starts the prior, and verifies its exact loaded revision and
health. The deployment still exits nonzero. If quiescing, restore, protected-state
verification, or prior health fails, the journal holds the deployment; it makes a
best effort to stop writers and never blindly continues a mixed release.

## Attended bootstrap and compatibility review

The deployed revision reported at assignment was
`53d9bd305319fae690e32e3c0ac2a10329ab72e4`, whose receipt only confirms restart
commands. It does not support these probes and cannot be treated as a healthy
rollback baseline. Before enabling this protocol, use an attended deployment of
reviewed code supporting the probes, retain the current source/runtime and data
backup according to existing recovery policy, and independently verify source
hashes, the exact loaded revision, worker RPC, browser smoke and runtime/config.
Install a root-owned `last-release.json` with `status: healthy`, `commit` and
`probe_protocol: 1` only after that evidence exists. Install the matching
root-owned `.release-identity.json` as root:stack 0640. Do not relabel the old
receipt as healthy without an actual check.

Install the reviewed existing receiver/promoter/wrappers and support modules,
plus `release_safety.py`, `release_probe.py`, and `release_channel.py` in the
existing trusted helper directory. Root validates and reads the channel's static
source and passes it to isolated Python as stack; stack needs no read or traversal
permission on the private helper directory. Its only operations run as stack in `.jac/release-readiness`;
the root helper never writes worker-controlled IPC paths. Keep existing sudo,
SSH, Docker, network, systemd and Tailscale authority unchanged.

An attended review establishes `/etc/stack-release/compatibility.json`, root-owned
0600, once per compatibility epoch. Ordinary reviewed main releases within the
same epoch need no recurring human approval. Artifact digest/revision checks
remain exact for every release. The trusted promoter independently compares both
prior and candidate inventories against this root-approved policy:

```json
{
  "protocol": 2,
  "epoch": "<reviewed bootstrap identifier>",
  "files": {"<every backend manifest path>": "<approved sha256>"},
  "routine_files": ["agents/gateway.jac"],
  "browser_files": {"<every browser source path>": "<approved sha256>"},
  "routine_browser_files": [],
  "browser_contract": {"<every browser contract path>": "<approved sha256>"},
  "data_compatible": true,
  "irreversible_migrations": false,
  "protected_files": {"<reviewed root-owned runtime/config path>": "<sha256>"}
}
```

Every added/deleted file and every changed file outside the explicit routine
allowlists holds before service stop. Freeze the entire server-filtered `jac.toml`
(including entrypoints and placement), `main.jac`, persistence code in `core/`,
worker/result producers, workflow contracts, discovery normalization/matching/
timeline code, browser session persistence and launchers. The example gateway
allowlist is a starting proposal requiring review of the actual bootstrap source;
it is not permission to add persistence writes to a routine file. Browser frame
transport or search presentation may be included only after the same review.
Both prior and candidate must satisfy the same frozen hashes. Release-supplied
epoch labels or attestations grant no authority. Frozen changes require an
attended epoch update, including compatible forward migration where applicable.
This conservatively guards accidental incompatibility in trusted reviewed code;
hashes cannot prove arbitrary routine code semantically safe.

Review node/schema changes AND runtime data transformations, startup migrations,
workflow checkpoint semantics and old code's ability to read candidate-written
data. A release-supplied compatibility statement is not sufficient. Include hashes
for `/etc/stack/api.env`, `/etc/stack/worker.env`, all three installed Stack units,
`/opt/stack/scripts/jac`, `/usr/local/bin/jac`, and other protected runtime files
needed by the host. Browser protected state is additionally verified by the
existing browser policy. Configure an explicit existing worker token in the
root-owned worker environment; never print it. Do not add new service credentials
or broader access for this task. Missing policy, changed frozen hashes, changed runtime
contract, or incompatible/irreversible migration stops before promotion.

For irreversible migrations: keep automation paused, make a reviewed backup,
perform an attended forward migration and compatible forward repair, or use an
explicit operator-approved data recovery plan. Reversing source is not proof that
the prior can read current data. Never overwrite current user data automatically.

## Failure evidence and operator recovery

Private host `transaction.json` records candidate/prior SHAs, artifact digest,
backup ID, failing stage/check, recovery outcome, attempts and timings. CI keeps
only whitelisted coarse fields in a one-day health receipt artifact. It fails for
rollback, hold, missing/malformed receipt, wrong revision, protocol mismatch or
transport timeout. It never publishes host paths, raw responses, environment,
credentials, user data or dependency/service logs.

On `held`, interrupted `deploying`/`recovering`, or missing receipt after timeout:

1. Pause new automatic releases using the existing deployment approval control.
   Inspect the private journal and matching backup on the host; avoid blind retries.
2. Confirm all writers are stopped and no second deployment owns the lock. If a
   writer cannot be stopped, repair that condition before replacing source.
3. Verify backup source hashes, identity, immutable browser image availability,
   protected configuration/runtime and data compatibility. Restore only reviewed
   code/image state. Keep current user data and configuration intact.
4. Start the compatible prior or reviewed forward repair, verify exact serving
   revisions and health, and save evidence. Reconcile source policy/last healthy
   receipt and journal under operator review, then reconcile the compatibility epoch.
5. Enable protocol variable only after this bootstrap and checks are approved.

## Local evidence and remaining checks

`python3 -m unittest discover -s tests -p 'test_release_*.py' -v` exercises bounded
gates, stale revisions/nonces, failure receipts and synthetic source/data/config
preservation. `test_promote_transaction.py` runs the real promoter in temporary
paths with fake services/probes, covering successful promotion, partial install,
unhealthy candidate, config drift hold and compatibility rejection before stop.
Existing format-3 packaging and browser release tests cover artifact identity and
immutable image policy. Jac checks cover changed API/worker/gateway/browser source.

These simulations do not certify systemd process shutdown, Docker container
replacement, real Chromium or Jac/PostgreSQL startup timing. An authorized
disposable Linux staging host must run successful update, unhealthy candidate,
readiness timeout, partial install and failed recovery with synthetic credentials
and seeded disposable data before activation. Production migration, phone checks,
live deployment and cold boot remain unexecuted; MAT-31 owns cold boot work.
