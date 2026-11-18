# Stack iOS (SwiftUI) build and run

Follow AGENTS.md and ios/README.md. For any SwiftUI screen, also follow [ios/UI_STYLE.md](ios/UI_STYLE.md): the current minimalist blue look, its components and motion rules. The app lives in `ios/`, scheme `Stack`, bundle id `com.matthewkooy.stack.swift`.

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

For an interactive staging session, build, install and launch the locally signed app:

```sh
bash scripts/simulator-on.sh --build
```

The launcher defaults to Rust staging at `https://dev.stackmvp.top`. The simulator keychain stores the login per API origin. For an existing private desktop session, pass `STACK_API_URL=https://ryans-desktop.tailfe312e.ts.net:8443` to the same command.

First build took ~80s. This runs static checks, `xcodegen generate`, then `xcodebuild build` with ad hoc signing. Derived data is persistent and reused, so later builds are incremental; never `clean` or delete it unless a build is genuinely corrupt.

- Derived data: `.jac/ci-ios-swift/DerivedData` (gitignored via `.jac/`); override with `STACK_IOS_DERIVED_DATA`.
- App: `.jac/ci-ios-swift/DerivedData/Build/Products/Debug-iphonesimulator/Stack.app`
- Result bundle: `.jac/ci-ios-swift/build.xcresult` (overwritten each build)

## Run loop

1. Run the launcher above. 2. `control screenshot` to verify. 3. Shut the simulator down when the session ends (see Simulator above).
The first screenshot after launch can be blank white for a few seconds; wait and re-screenshot before debugging.
Skip `all`/`test` runs unless asked or the change warrants it; the `build` route is the default check.

## Backend

`STACK_API_URL` is baked into the build as `StackAPIBaseURL`. The app calls `POST /function/<name>` with a bearer session. The simulator uses the Mac's network. The private desktop override requires Tailscale.

- Sign-in: the user signs in themselves, with username/password or Google. Never type their credentials. The simulator launcher builds without the Apple sign-in entitlement.
- This is real user data. Don't create, edit or delete records on the real API to test UI; ask first.
- Changing the URL requires a rebuild. CI defaults to loopback (`http://127.0.0.1:8000`).
