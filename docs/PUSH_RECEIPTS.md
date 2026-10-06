# Push tickets, receipts and interrupted work

Stack queues content-free attention notifications when an agent run needs input,
review or other attention. Each notification snapshots the account's registered
devices at first claim. It stores a separate device key, send attempt count,
Expo ticket, receipt attempt count, due time, lease and sanitized outcome for
that device. Device tokens remain encrypted in the existing account-owned
registration nodes; notification records contain no resume, employer, contact,
email content or provider credential.

A send ticket means **accepted by Expo**. A successful receipt means **handed off
to APNs/FCM**, represented as `delivered`; it does not certify iPhone display,
background behavior or user interaction. See [Expo's receipt documentation](https://docs.expo.dev/push-notifications/sending-notifications/).

The authenticated `agent_notification_status` endpoint returns the current
account's notification summaries, or one summary when supplied an `id`. It
exposes per-device outcome and counters, without tokens, keys or active leases.
A notification is `accepted` while any saved ticket awaits its receipt,
`delivered` when all devices have successful receipts, `partial` when at least
one succeeds and another fails or remains uncertain, `failed` when none can
succeed, or `uncertain` when no confirmed success exists and dispatch/receipt
outcome is unknown. Empty device accounts finish as `no_devices`.

## Recovery and retry policy

The API is the single writer. A worker claims one device operation and receives
a 120-second lease. Immediately before sending, it calls
`agent_notification_begin`, which persists the `dispatching` boundary. The
worker saves that device's ticket/result immediately, before claiming another
operation. Callbacks require the correct owner, notification, device key and
lease. An identical repeated finish callback is idempotent; changed, expired
or superseded callbacks cannot alter another result.

- A worker killed before `begin` has not sent anything. After lease expiration,
  the API requeues that device and checks that its registration still exists.
- A worker killed after `begin`, including after provider acceptance but before
  saving a ticket, leaves an **uncertain** outcome after lease expiration. Stack
  does not automatically resend it or claim delivery. Even a kill between
  `begin` and the actual network write is uncertain because no atomic transaction
  spans the database and Expo.
- Once a ticket is saved, recovery polls its receipt and never resends merely
  because the worker died. A kill after reading a receipt but before finishing
  safely causes another receipt read after the lease expires.
- Explicit HTTP 429/500/502/503/504 send failures and `MessageRateExceeded` send
  tickets retry at 30 and 60 seconds, for at most three sends. A rate-exceeded
  **receipt** proves the downstream handoff failed and can requeue sending under
  the same three-send limit. Other provider rejections stop that device.
- Network errors, malformed send responses and missing ticket IDs are uncertain.
  The provider might have accepted the request. Raw exception/provider text is
  never persisted or returned by this lane.
- Receipts first poll after 15 minutes and then every 15 minutes, at most twelve
  reads, including interrupted reads. No receipt within 23 hours is uncertain;
  Expo clears receipts after 24 hours. Receipt transport errors retry reads and
  do not cause a send.
- `DeviceNotRegistered` retires the matching token under that account only,
  whether it came from the send ticket or delivery receipt. Removed devices
  cannot begin a new send. Account deletion removes notifications and devices.

Expo has no transaction or idempotency key shared with Stack. An explicit
server failure may occur after enqueueing, so retrying a 5xx response can cause
a duplicate alert. Operator retry of an uncertain outcome can also duplicate
an already accepted notification. The interrupted-dispatch policy deliberately
leaves that uncertainty visible instead of automatically risking another send.
An already authorized network write can race with token removal/account deletion;
its generic payload must still be checked against the signed-in account on tap.

Existing `sent` records contain acceptance tickets, not delivery proof. They
are migrated lazily to receipt polling. Since legacy tickets lack a device
mapping, a legacy invalid-token receipt cannot safely retire a current device.
Old `dispatched` records recover as uncertain. Preview-imported `cancelled`
notifications stay cancelled and never replay.

## Verification

Run on Linux/WSL using the pinned Jac 0.37.21 runtime:

```sh
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac check agents/notifications.jac agents/worker.jac core/automation.jac main.jac agents/gateway.jac
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_push_notifications.py
JAC_DB_SCRATCH=1 jac run --no-serve tests/test_model_logs.py
```

The suite queues attention through the actual agent APIs, routes the actual
worker's HTTP API calls into `JacTestClient`, uses disposable persistent storage,
and substitutes only a local HTTP provider transport behind the fixed Expo
origin. It reloads storage and kills subprocess workers before send, after
acceptance and before receipt finish. Required scenarios fail if unexecuted;
there are no silent skips or live credentials in CI.

## Live provider and phone acceptance

Live-provider certification is a separate dedicated exercise when an operator
has authorized test credentials and an Expo token belonging to a test account.
No production environment or registered token should be borrowed for fixtures.
Use that test account to register the device, queue one attention run, and drive
`notification_once` in the real worker. Save the account-owned status showing
`accepted` with an Expo ticket, then `delivered` or the actual receipt error after
polling. Record the revision, ticket, elapsed time and provider result without
printing the Expo credential/device token. An accepted ticket alone is not a
passing live receipt exercise.

No live-provider credential is present in the MAT-14 disposable test environment.
The controlled-provider tests do not certify Expo. Physical iPhone foreground,
locked/background delivery and account-safe tap behavior remain the separate
phone acceptance gate in `docs/PHONE_TESTING.md`. This change does not request a
deployment, change signing/provisioning, or enable push for an unconfigured app.
