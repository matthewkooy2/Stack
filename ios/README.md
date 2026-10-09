# Stack for iPhone (SwiftUI)

A native SwiftUI rebuild of the Stack app. The visual language and motion come from the Prep
workflow: a cream palette, one easing curve, staggered reveals, directional page transitions,
press and release feedback, a recording halo, and Reduce Motion support.

It talks to the same backend as the Expo app (`POST /function/<name>` with the existing bearer
session) and does not change that app, its release pipeline or any backend code.

## Build and test (macOS)

Requires Xcode 15.4+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
bash scripts/ci/ios-swift.sh all        # structural checks, generate the project, build, run unit tests
bash scripts/ci/ios-swift.sh static     # the part that needs only Python (any OS)
STACK_API_URL=https://your-stack-api.example bash scripts/ci/ios-swift.sh build
```

Or by hand: `cd ios && xcodegen generate && open Stack.xcodeproj`, then set the `STACK_API_URL`
build setting in Xcode (or pass `STACK_API_URL=https://...` to `xcodebuild`).

`STACK_API_URL` (default `http://127.0.0.1:8000`) becomes the `StackAPIBaseURL` Info.plist key.
The default simulator build is unsigned and uses a distinct bundle identifier (`com.matthewkooy.stack.swift`).
The separately authorized beta upload route overrides this to the existing Stack App Store bundle
(`com.matthewkooy.stack`) and version `0.2.0`, so testers can select the Swift candidate in TestFlight.
It leaves the Expo source and its `0.1.0` release route intact.
Installing the Swift build replaces the installed Expo build on that device because they share the
existing Stack bundle. Swift upload is manual-only: dispatch `Swift candidate TestFlight` on approved
`main` with `upload_native=true`, after review and release coordination. The environment's existing
branch protections remain intact; merging to main can also trigger the existing backend release gate.

CI: `.github/workflows/ios-swift.yml` runs the static checks on Ubuntu and the Xcode build and unit
tests on `macos-14`. It is separate from `ci.yml`: it is not part of the `CI passed` gate and does not
touch the TestFlight workflow.

## Layout

| Path | Purpose |
| --- | --- |
| `Stack/Design` | `Palette`, `Motion` (stage, reveal, tap, pop, halo, breathe) and shared components |
| `Stack/Core` | `JSON`, `APIClient`, Keychain session, `GoogleSignIn` handoff, account models, `AppStore` |
| `Stack/Features/Access` | welcome, Stack sign-in, Google, invitation gate, Google link and recovery |
| `Stack/Features/Jobs` | swipe deck, search filters, saved search, timeline, sources, link import, job detail |
| `Stack/Features/Applications` | list, detail, notes, resume choice, agent help, calendar |
| `Stack/Features/Network` | people, saved contacts, outreach contacts, LinkedIn review |
| `Stack/Features/Resume` | upload, preview, details review, LaTeX format, tailored resumes, experience bank, resume agents |
| `Stack/Features/Prep` | behavioral practice: state machine, WAV recorder, transcription and coaching polling |
| `Stack/Features/Interview` | mock interviews, technical practice, recording and transcription |
| `Stack/Features/Agents` | agent hub, task review and approval, remote browser |
| `Stack/Features/Profile` | profile, matching preferences, follow-up reminders |

## Compatibility

- Prep sessions use the same persisted shape as the Expo client (workflow metadata inside the canvas
  document, numbered question variants mapped to catalog questions), so a session started on either
  client continues on the other.
- Recordings are 16 kHz mono 16-bit PCM WAV, as the transcription service requires.
- Google sign-in uses the existing `OAuthSession` handoff (`/sso/google/begin`, `/sso/google/poll`),
  validates the authorization URL, stores the one-time poll capability in the Keychain, and polls only
  while the app is active.
- Every backend function the app calls is checked against `mobile/feature-rpcs.js` (the list the
  gateway publishes) by `scripts/ci/ios-swift-static.py`.
- Responses for a session that has ended are dropped (`AppStore.call`, `sessionGeneration`), and
  notifications are scoped to the signed-in account.

- Public-profile drafts are local to the signed-in session; sign-out clears them. LinkedIn suggestions
  can be edited, selected, approved and copied. Neither feature publishes text to an external profile.

## Not ported

- Apple sign-in (not connected on any current client or on the backend).
- On-device speech transcripts from the native Stack Speech module. Audio is transcribed by the
  server worker; `transcription_upload` is called without `local_transcript`.
- Push registration (`agent_register_push`, `agent_remove_push`). The backend sends through Expo push
  tokens, which a native app cannot obtain; local reminder notifications are scheduled instead.
- Live voice practice (`prep_live`), which needs the realtime voice service.
- The remote browser's live hidden keyboard. Typing goes through a text field with Send, Backspace,
  Tab and Enter buttons; taps and scrolling are streamed as on the other clients.
- The mock-data preview mode and review/scenario tooling of the Expo app.
- Web-only account tools (data export, account deletion, model logs, traces).
