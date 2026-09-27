# Implementation notes

The official Jac mobile documentation describes a beta React Native/Expo target. The installed 0.37.21 compiler uses `[apps.mobile] kind="mobile"` and `@jac/mobui`. Bundled `jac guide` references and the actual compiler were used when older documentation differed.

References consulted:

- [Jac mobile target](https://docs.jaseci.org/reference/plugins/jac-client/#react-native-target-beta)
- [Expo version compatibility](https://docs.expo.dev/versions/latest/#support-for-android-and-ios-versions)
- [Expo local notifications](https://docs.expo.dev/versions/latest/sdk/notifications/)

The Jac target generates genuine React Native components. The native bridge contains platform/transport functions; application state, screens, validation, ownership, graph operations, and demo execution stay in Jac. No Jac framework source was patched.

Resolved integration issues:

- Re-extracted a broken launcher runtime under ignored `.jac/tool-cache`.
- Kept runtime extraction outside the compiler's application scan.
- Used Node for Expo prebuild; Bun produced a malformed `pbxproj`.
- Staged `auth_contract` and `endpoint_cache`, omitted from the beta native runtime staging.
- Used explicit collection-length conditions because empty Jac client collections compiled with JavaScript truthiness.
- Quoted object keys where local Jac state names otherwise generated invalid JavaScript.
- Refreshed the request snapshot after acquiring the swipe/seed lock; locking alone allowed requests with stale snapshots to create duplicates.
- Removed `aps-environment`: local notifications do not need remote-push provisioning.
- Preserve the current LAN API address after every native recompile.

The demo service computes Queued (0–3 seconds), Preparing (3–8 seconds), and Submitted (after 8 seconds) from a stored creation timestamp. This survives process termination without a worker process. Previously seeded interview/rejection examples remain in existing accounts; new accounts start without demo applications. Real listings use Ready to apply and explicit user-confirmed submission. The catalog worker is now implemented in `core/catalog.jac` and `scripts/discovery-worker.jac`; see `docs/JOB_DISCOVERY.md`.

Notifications use stable per-account/per-reminder identifiers. Foreground/sign-in reconciliation cancels stale schedules, updates changed titles/dates, and schedules pending reminders once. An epoch prevents in-flight requests from crossing account changes. Background refresh is prevented from overwriting a newer successful mutation. No background Mac agent, remote push service, LinkedIn scraping, application submission, or outreach exists in v1.

Known prototype limits: no cloud sync, email delivery, password recovery, multi-device notification coordination, or multiworker guarantee. The iOS system limits how many pending local notifications an app can hold; larger production reminder queues need a separate scheduling design. User data remains on the development Mac. Subscription integration feasibility is still open for all three planned providers.
