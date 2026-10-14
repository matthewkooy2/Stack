# Admission configuration

Stack defaults to closed admission. `agents/contracts.jac` reads the private
`STACK_AGENT_CONFIG` file, or `storage/agents/config.json` when that variable is
unset. A missing file, missing `invite_only` field, or any value other than the
JSON boolean `false` requires an invitation. Strings such as `"false"`, null,
zero, and empty containers do not enable public admission.

To deliberately allow public admission, configure `"invite_only": false` in the
private JSON object. Keep `"invite_only": true` for a closed beta. The committed
`deploy/agent-config.example.json` remains closed. Existing admitted accounts
continue to work with missing or incomplete configuration, subject to the same
permissions, ownership, provider and budget checks. Invitations still use the
operator tool and the existing single-use acceptance flow. Acceptance establishes
a writable graph transaction before consuming a token, so the pinned runtime
can replay its initial read-only transaction before that irreversible step.
Token consumption and graph persistence still use separate stores; an unrelated
commit failure after consumption may require a fresh operator invitation.

An unreadable file, malformed JSON, a non-object JSON value, or invalid numeric
limits rejects configuration-dependent requests. The error tells the operator
to check `STACK_AGENT_CONFIG`, JSON shape and numeric limits without exposing
configured values, the selected private path, or the underlying exception.
Repair the private file; do not change admission to public to work around an
error. This is a request-time check, not startup validation. Configuration is
reread, so removing a public configuration closes admission on subsequent checks.

The gateway obtains the API's admission decision before forwarding personal
calls. API access and worker claim/lease checks use the same configuration.
Recurring scheduling skips denied accounts after its existing maintenance pass,
so one denied account cannot starve invited accounts. Worker token, account ownership and run lease validation remain required. If
admission closes during a lease, further agent-run lease access is denied for uninvited
accounts. Already dispatched external work cannot be undone; restore valid
configuration/admission and use the existing retry/reconciliation flow as
appropriate. Invited accounts retain access; deleted accounts remain denied. Independent
resume/transcription processing, notification delivery, and live-session completion
keep their existing ownership and completion rules; this change does not introduce
a global worker shutdown or cancel already dispatched work.

## Local verification and deployment boundary

Run serially with the pinned Jac runtime, from the worktree root:

```sh
./scripts/jac run --no-serve tests/test_admission_config.py
JAC_TEST_JOBS=0 ./scripts/jac test tests/admission_tests.jac
./scripts/jac run --no-serve tests/test_gateway.py
```

These use synthetic config and isolated accounts, and make no provider calls.
They do not inspect or certify deployed configuration. A later authorized host
verification should confirm API/worker config paths and file permissions,
validate invited/uninvited access through the gateway, and confirm deliberately
public behavior only on an isolated test instance. No live settings or deployment
are changed by this delivery.
