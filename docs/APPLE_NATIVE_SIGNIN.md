# Native Sign in with Apple

This candidate adds a disabled-by-default backend for the Swift application.
It does not activate Jac's browser Apple provider, change Google's endpoints,
create credentials, enable Apple capabilities, deploy, or merge. Swift wiring is
held for the independent Swift UI PR56 to land, then reviewed against its final
head. Expo is not a second client implementation in this change.

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

Set `ASAuthorizationAppleIDRequest.nonce` to the nonce exactly as returned (it
is already SHA256), and `request.state` to the returned state. Request
`.fullName` and `.email`; format the initial `credential.fullName` as optional
display metadata. Send UTF-8 `credential.identityToken` and
`credential.authorizationCode` over the configured HTTPS API. Check returned
credential state. On cancellation, discard the challenge and display no failure;
expired challenges cannot be reused. Keep state/nonce in memory for the one
operation and clear on sign-out, origin/session change, failure or completion.

Swift integration must use Apple's official `SignInWithAppleButton`. Its next
patch adds `Core/AppleSignIn.swift` and a small `AppStore` method: capture the
store and API session generations, begin native authorization, finish, verify
both generations are unchanged, adopt the returned Stack token, and run the
existing `completeLogin()` invitation/admission/bootstrap flow. A callback after
sign-out must never adopt a token. Returning users commonly supply no name/email;
this must not block login or erase previously captured metadata.

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
6. Review the native patch after PR56 lands. Run Mac CI compilation/unit/UI
   checks, then a signed-device test with cancellation, first sign-in with name
   and relay email, returning login, explicit link conflict, unadmitted deletion,
   deletion retry and credential revocation. Use
   `getCredentialState(forUserID:)`/revocation notification to clear local Apple
   sessions when authorization is revoked; do not persist Apple ID tokens as
   Stack sessions. Provider server-to-server event handling and periodic grant
   validation are a separate activation requirement for prompt remote revocation
   of already-issued long-lived Stack sessions.
7. Coordinate merge/backend rollout with the parent because main CI can deploy
   the existing backend. No production deployment or merge is authorized here.

## Verification

Offline tests use ephemeral keys and synthetic subjects/accounts; no Apple
account or persistent credential is touched. Run
`python -m unittest discover -s tests -p test_apple_auth.py` and pinned
`jac check main.jac agents/gateway.jac`. Contributor offline CI includes the Apple
suite and gateway tests. Independent review covers claim validation, replay,
identity conflicts, persistence failures, partial Jac writes and deletion races.
Windows test success does not constitute Xcode verification; native checks wait
for the reviewed Swift patch and Mac CI.

Primary references: [Apple token verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user),
[native authentication](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple),
[account deletion and revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple),
and [Apple's credential lifecycle guidance](https://developer.apple.com/videos/play/wwdc2022/10122/).
