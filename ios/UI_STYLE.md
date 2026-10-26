# Stack iOS UI style

This is the look to build new screens in and to move old screens toward. It was set on the launch, login and Prep
screens. Read it before adding or restyling any SwiftUI.

## Where it is applied

New look (use these as the reference): launch sequence, `Features/Access/AccessView.swift` (welcome, sign in,
create account), `Features/Prep/PrepScreens.swift` with `PrepView.swift`, and the Resume tab's first-use screen
(`Features/Resume/ResumeUploadScreen.swift`), the Jobs deck (`Features/Jobs/JobCard.swift`, `JobsView.swift`) and the Network tab
(`Features/Network/NetworkView.swift`, `PresenceView.swift`). The populated Resume view is still the old look.

Old cream look (still in place, restyle only when asked): Applications, Resume (once a resume exists), Profile, the Interview and
Practice sheets, and the sheets opened from Jobs and Network (requirements, job details, sources, import, discovery, public profiles). These use `Palette` and the components in `Design/Components.swift`.
`ios/README.md` still describes the cream palette; that is the old look, not the target.

Do not restyle a tab you were not asked to touch. Do not mix the two looks on one screen, except for the tab bar,
which already follows the active tab.

## Principles

1. One thing to read and one thing to tap per screen. The user should have to think as little as possible.
2. Big type, lots of space, no cards, no borders around content. Separate rows with a one point hairline.
3. One accent colour, blue, used for the main action and for small labels. Everything else is black, grey or white.
4. Say less. A headline, at most one line of detail, one main button, and at most two quiet links. If a screen
   needs more, put the rest one tap away (an expanding row, a "Your answer" link, a sheet).
5. Motion is smooth and continuous: nothing pops, flashes or jumps, and elements never swap mid-air.
6. No jargon from the backend on screen. Never write "worker", "queue", "run" or "revision" for the user.

## Colours

Use `Brand` (in `Design/StackMark.swift`), never raw hex in a view.

| Token | Hex | Use |
| --- | --- | --- |
| `Brand.page` | `F5F3F0` | Every screen background, set with `.background(Brand.page.ignoresSafeArea())` |
| `Brand.ink` | `111111` | Headlines and primary text |
| `Brand.accent` | `2563FF` | Main button, small labels, filled score dots, links that act |
| `Brand.muted` | `5E5C58` | Secondary text and quiet links |
| `Brand.rule` | `DAD7D2` | Hairlines, empty dots, outlines |

White (`Color.white`) is used for text fields, the back button and the Google button. Errors use `Palette.danger`.
Do not add new colours. A zero or failing score is `Palette.danger`; nothing else is red.

## Type

System font, tight and heavy for headlines.

| Role | Spec |
| --- | --- |
| Hero or question | `.system(size: 36, weight: .heavy)`, `.tracking(-1.8)`, `minimumScaleFactor(0.6)` |
| Screen title | `.system(size: 36, weight: .heavy)`, `.tracking(-1.8)` |
| Large number (timer) | `.system(size: 64, weight: .heavy).monospacedDigit()`, `.tracking(-2)` |
| Row title | `.system(size: 20 to 22, weight: .semibold)`, `.tracking(-0.5)` |
| Small label | `.system(.subheadline).weight(.semibold)`, in `Brand.accent` or `Brand.muted` |
| Body and detail | `Typeface.body` or `Typeface.caption`, in `Brand.muted` for detail |
| Button | `.system(.headline).weight(.semibold)` |

Long text is never set in headline type. Cut it to a sentence (see `CoachingText.headline`) and put the rest behind a tap.

## Components

Use these instead of writing new ones. All are in `Features/Prep/PrepScreens.swift` unless noted.

- `PrimaryPill`: the one main button. Blue, 58 pt tall, 16 pt corners, white semibold label, optional SF Symbol.
  One per screen.
- `QuietLinks` with `ScreenLink`: grey text links under the main button. Two at most.
- `BrandBackButton`: round white back button, 44 pt. Prep pages that are not full screen use it; login forms have their own `AccessBackButton`.
- `PrepQuestionScreen`, `PrepRecordingScreen`, `PrepWorkingScreen`, `PrepCoachingScreen`, `PrepDoneScreen`,
  `PrepListScreen`, `PrepSavedAnswerScreen`: the full screens. They are plain views fed by values and closures, so the
  Motion Lab can show them with no session, microphone or network. Keep new screens that way.
- `StackMark` (`Design/StackMark.swift`): the coin S mark. Never draw another logo. `tiled: true` is the icon form.
- Text fields: white, 14 pt corners, hairline border that turns blue with focus (`AccessField` in `AccessView.swift`).
- Social sign-in: Apple's system button and a white Google button with the multicolour G (`GoogleG` asset).

Layout: 24 pt side margins (`Spacing.page`), main button at the bottom, content centred or top aligned in the space above it.
Tap targets are at least 44 pt. Set the page background on the root view so the tab bar and scroll bounce match.

## Motion

- Entrances use `.reveal(index, delay:)` from `Design/Motion.swift`: content rises 14 pt and fades in, staggered by 0.055 s.
- Easing is `Motion.ease(duration)`, the one shared curve. Springs only for the mark and small pops.
- Honour Reduce Motion everywhere: read `\.stackReduceMotion`, never `accessibilityReduceMotion` alone.
- Mark a screen with `.replayable()` so the Motion Lab can replay its entrance.
- Colour changes never cross-fade a foreground and a background that swap contrast, because the middle frames turn
  unreadable. The launch sequence uses an expanding mask for this; copy that approach.
- Do the expensive build of the next screen while nothing is moving, hold its entrances (`launchHold`), then release.
- Do not put `drawingGroup()` on the mark: it clips and blurs it when scaled.

## Words

- Sentence case. Short. No exclamation marks, no "please", no "successfully".
- Buttons are one to three words and start with a verb where possible: "Answer", "Done", "Next question", "Try again".
- Errors say what happened and what to do, in one line, with the action as the button.
- Show a score as `n/4` with filled dots, and open its reason on tap.

## Every new screen needs

1. Its states: loading, empty, error, success, and the case where the data is not what you expected.
2. A Motion Lab entry in `Features/Debug/MotionLab.swift` (`LabScreen`) so it can be previewed and replayed. Keep the lab; do
   not remove or bypass it. It is DEBUG only.
3. A test for any parsing or logic. Model replies are free text and their layout changes, so test against real replies,
   with names changed (see `Features/Debug/CoachingSamples.swift` and `CoachingTextTests`).
4. A check on the simulator with real data, then on the phone. Do not hand over a screen you have only seen with made-up data.

## Verifying

- Build and run: follow `CLAUDE.md` (simulator) and use `scripts/ios-phone.sh` for the phone.
- Drive the app yourself, including recording audio, rather than asking the user to test. Ask first before creating or
  changing data on the real account.
- A screenshot only samples a moment. For animation, record the simulator (`xcrun simctl io <id> recordVideo`) and read
  frames, or measure with the debug timing in `Features/Debug/PrepTrace.swift`.
- Commit subjects use `type<scope>: lowercase outcome` with no final period and no co-author line. See `docs/COMMIT_STYLE.md`.
