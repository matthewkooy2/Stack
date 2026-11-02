# Google registration and sign-in

Stack uses Jac 0.37.21's existing Google provider and OAuthSession. Google
authorization requests only `openid email profile`. Gmail and Calendar remain
separate optional connections through `/oauth/google` and their existing APIs.

In the Swift iPhone app, Applications → **Connect Gmail** starts optional read-only
consent and automatically enables application tracking when consent completes.
There is no separate rules toggle, daily limit or permission save. Tracking stays
on until Google is disconnected or access becomes unavailable. Denied or partial
consent never enables it. Existing active Gmail read policies remain compatible.
Email & calendar shows tracking status; sending, calendar and disconnect controls
live under **Advanced settings**. Sending and calendar changes retain their own
permissions and per-action approval. This flow requires both the updated app and
backend. Completing real Google consent and checking resulting application
updates on an iPhone are still required for release acceptance.

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

## Swift iPhone sign-in and app links

The Swift app now presents Google's pages in `ASWebAuthenticationSession`, using
the normal browser session so a signed-in Google account can be reused. It opens
`/auth/google/start?url=...` on the same gateway. That route accepts only Google's
identity-only authorization URL with the configured server callback and S256,
then sets a ten-minute Secure, HttpOnly, SameSite=Lax cookie bound to OAuth state.
After Jac processes the callback, a matching cookie returns the sheet to
`com.matthewkooy.stack://auth/google?state=...`. The sheet checks the returned state,
dismisses, and retrieves the Stack session through the existing one-use poll
capability. Neither a Google credential nor a Stack session appears in that URL.
Closing the sheet cancels quietly. Responses from cancelled attempts cannot
adopt a session or reset a newer attempt. Existing web and Expo flows retain
their original callbacks; ordinary browsers get a styled Continue in Stack page.

`/open`, `/open/jobs`, `/open/applications`, `/open/resume`, `/open/network` and
`/open/prep` have matching custom-scheme links and iOS Universal Links. Links only
navigate; a signed-out user still signs in and passes admission before opening a
screen. The AASA document is served as JSON at
`/.well-known/apple-app-site-association` and claims only `/open` paths, never
OAuth callback routes. The signed app includes `applinks:stackmvp.top` and
`applinks:dev.stackmvp.top`. Enable Associated Domains on the existing App ID
and refresh its provisioning profiles before building a release.

The gateway injects Apple's Smart App Banner into the web entry page and app-link
fallback, using the verified App Store record `6820196890` for
`com.matthewkooy.stack` (App Store Connect display name `StackThatYeah`). Set
`STACK_APP_STORE_ID` to override that ID. The URL uses the HTTPS origin from
`STACK_SSO_HOST` or the gateway's existing `STACK_SSO_CALLBACK_URL`. Apple does
not show its banner for an app unavailable in the App Store, including a
TestFlight-only app; the custom Continue in Stack button works independently.
Safari can keep same-domain Universal Links in the browser, so the visible
fallback button uses the registered custom scheme.

`/about` is a public description of Stack with app/web links and a privacy link;
it avoids using an account login form as Google's application homepage.
`/privacy` is an unauthenticated, static explanation of Stack's identity,
optional Google connections, stored career/interview material and account
controls. It ships with the backend source, without requiring a frontend rebuild.

### Google configuration, November 2, 2026

In the existing Stack Google Cloud project `serious-house-510618-m7`, the app
name remains Stack; its existing iOS icon, public homepage
`https://dev.stackmvp.top/about` and privacy URL `https://dev.stackmvp.top/privacy` were
saved. Publishing status was changed from Testing to In production at the
user's explicit request. Existing OAuth clients, credentials, redirect URIs and
Gmail/Calendar scopes were retained. Google requires separate verification for
the logo and any sensitive/restricted permissions. Production publishing alone
does not establish verification approval or a warning-free consent screen.
The privacy route must be deployed before submitting brand verification.

Google's first automated branding check reported domain ownership, the former
login-only homepage and the unavailable privacy page. A domain-verification TXT
record was added to the existing Cloudflare zone and observed in public DNS;
Google Search Console initially still saw cached DNS. Complete that ownership
check, deploy `/about` and `/privacy`, and wait the 24 hours Google requests after
ownership verification before retrying branding. This is ownership verification,
not SEO setup, an indexing request or a marketing-site launch.

The existing Apple App ID `com.matthewkooy.stack`, prefix `38BZ2B7677`, now has
Associated Domains enabled. The development signing profile was refreshed by a
successful signed-device build. The existing Stack App Store distribution
profile was regenerated with the same distribution certificate, validated for
the app ID, Apple sign-in and Associated Domains, and saved to the existing
`stack-testflight` environment's `IOS_APP_STORE_PROFILE_BASE64` secret. No new
certificate, signing private key or release workflow was created.

### Candidate checks

Use `python3 -m unittest discover -s tests -p test_app_links.py` for app-link,
banner and authorization-start validation; the existing
`scripts/jac test tests/google_signin_gateway_tests.jac` covers real HTTP
start/return, legacy fallback and private-route restrictions. Run
`scripts/jac run --no-serve tests/test_gateway.py` for admission regressions.
Native manual selection: `StackTests/GoogleAuthSessionTests`,
`StackTests/GoogleSignInTests` and `StackTests/AppStoreSessionTests`. No CI gate
or blocking test selection is added by this change.

Release acceptance still requires a real Google sign-in and cancellation on the
signed iPhone, return to the same existing account, registration through
admission, a cold/warm app-link tap, and inspection of the publicly deployed
privacy and AASA routes. Build success and fixture tests do not prove those.

Google's verified email is normalized and stored as a unique account identity.
An unlinked Google identity reuses the account with that email, including an
Apple account that shared the same address. Repeat sign-in also resolves by
Google's stable subject. Apple's Hide My Email relay does not reveal the real
address, so it cannot be matched to a different Google address automatically.
Existing conflicting accounts are not silently merged or deleted. Explicit
linking and password sign-in remain available; stored account data is preserved.

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
