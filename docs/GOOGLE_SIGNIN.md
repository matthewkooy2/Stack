# Google registration and sign-in

Stack uses Jac 0.37.21's existing Google provider and OAuthSession. Google
authorization requests only `openid email profile`. Gmail and Calendar remain
separate optional connections through `/oauth/google` and their existing APIs.

The server reads the existing `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` through
`[scale.sso.google]` in `jac.toml`. Empty values leave the provider disabled. No
credentials belong in source, generated web assets, or the native application.
Set `STACK_SSO_HOST` to the production HTTPS origin and
`STACK_SSO_CALLBACK_URL` to that origin plus `/auth/google`. The existing Google
web OAuth client must allow the exact origin plus `/sso/google/callback` as an
additional redirect; retain its existing `/oauth/google` redirect.

The gateway exposes only `POST /sso/google/begin`, `POST /sso/google/finish`,
`POST /sso/google/poll`, `GET /sso/google/callback`, and the `/auth/google` frontend
callback. Legacy `/sso/google/login` and `/sso/google/register` redirects and other
providers stay private. The gateway needs the same non-secret
`STACK_SSO_CALLBACK_URL` as the API; it does not need Google credentials.

The web client creates a PKCE verifier and keeps its state and verifier in that
tab's sessionStorage for at most ten minutes. It validates the returned state,
clears the callback URL, and exchanges the result with Jac. Stack sessions remain
in memory. The optional Gmail callback parser only processes `/oauth/google`;
it must never consume the identity callback's query.

The native client requests Jac's native OAuthSession mode. Jac creates provider
PKCE and returns a separate one-time poll capability. Safari completes Google
authorization, and the initiating app retrieves its Stack session by polling.
The session and pending capability use SecureStore. Polling pauses while the app
is inactive; cancellation and session changes reject late results. No Stack
session is placed in a browser redirect or a native deep link. The existing
mobile compilation script includes the helper without a new native dependency.

An unlinked Google identity creates its own Stack account and graph root. Repeat
sign-in resolves by Google's stable subject identifier. Email equality does not
merge accounts. To preserve an existing password account, first sign in to that
account and use **Link Google sign-in** in web Account or native Profile. Linking
requires its authenticated, admitted Stack session. Conflicting identities are
rejected, and password sign-in continues to work. This change has no identity
transfer/recovery endpoint and performs no graph or database migration.

Google registration does not bypass beta admission. A signed-in user may check
admission and retry an invitation without repeating provider authorization.
Personal endpoints retain admission checks. Existing production and test
databases, signing keys, account IDs, graph roots, and test deployment stay intact.

## Verification

Use disposable identity storage and fixture provider transport:

```sh
node tests/google_signin_clients.cjs
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac test tests/google_signin_tests.jac tests/google_signin_gateway_tests.jac
jac check agents/gateway.jac web/main.jac mobile/main.jac
jac build --as client workspace
STACK_API_URL=https://stack.example.com jac run --no-serve scripts/compile-mobile.jac
```

These checks cover registration, repeat login, explicit linking and saved-root
preservation, password compatibility, same-email isolation, conflict rejection,
PKCE/state/replay/cancellation, native one-time retrieval, gateway redirect
validation, and invitation admission. Provider requests use mocks; this does not
certify a real Google consent round trip or the installed iPhone binary.

## Production activation requires action-time approval

Merging main can trigger the existing production backend workflow. It deploys
backend source and server configuration, but holds web assets and the signed
iPhone application outside its release. Obtain confirmation for the exact commit
and the following actions before merging or changing persistent authentication:

1. Preserve the current production source/web artifact and record the existing
   release revision. Use the existing protected backup process for state; never
   export credentials or restore an old database during source rollback.
2. Resolve the production origin from the existing `GOOGLE_REDIRECT_URI`, retaining
   its HTTPS hostname and port (currently 8443). Add its exact
   `/sso/google/callback` redirect to the existing Google OAuth client's allowed
   redirects if absent. No new client or credentials are needed.
3. Set only the two non-secret SSO origin/callback settings in
   `/etc/stack/api.env`. Leave both existing Google credential entries untouched.
   Give `stack-gateway.service` only the matching non-secret callback setting,
   through an approved systemd drop-in; do not import the API's credential file
   into the gateway.
4. Merge the reviewed commit and allow its existing backend release, then deploy
   the matching web build through the attended web flow. Restart the API and
   gateway with the approved settings. The automatic backend flow also restarts
   its managed workers; request a brief service interruption without promising
   a fixed duration. Leave the port-8001 snapshot and all phone origins unchanged.
5. Verify service readiness and source/configuration parity without invoking a
   real account login. A real Google registration/login acceptance test needs
   separate explicit authorization. An iPhone rebuild/install is separate work.

Rollback uses the pre-change backend and web source/artifacts and removes the
new SSO settings/drop-in. Preserve current databases, storage, accounts and
identity records, including any accounts created after activation. Existing
Google credentials and `/oauth/google` redirects remain unchanged. Confirm an
exact action bundle again if the candidate or deployment baseline changes.
