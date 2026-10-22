# Stack iOS (SwiftUI) build and run

Follow AGENTS.md and ios/README.md. The app lives in `ios/`, scheme `Stack`, bundle id `com.matthewkooy.stack.swift`.

## Simulator

Reuse the existing device "Stack iPhone 16 Plus", ID `68DEB5C0-C366-418B-B07B-2B7B0F8B1020`. Do not create or erase simulators.

```sh
xcrun simctl boot 68DEB5C0-C366-418B-B07B-2B7B0F8B1020   # only if Shutdown; errors harmlessly if already booted
```

In Claude's embedded pane: `control attach` with that device ID, then `control launch` with the .app path below.

This Mac has 8 GB of RAM, and a booted iOS 27 simulator thrashes it (`diskimagesiod` runs at 300%+ CPU and swap fills up). So:

- Only one session drives the simulator at a time. Before booting, installing or launching, check whether another session is already using it (`pgrep -fl 'simctl (boot|install|launch)'`). If one is, wait or ask the user; don't run a second loop on the device.
- Shut the simulator down when you're done with it, including when verification fails. During a UI iteration session, keep it booted between iterations and shut it down when the session ends:

```sh
xcrun simctl shutdown 68DEB5C0-C366-418B-B07B-2B7B0F8B1020
```

## Incremental build (verified)

Build against the real API, signed locally and with the Apple button shown, so the signed-in session in the simulator stays valid:

```sh
STACK_API_URL=https://ryans-desktop.tailfe312e.ts.net:8443 STACK_APPLE_SIGN_IN_ENABLED=YES STACK_IOS_SIGN_LOCALLY=1 STACK_IOS_DESTINATION='platform=iOS Simulator,id=68DEB5C0-C366-418B-B07B-2B7B0F8B1020' bash scripts/ci/ios-swift.sh build
```

Always pass all of these. The login token is saved in the simulator keychain per API origin. A build with a different URL (including the default) shows the signed-out screen, and an unsigned build (without `STACK_IOS_SIGN_LOCALLY=1`) can't read the saved token, so the user would have to sign in again (verified).

First build took ~80s. This runs static checks, `xcodegen generate`, then `xcodebuild build` unsigned. Derived data is persistent and reused, so later builds are incremental; never `clean` or delete it unless a build is genuinely corrupt.

- Derived data: `.jac/ci-ios-swift/DerivedData` (gitignored via `.jac/`); override with `STACK_IOS_DERIVED_DATA`.
- App: `.jac/ci-ios-swift/DerivedData/Build/Products/Debug-iphonesimulator/Stack.app`
- Result bundle: `.jac/ci-ios-swift/build.xcresult` (overwritten each build)

## Run loop

1. Build (above). 2. `control launch` the .app on the device (reinstalls and relaunches). 3. `control screenshot` to verify. 4. Shut the simulator down (see Simulator above).
The first screenshot after launch can be blank white for a few seconds; wait and re-screenshot before debugging.
Skip `all`/`test` runs unless asked or the change warrants it; the `build` route is the default check.

## Backend

`STACK_API_URL` is baked into the build as `StackAPIBaseURL`. The app calls `POST /function/<name>` with a bearer session. The real API is `https://ryans-desktop.tailfe312e.ts.net:8443`, which this Mac reaches over Tailscale (Tailscale must be connected and that desktop serving). The simulator uses the Mac's network.

- Sign-in: the user signs in themselves, with username/password or Google. Never type their credentials. Continue with Apple can't complete, because the build is unsigned and has no Apple entitlement.
- This is real user data. Don't create, edit or delete records on the real API to test UI; ask first.
- Changing the URL requires a rebuild. The default (`http://127.0.0.1:8000`, a local `jac run --dev main.jac`) has no data and no Google sign-in.
