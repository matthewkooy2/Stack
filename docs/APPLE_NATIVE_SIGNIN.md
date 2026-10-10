# Native Sign in with Apple

This candidate adds disabled-by-default native Swift sign-in and its verified
backend. It preserves Google's endpoints and does not activate Jac's browser
Apple provider. The isolated branch incorporates reviewed main `612417f`
(PR56 and PR58); its merge remains held for parent release coordination.
No credential, live capability, deployment or production merge was performed.
Expo is not a second client implementation in this change.

## Client contract

All calls use the existing `POST /function/<name>` envelope and
`APIClient.call`. Begin/finish errors contain `ok:false`, a stable `code`, and a
safe `error` string. No provider tokens or Apple subject appear in responses.

| Endpoint | Authorization and arguments | Result |
| --- | --- | --- |
| `auth_apple_begin` | Public, no arguments | `ok`, secret `state`, `nonce`, `expires_in:300` |
| `auth_apple_finish` | Public: `state`, `identity_token`, `authorization_code`, optional `name` | `ok`, Stack `token`, `username` |
| `auth_apple_link_begin` | Existing Stack session; same-root `username`, `password` confirmation | Same challenge |
| `auth_apple_link_finish` | Same Stack session: proof fields and optional `name` | Same root's Stack session |
| `auth_apple_delete_begin` | Existing Stack session | Same challenge, bound to account root |
| `account_delete_apple` | Same session: `state`, `identity_token`, `authorization_code` | `deleted:true` after revocation/cleanup |

The gateway also exposes `POST /auth/apple/notifications` with Apple's exact
`{"payload":"<signed JWT>"}` body. Its private upstream `auth_apple_session`
preflight is internal and cannot be called through the public function allowlist.

Set `ASAuthorizationAppleIDRequest.nonce` to the nonce exactly as returned (it
is already SHA256), and `request.state` to the returned state. Request
`.fullName` and `.email`; format the initial `credential.fullName` as optional
display metadata. Send UTF-8 `credential.identityToken` and
`credential.authorizationCode` over the configured HTTPS API. Check returned
credential state. On cancellation, discard the challenge and display no failure;
expired challenges cannot be reused. Keep state/nonce in memory for the one
operation and clear on sign-out, origin/session change, failure or completion.

Swift uses Apple's official `ASAuthorizationAppleIDButton` through
`AppleAccountButton`, plus `Core/AppleSignIn.swift` and small `AppStore` methods.
It captures store/API session generations, begins authorization, finishes,
checks both generations, adopts the returned Stack token, and runs the existing
`completeLogin()` invitation/admission/bootstrap flow. A callback after sign-out
cannot adopt a token. Returning authorization without name/email preserves the
previously captured metadata.

Apple subject is the sole provider identity key. Verified email, including
Hide My Email relay addresses, is metadata, never an identity lookup or merge
key. Explicit linking currently requires a known Stack password. Google-only
accounts without one must use their existing recovery/password setup before
linking; no guessed-email fallback is permitted. One Apple subject per Stack
account is supported. Switching Apple identities requires a separate reviewed
unlink/relink design; this candidate does not silently replace an identity.

Deletion requires account ownership, not beta admission. A fresh Apple proof
can recover deletion when a saved grant is missing/unreadable. Password deletion
also revokes linked Apple grants. Provider unavailability leaves the account
intact for retry. Product APIs retain their beta admission checks.
Deletion enters an explicit writable Jac unit before consuming proof or revoking
tokens: the pinned runtime can otherwise replay a newly discovered writer after
it consumed the one-use proof. `finally` balances the unit even when transaction
upgrade raises. Real-storage tests assert one provider exchange and balanced
request units. A later serialization conflict can fail closed after consuming
proof; retry starts with fresh authorization, not a reused code/challenge.

## Security boundary and persistence

The server validates a fixed-origin Apple JWKS RSA signature, exact `RS256`,
issuer, one configured audience, expiry, issuance time and server nonce. It
rejects duplicate JSON members, unexpected critical JWT headers, wrong subjects,
noncanonical encodings and replayed/expired challenges. The authorization code
is exchanged at Apple's fixed token endpoint with a short-lived ES256 client
secret; exchange identity must match the native subject. A refresh grant must be
encrypted and persisted before an identity is linked or a Stack JWT is issued.

Challenges use Jac's atomic `AuthTokenStore` consume operation. Encrypted grants
live in `kv_state` as `stack-apple-grant:<user_id>`, use the existing connection
encryption key, and are erased after successful identity deletion. Existing
sessions/root IDs and other linked providers are retained. Interrupted Jac SSO
lookup/document writes are reconciled before issuing a session, and grant-backed
revocation does not depend on a complete identity document.

Cross-worker subject/account locks use `kv_state` and never expire during slow
deletion. Locks are released in `finally`. If a worker dies, sign-in/link/deletion
fails closed for that key. Operator recovery must first confirm the original
worker is stopped and no operation remains active, inspect the specific
hashed `stack-apple-lock:` key, and remove only that abandoned lock under a
separately approved operational action. Do not bulk clear locks or grants.

## Precise activation gates (approval required)

1. Confirm the actual signing bundle ID. The upcoming signed TestFlight build
   uses the existing `com.matthewkooy.stack`; the Swift developer default
   `com.matthewkooy.stack.swift` is a different audience. Configure one intended
   bundle ID per environment; do not accept arbitrary client-supplied audiences.
2. In the intended Apple Developer team, enable Sign in with Apple for that
   explicit App ID. Regenerate the matching distribution/development provisioning
   profiles and add `com.apple.developer.applesignin = [Default]` to the Swift
   target's entitlements. These live capability/profile changes require explicit
   action-time approval. Neither has been performed here.
3. Obtain approval to select an existing Sign in with Apple key or create a new
   one tied to that primary App ID. Record its Team ID and Key ID. The private
   `.p8` must be handed directly to the server's secret store; never paste it into
   chat, Git, PR text, workflow logs or client builds. No credential was created.
4. Supply server-only `STACK_APPLE_CLIENT_ID`, `STACK_APPLE_TEAM_ID`,
   `STACK_APPLE_KEY_ID`, `STACK_APPLE_KEY_FILE` (path to the securely mounted key),
   and the existing `STACK_CONNECTION_KEY`. Restrict key-file access to the API
   service account. Preserve encryption-key backups/rotation access needed for
   existing grants; no new encryption key is generated by this candidate.
5. Confirm Jac's durable shared identity database and challenge store, then set
   `STACK_APPLE_ENABLED=1` only after the approved Swift patch and tests land.
   Missing configuration fails closed. Browser `scale.sso.apple` remains unset;
   no Services ID/website redirect is required for this native-only code flow.
6. The native patch is based on reviewed main `612417f`. Run Mac CI compilation/unit/UI
   checks, then a signed-device test with cancellation, first sign-in with name
   and relay email, returning login, explicit link conflict, unadmitted deletion,
   deletion retry and credential revocation. Use
   `getCredentialState(forUserID:)`/revocation notification to clear local Apple
   sessions when authorization is revoked; do not persist Apple ID tokens as
   Stack sessions. Provider server-to-server event handling and periodic grant
   validation are implemented as described below. Notification delivery requires
   a publicly reachable HTTPS endpoint ending `/auth/apple/notifications`;
   private-only HTTPS is not reachable by Apple's servers. Register an approved
   public endpoint in the primary App ID configuration only after separately
   approved ingress deployment. Native authorization and daily server validation
   use outbound Apple requests and do not require public ingress. A private-only
   rollout requires an explicitly accepted up-to-24-hour server revocation delay;
   prompt notification-based revocation requires public notification-only ingress.
   Neither policy acceptance nor network changes are authorized by this code.
   Signed-device acceptance follows an approved
   test deployment; it is not a prerequisite for merging disabled code.
7. Coordinate merge/backend rollout with the parent because main CI can deploy
   the existing backend. No production deployment or merge is authorized here.

## Verification

Offline tests use ephemeral keys and synthetic subjects/accounts; no Apple
account or persistent credential is touched. Run
`python -m unittest discover -s tests -p test_apple_auth.py` and pinned
`jac check main.jac agents/gateway.jac`. Contributor offline CI includes the Apple
suite and gateway tests. Independent review covers claim validation, replay,
identity conflicts, persistence failures, partial Jac writes and deletion races.
Windows test success does not constitute Xcode verification; native checks run
in the separate unsigned Mac CI workflow.

## Remote revocation and session policy

Apple-issued Stack JWTs carry a signed `stack_apple` epoch. Google/password
sessions keep Jac's ordinary claims. The public gateway checks every authenticated
product, admission, browser stream and Google linking request through the private
preflight before forwarding it. Keep the Jac writer on loopback; exposing it
directly would bypass gateway enforcement. A revoked or mismatched Apple epoch
returns 401. Configuration/storage/provider outages fail closed with 503 and do
not clear otherwise valid sessions. Confirmed refresh `invalid_grant` rotates the
epoch; other provider failures never infer consent revocation.

Every fresh Apple authorization also rotates the epoch, invalidating older Apple
sessions while preserving the same root and Google/password sessions. The epoch
is persisted before the saved grant is replaced, so a partial metadata/identity
failure cannot extend an older JWT's cached 24-hour validation window. Only the
newly issued Stack JWT is usable after a successful reauthorization.

Active Apple sessions validate their saved refresh grant when its last successful
exchange is at least 24 hours old. The returned identity must match the stored
subject and exact audience. There is no network refresh on every product call.
Signed server notifications provide prompt revocation between daily checks.
RS256 signature, issuer, audience, issuance time, event subject/type/time and
notification ID are validated. Notifications older than 30 days fail closed;
older replayed events cannot revoke a newer authorization. Retry lock/configuration
or storage failures with 503; only conclusively invalid payloads receive 400.
Notification bodies are capped at 20KB before reading them.

Durable hashed-subject revocation watermarks cover events arriving before first
account mapping, failed user-lock acquisition, and proof exchanged before account
deletion. Preflight and reauthorization reconcile these watermarks under shared
locks, so a new grant cannot revive an old session epoch. Deletion records a
tombstone before removing the identity. Apple `account-deleted` revokes Apple
sessions; it does not automatically delete an independent Stack account or its
Google/password identities. Email events record forwarding status in lifecycle
metadata without using email as an account identity.

Owner deletion routes bypass the Apple grant/epoch preflight so a missing grant
can recover with fresh Apple proof. Jac's signed session/root ownership and the
fresh-proof or password confirmation remain required. No product API exemption
is added. Provider outages preserve the account for a retry.

## Native build and session behavior

`AppleSignIn.swift` wraps Apple's official `ASAuthorizationAppleIDButton` so
Stack can request its challenge asynchronously before presenting the Apple sheet.
The request passes the server's already hashed nonce unchanged and verifies the
returned state before sending the proof. Cancellation is quiet; sign-out and
session replacement invalidate pending results. Only the verified Stack token
is adopted, followed by the existing `completeLogin` admission path.

The initial name is optional; returning authorization need not supply it. Apple
ID tokens/codes are not persisted on the device. The origin-scoped Keychain
records the Apple user identifier and a SHA-256 fingerprint of its exact Stack
session solely for credential lifecycle checks. Checks run on startup,
foreground/refresh and Apple's revocation notification; offline errors preserve
the session. Confirmed revocation clears it. A subsequent Google/password
session cannot be signed out by stale Apple metadata.

New login/link controls default off via `STACK_APPLE_SIGN_IN_ENABLED=NO`.
Existing Apple sessions retain deletion access when that flag is disabled.
After live setup approval, build with `STACK_APPLE_SIGN_IN_ENABLED=YES` and
`STACK_APPLE_ENTITLEMENTS=Stack/StackApple.entitlements`, and the exact approved
bundle identifier. The empty default entitlement setting preserves current
provisioning requirements. Do not remove Apple capability from a shipped app
while existing Apple users need native reauthorization/deletion.

The signed-in account card requires that account's Stack username/password for
explicit linking. Google-only accounts must first use the existing recovery
path to their original Stack account; Apple-only accounts do not know the random
internal password and instead use fresh Apple proof for deletion. The destructive
confirmation precedes fresh proof and deletion remains available before beta
admission. Provider revocation/cleanup failure preserves the session for retry.

Primary references: [Apple token verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user),
[native authentication](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple),
[account deletion and revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple),
and [Apple's credential lifecycle guidance](https://developer.apple.com/videos/play/wwdc2022/10122/).
