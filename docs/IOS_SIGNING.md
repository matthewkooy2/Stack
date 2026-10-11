# Reusable TestFlight signing

Both upload workflows restore an approved Apple Distribution identity and an
App Store provisioning profile on each runner. They use manual signing for
archive/export. They do not request provisioning updates or use the ASC API key
to create certificates/profiles. The existing API key still performs preflight,
upload and processing checks. Unsigned PR/simulator checks need no signing assets.

## Secure user handoff

In repository Settings > Environments > `stack-testflight` > Environment secrets,
the authorized owner must enter these three secrets directly:

| Secret | Asset |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 of a password-protected `.p12` containing an approved Apple Distribution certificate **and its matching private key** |
| `IOS_DISTRIBUTION_P12_PASSWORD` | The export password for that `.p12` |
| `IOS_APP_STORE_PROFILE_BASE64` | Base64 of the approved iOS App Store distribution `.mobileprovision` for `com.matthewkooy.stack`, including that certificate |

Do not paste keys, passwords or encoded assets into chat, commits, logs, artifacts
or agent tools. The owner performs export, encoding and secret entry on a trusted
machine. Preserve `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `STACK_API_URL`
and the existing `APPLE_TEAM_ID` variable. No additional keychain password secret
is needed; every job generates one locally.

The shortest path is to reuse an existing valid distribution certificate whose
matching private key is already held on a trusted Mac or in an approved protected
`.p12` backup. No new certificate is needed in that case. A cloud-managed
certificate with no exportable local key cannot satisfy this workflow.

1. On the trusted Mac, open **Keychain Access > login > My Certificates**. Find
   the approved **Apple Distribution** identity, confirm it is unexpired and
   expands to show a private key. Select the certificate and matching key, then
   **File > Export Items**, choose **Personal Information Exchange (.p12)**, and
   set a strong export password. The owner performs this directly; agents must
   not inspect the key. The current Mac is offline, so wait for it or use another
   authorized machine/approved protected backup holding that identity.
2. Open [Apple Developer > Certificates, Identifiers & Profiles > Profiles](https://developer.apple.com/account/resources/profiles/list).
   Reuse and download an unexpired **App Store Connect** distribution profile
   for the explicit App ID **com.matthewkooy.stack**, the existing Apple team,
   and the selected distribution certificate. It must include the app's enabled
   capabilities. Both release routes upload this same bundle ID; the simulator
   default `com.matthewkooy.stack.swift` is not the release profile's App ID.
   If no matching profile exists, obtain approval specifically to create it;
   then an Account Holder/Admin selects **Profiles > + > Distribution > App
   Store Connect**, chooses that explicit App ID and certificate, names the
   profile, generates it and downloads it. Do not choose Development or Ad Hoc.
3. Privately encode each file on the owner's Mac. For example, the owner can run
   `base64 -i /private/path/distribution.p12 | pbcopy`, then paste directly into
   the certificate secret below, and repeat with the `.mobileprovision` file for
   the profile secret. Do not print, send or paste these values into agent tools
   or chat. Keep the protected backup under the owner's approved storage policy.
4. Open [Stack repository environment settings](https://github.com/matthewkooy2/Stack/settings/environments),
   select **stack-testflight**, then **Environment secrets > Add secret**.
   Add the encoded `.p12` as `IOS_DISTRIBUTION_P12_BASE64`, its export password
   as `IOS_DISTRIBUTION_P12_PASSWORD`, and the encoded downloaded profile as
   `IOS_APP_STORE_PROFILE_BASE64`. Leave the existing API configuration intact.
   GitHub accepts the values through this page; agents receive only completion
   confirmation, never the values.
5. Parent reviews the exact candidate and coordinates merge and one specifically
   approved release. **The existing Expo main-push route is enabled**, so merging
   this change can immediately start an Expo upload after preflight. Coordinate
   the release gate before merging, not afterward. Swift upload remains an
   explicit workflow dispatch with `upload_native=true`. Do not rerun historical
   revisions that retain automatic provisioning.

If the private key is missing, first have the owner inspect trusted original
machines and approved protected backups. A `.cer` download or ASC `.p8` cannot
recover that key. If no approved recoverable identity exists, stop signing and
request approval to create **one Apple Distribution certificate/private-key
pair** and its matching **App Store Connect profile**. After approval, the owner
creates a CSR on the trusted Mac using **Keychain Access > Certificate Assistant
> Request a Certificate from a Certificate Authority > Saved to disk**, then
uses **Apple Developer > Certificates > + > Apple Distribution** to issue the
certificate from that CSR. Download/install it on the CSR's Mac, export the
resulting identity as `.p12`, and complete steps 2–4. Do not revoke an existing
certificate to make room; any quota-driven revocation needs an inventory and
approval for the exact certificate, including the impact on its other users.

For read-only inventory, record certificate type, serial/fingerprint, expiry and
owner/use; profile name, UUID, expiry, team and bundle ID. Do not record private
key material. Current certificate count and key recoverability remain unknown.

Verified instruction sources: [Apple keychain export](https://support.apple.com/guide/keychain-access/import-and-export-keychain-items-kyca35961/mac),
[Apple App Store Connect profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/),
[Apple CSR creation](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/),
and [GitHub environment-secret setup](https://docs.github.com/actions/security-guides/using-secrets-in-github-actions).

## Runner lifecycle

`scripts/ci/ios-signing.py prepare` imports into a temporary keychain under
`RUNNER_TEMP`, preserves the user keychain search list, grants codesign access,
and installs the profile under its UUID. It validates expiry, team, exact bundle
ID, iOS App Store type and a matching valid distribution identity with a private
key. App ID prefixes may differ from Team ID for older accounts.

The archive pins that identity and profile (Expo scopes the profile to its generated application target so CocoaPods targets remain profile-free); export pins the same fingerprint and
bundle/profile mapping. The temporary keychain is in the search list for export.
An `always()` cleanup step deletes the temporary keychain and installed profile,
including after partial preparation failure. If keychain deletion fails, it still
removes the profile and decoded asset files and reports incomplete cleanup; the
failed keychain remains at its exact run-local path for owner cleanup/retry. It refuses to overwrite an existing
profile. Signing assets are never retained as artifacts. Job cleanup cannot run
after a runner crash; dispose of the runner or have its owner remove the exact
temporary assets before reuse. These workflows assume a clean ephemeral runner.

For renewal, the owner replaces the approved secret assets before expiry. If
new app extensions or capabilities are added, review their required entitlements
and explicit provisioning mappings before a release.

## Inspection and verification evidence, 2026-10-11

Base: `f9acbaebebb6a6583942d2553298141094fa9a87` (PR69 merged).
Repository secret names: `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY`.
`stack-testflight` environment secret names: `STACK_API_URL`.
Repository variable names: `APPLE_TEAM_ID`, `STACK_RELEASE_FORMAT`,
`STACK_TESTFLIGHT_ENABLED`; environment variable list was empty.
Only names/update metadata were inspected; no secret values were retrieved.
The three reusable signing secrets were absent at inspection time. A subsequent
read-only check confirmed the non-secret `STACK_TESTFLIGHT_ENABLED` variable is
`true`. The environment has a branch restriction but no required-reviewer rule;
merging this patch can automatically start the Expo release after preflight.

The delegated diagnosis reports build `1011.1` / run `38089811592` failed during
development signing at archive, before export/upload; last success `1010.1`.
Current certificate counts and recoverable private-key ownership are unknown.
Apple portal inventory has not been authenticated or inspected in this task.
An authorized portal login is needed for that read-only inventory; no quota
remediation or certificate revocation is authorized by the workflow change.

Local configuration tests use fictional bytes and mocked `security` calls.
They establish validation, manual export mapping, fail-closed behavior, search
list preservation and cleanup logic. They cannot prove actual macOS keychain
import, Xcode archive/export or Apple acceptance. Existing macOS-only release
tests remain required on macOS; a signed release is gated on secure handoff and
parent approval. No release run or signing-state mutation was performed here.

Reference: [GitHub's macOS certificate/profile installation guidance](https://docs.github.com/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development).
