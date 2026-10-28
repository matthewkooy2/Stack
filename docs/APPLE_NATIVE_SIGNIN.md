# Native Apple sign-in

Apple sign-in has three responsibilities:

1. Verify Apple's identity proof, including its signature, app audience, expiry,
   issuer and the one-use sign-in challenge.
2. Find the Stack account by Apple's stable subject, or create it on first sign-in.
3. Issue the same Stack session used by other sign-in methods.

The iPhone uses Apple's official sign-in button and AuthenticationServices sheet.
The optional Google-account metadata lookup cannot block loading a Stack session.
`auth_apple_begin` returns a five-minute challenge; `auth_apple_finish` verifies the
identity token and returns `ok`, `token` and `username`. The finish endpoint still
accepts the old optional `authorization_code` and `name` arguments for installed
clients; neither is used. Existing Apple subject-to-account mappings are preserved.

Only `STACK_APPLE_ENABLED=1` and `STACK_APPLE_CLIENT_ID=com.matthewkooy.stack` are
needed by the backend. Apple public keys are fetched from
`https://appleid.apple.com/auth/keys`; the existing google-auth library checks JWT
signatures, audience and expiry. No Apple private key, client secret or stored
Apple refresh grant is used. The native build needs the matching bundle ID and
`Stack/StackApple.entitlements`, with `STACK_APPLE_SIGN_IN_ENABLED=YES`.

Apple-specific account linking/deletion, refresh, revocation notifications,
session versions, request preflights, persistent locks and crash recovery have
been removed. Apple sessions now follow normal Stack session behavior. The
Apple-specific account deletion control is removed; password-confirmed Stack
account deletion is unchanged. Old Apple grant/state/lock rows are no longer read
or written; this change does not delete stored account data.

## Verification

Run `scripts/jac run --no-serve tests/test_apple_auth.py` with `JAC_DB_URL` unset.
Exactly three tests use real disposable Jac storage and normal Stack sessions:
valid sign-in, returning sign-in preserving account/data, and invalid proof
rejection. Only Apple's public-key network response is replaced, using an
ephemeral RSA key; signature and identity verification execute normally.

Run `scripts/jac check main.jac agents/gateway.jac` and the existing Swift build
checks. A real signed-device login is separate evidence: install the matching
backend and native app, continue with Apple, then sign out and sign in again to
confirm the same account returns. Automated fixtures do not prove this step.

### Verified development build — October 27, 2026

The three tests passed against disposable storage. Jac checks, Swift structural
checks, the simulator compile and the signed physical-iPhone compile passed.
A real Apple authorization from the paired iPhone was verified using Apple's
live public keys and created one Stack account in the disposable backend. An
optional Google-status lookup initially blocked the app after session issuance;
that lookup is now nonblocking. The corrected device build reused the Apple
session and successfully loaded authenticated admission and account endpoints.
This evidence covers the local development build, not a TestFlight rollout.
