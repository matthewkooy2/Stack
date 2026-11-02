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

## Browser Apple sign-in

The web login includes **Continue with Apple**. It uses Apple's official JavaScript
popup SDK without requesting email or name scopes. `auth_apple_web_begin` creates
a five-minute challenge for the configured web Services ID; `auth_apple_finish`
selects the expected audience from that stored challenge, verifies Apple's
signature/issuer/expiry/nonce, and consumes the state once. Native challenges
continue to use the iOS bundle ID. Both modes resolve the same Apple subject into
an ordinary Stack account/session. No Apple private key, client secret, refresh
grant, or extra JavaScript package is added.

### Apple Developer setup

1. Sign in to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list).
   Accept any pending program agreement as the account holder before continuing.
2. Create a **Services ID** for the website, for example `com.matthewkooy.stack.web`.
3. Enable **Sign in with Apple** on that Services ID and configure its **Primary
   App ID** as the existing Stack iOS App ID (`com.matthewkooy.stack`). This grouping
   is required for the website and iPhone to receive the same Apple subject. Do
   not match accounts by email or create a separate ungrouped primary app.
4. Register the website's exact domain and HTTPS return URL, ending in
   `/auth/apple`, then save. Apple does not accept localhost or an IP address as
   the return host. See [Apple's web configuration guide](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/).
5. Set these values on the **API server**, preserving its existing native ID:

   ```sh
   STACK_APPLE_ENABLED=1
   STACK_APPLE_CLIENT_ID=com.matthewkooy.stack
   STACK_APPLE_WEB_CLIENT_ID=com.matthewkooy.stack.web
   STACK_APPLE_WEB_REDIRECT_URI=https://YOUR-REGISTERED-HOST/auth/apple
   ```

   These identifiers/URLs are public configuration, not credentials. Keep completed
   deployment files ignored. Restart the API and gateway with the new build. The
   gateway serves `/auth/apple`, allows only Apple's SDK/CDN origins in its CSP,
   and applies the existing sign-in rate limit to the new public begin endpoint.
   Private worker endpoints remain inaccessible through the gateway.
6. Open the web login, allow its Apple popup, and sign in. Verify that a returning
   iPhone user sees the same saved profile and applications, then sign out and
   sign in again. Password and Google sign-in remain available when web Apple
   configuration is absent; Apple reports a setup error instead of issuing a
   session. A popup-blocked message means the browser needs to allow the popup.

The ordinary `make dev` contributor launcher intentionally clears deployment
integration variables. Use the operator API/gateway launch path with the explicit
configuration above to exercise real Apple sign-in. The popup uses the registered
HTTPS return URL supplied by the server; a local browser preview still needs
Apple's configured web service. Register and verify the intended hosted origin
before treating live browser sign-in as accepted.

### Browser verification

- `node tests/apple_web_clients.cjs`: actual helper with mocked Apple SDK and HTTP
  boundaries; checks state, nonce, popup configuration, cancellation, invalid
  return URLs, missing server setup and overlapping attempts.
- `scripts/jac run --no-serve tests/test_apple_auth.py`: three existing security
  checks now cover native/web audience separation, replay and bad nonce/proof
  rejection, ordinary Stack sessions and native-to-web account/data continuity.
- `scripts/jac run --no-serve tests/test_gateway.py`: existing HTTP boundary checks
  include unauthenticated Apple begin/finish access without weakening admission
  on personal endpoints or exposing worker endpoints.
- A real Apple popup and returning-account check remain separate from fixture
  evidence; locally signed identity proofs do not certify Apple portal setup.

### Setup status for the team hostname

The Services ID `com.matthewkooy.stack.web` (Stack Web) has been registered in
Apple Developer. The proposed primary app is the existing
`com.matthewkooy.stack`, and the proposed team return URL is
`https://stackmvp.top/auth/apple`. The hostname is not yet confirmed as the final
Cloudflare app origin and had no live DNS routing during preparation. The domain
association and live activation remain pending until the domain/HTTPS origin is
confirmed. No existing iOS identifier, native capability or production service
configuration was changed. A subdomain chosen by the hosting setup must replace
the proposed root hostname in both Apple Developer and the API environment.
