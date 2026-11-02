# Jobs card and native browser acceptance

The Jobs deck now uses the current blue/off-white brand, with no app heading or
search toolbar above the card. Requirements and the existing job tools live
behind the card's sliders control. The five tabs, coin mark, launch sequence,
and Prep screens are retained.

Card facts come from the current job data. In the compact feed, responsibilities
and requirements come from `highlights`, which contains employer-text excerpts.
Missing facts are not replaced with generated fit claims. Full text and matching
explanations remain in Job details. `confirmed_only` still refers to listing
evidence, not a record that the user approved their preferences.

The listing browser is the real `SFSafariViewController`, presented modally with
its default presentation and transition. No custom Reader label, security icon,
address bar, grabber, or website controls are drawn by Stack. Reader availability,
redirects, security warnings, browser errors, sharing and Safari handoff remain
system-owned. The system determines appearance for the OS and linked SDK; older
supported iOS versions will not exactly match a newer reference screenshot.

Apple's presentation guidance:
https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller

## Checks performed in the implementation environment

- Existing Python structural validation: 93 Swift files passed.
- Existing Python tests for Swift structure, native-core selection and compact
  job-card payloads: 16 passed.
- `git diff --check`: passed.
- No workflow, CI selection, project configuration, release condition or gate
  changed. Added Swift regressions belong to the manual suites, not native core.
- The native build was attempted through `scripts/ci/ios-swift.sh build`, which
  stopped at the existing macOS/Xcode prerequisite. No Swift compilation,
  simulator/device rendering, XCTest run or native acceptance is claimed.
- An optional backend feed API test could not import `jaclang` in this cloud
  environment. Backend source was not changed.

## Native verification still required

Use the repository's existing Xcode workflow on an authorized macOS environment.
No new gate is required or authorized by this document.

1. Build Debug and Release using the supported Xcode toolchain.
2. Run `JobCardPresentationTests`, `JobFilterTests`, `JobsDeckFlowUITests`,
   `JobFiltersFlowTests` and the existing job detail flow. The new coverage is
   manual-only; do not add it to a blocking workflow without explicit approval.
3. Start the existing loopback listing fixture and run `JobListingSafariUITests`
   using the instructions in `ios/README.md`. The stub browser does not establish
   native Safari appearance or dismissal behavior.
4. Compare Jobs and real Safari with the approved references on a compact and a
   larger iPhone. Check the native status area, card insets, remaining tab space,
   sheet transition, visible underlying strip, actual Reader states, and close.
5. Exercise smallest supported portrait layout, longest employer/title/pay text,
   all accessibility Dynamic Type sizes, VoiceOver and Reduce Motion. Confirm
   body scrolling, the bounded company header, filter hit target and footer
   buttons remain usable. Card accessibility exposes the complete displayed
   excerpts even when ordinary-size visuals truncate a line.
6. Test repeated listing taps, close/reopen, browser back/forward, real share and
   Safari handoff, network failure/reload, unsafe links, and returning to the same
   card. Swipe left/right must decide only once; short and vertical drags must
   neither decide a job nor open its listing.
7. Test slow initial feed, cached feed refresh, paging, empty/error/retry, failed
   Save/Pass, Undo, failed requirement saves, quick picks, reset, tool sheets,
   profile access, sign-out and account replacement. Requirements stays disabled
   until initial criteria is available and while a feed change is in flight.

The ordinary Undo window remains 2.4 seconds while browsing. A pending Undo is
not force-committed merely by opening Safari, but is not kept indefinitely.
