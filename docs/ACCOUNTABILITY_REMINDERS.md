# Accountability reminders (iOS)

Issue #127. Short reminders through the day, each pointing at one small job-search
step, that arrive while the app is closed or in the background.

## What the user sees

Account → **Daily accountability**:

- **Send reminders** on or off. Turning it on asks for notification permission the
  first time.
- **How often**: every 2, 3, 4 or 6 hours.
- **From / Until**: the active hours (5am to 11pm). The first reminder is at the start
  hour, then one every interval up to the end hour. Defaults: every 3 hours, 9am to
  9pm (5 a day).

Each slot is one step, rotating through the day:

| Step | Text | Tap opens |
| --- | --- | --- |
| Find one role | Swipe through today's matches and save one worth applying to. | Jobs |
| Follow-ups due / move one application forward | Names the number of follow-ups due in the next day when there are any | Applications |
| Practice one answer | Five minutes: answer one interview question out loud and get coaching. | Prep |
| Reach out to one person | Message one contact or alum about their team. | Network |

Changes apply at once; they are not part of the profile Save button. If permission
was denied, the section says so and links to the app's page in iPhone Settings.
Turning the switch off removes every pending accountability reminder.

## How it works

`ios/Stack/Core/Nudges.swift` holds the settings (`NudgeSettings`) and the plan
(`Nudge.plan`). `AppStore.reconcileNudges` replaces the pending reminders with one
`UNCalendarNotificationTrigger` per slot that repeats daily at that hour. Because the
triggers repeat, reminders keep arriving even if the app is not opened again. The app
re-plans whenever it reconciles reminders: at launch, refresh and after a saved change.
That keeps the follow-up count current.

- Identifiers are `stack-nudge-<user>-<hour>`. Follow-up reminders (`stack-<user>-<id>`)
  and accountability reminders no longer remove each other. Before this change,
  scheduling follow-ups called `removeAllPendingNotificationRequests`.
- Settings are stored in `UserDefaults` per account, on this phone only, because local
  notifications are per device. Signing out removes all pending notifications. Signing
  back in on the same phone restores the saved schedule.
- A tap carries `target_type: "tab"` and the tab name. `RootView.open` switches to that
  tab. It ignores a tap meant for another account.
- At most 10 slots a day (every 2 hours from 5am to 11pm), well under iOS's limit of
  64 pending requests even with follow-up reminders.

## Local or remote notifications

**Local notifications were chosen.** They:

- arrive on schedule while the app is closed or the phone is offline;
- need no server, no APNs credentials and no paid Apple Developer membership;
- work with the unsigned and locally signed builds used today.

The cost is that the text is fixed when the app last ran. A count can be up to a day
old if the app is not opened.

Remote push would add server-chosen content, such as "Acme replied", and reach people
who never reopen the app. It is not usable from the native app today:

1. The backend's `agent_register_push` accepts only Expo push tokens
   (`ExponentPushToken[...]`). Delivery goes through Expo (`agents/notifications.jac`,
   `EXPO_ACCESS_TOKEN`). The native SwiftUI app has no Expo SDK and never calls
   `registerForRemoteNotifications`, so it has no token to register.
2. The app target has no `aps-environment` entitlement.

## Apple setup

For the local reminders in this change:

- No capability, entitlement, APNs key or provisioning change is needed.
- The only requirement is the user's permission (`.alert`, `.sound`), requested from
  the settings screen.

For remote push later:

1. Use a paid Apple Developer Program team for `com.matthewkooy.stack.swift`.
2. Enable the **Push Notifications** capability on the App ID, then regenerate the
   provisioning profiles.
3. Add `aps-environment` (`development` for local builds, `production` for TestFlight
   and App Store) to the entitlements file passed through `STACK_APPLE_ENTITLEMENTS`.
4. Create an APNs authentication key (.p8) in Certificates, Identifiers & Profiles, and
   note its Key ID and Team ID.
5. Choose a backend path:
   - Send through APNs directly. This means a new sender that signs a JWT with the
     .p8 key, plus a token type in `agent_register_push` for raw APNs device tokens.
   - Keep Expo. Upload the .p8 key to the Expo project, then either add the Expo
     notifications module to the native app or call Expo's token API from it.
6. In the app, call `UIApplication.registerForRemoteNotifications()` after
   permission, send the token to the backend, and remove it on sign-out
   (`agent_remove_push`).

Steps 1 to 4 need access to the Apple Developer account, which this change does not
assume.

## Verification

- Unit tests: `ios/StackTests/NudgeTests.swift`. They cover window and frequency,
  off, step rotation, follow-up wording, daily repeating triggers with tab routing,
  per-account settings and hour labels.
- Still needed on a physical iPhone, as the issue asks:
  - enable reminders and allow permission;
  - set **Every 2h** with a window that starts within the hour, then close the app;
  - confirm the reminder arrives with the app closed and that tapping it opens the
    right tab;
  - change the frequency and confirm the old times stop;
  - deny permission and confirm the Settings link;
  - turn reminders off and confirm none arrive;
  - sign out and confirm none arrive.
