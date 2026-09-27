# Real-job discovery acceptance (current)

- Open Jobs, change the target profession and location, and confirm real source-labeled results.
- Inspect a listing with unknown salary and a listing with hourly pay; neither should claim an invented annual salary.
- Swipe right; verify **Ready to apply**, open its source application page, then explicitly mark submitted.
- Relaunch and verify the application, notes, selected resume, and saved search remain.
- Import a public job URL. Confirm unsupported pages show review/error feedback rather than a fake successful import.
- View **Live sources**: missing provider credentials and incomplete employer coverage must be visible.
- Check larger text and available compact/large iPhone layouts. The device must be connected for this acceptance.
- Repeat existing PDF, reminder, sign-out, and notification tests below; legacy demo checks apply only to existing demo history.

# Phone testing

Physical-device acceptance is pending: the paired iPhone was reported unavailable by `devicectl` during implementation. Compilation, code signing, API integration, and mocked native workflows are separate checks.

1. Connect/unlock the iPhone. Start `scripts/dev`, open the generated Xcode workspace, select the phone, and Run. Grant local-network access. Confirm the sign-in screen loads from Metro; change a visible string in `mobile/main.jac`, save, and verify hot reload, then revert that string.
2. Create an account and finish onboarding. Swipe right or tap **Apply · Demo**. Verify one application appears and becomes **Submitted · Demo** after about eight seconds. Force-close/reopen Stack and confirm the same record, notes, and preferences persist.
3. Import a PDF under 10 MB from Files. Preview, rename, select it for an application, and delete it. Cancel a picker without an error. Try an oversized PDF and a damaged PDF; neither should be saved. The automated fixture `tests/fixtures/blank.pdf` is a valid single blank page.
4. Open an application or contact, add a follow-up, choose **In 1 minute**, and allow notifications. Check foreground and locked-screen delivery. Tap the notification and verify it opens the correct record. Repeat after rescheduling; complete/delete a pending reminder and confirm its alert is canceled.
5. Disable notifications in iPhone Settings, save another reminder, and check that it remains in-app with an explanation. Re-enable notifications and foreground Stack; check that one alert is scheduled. Notification taps while signed out should wait for authentication and must never open a different account's record.
6. Sign out, create another account, and check that the first account's applications, PDFs, drafts, and alerts do not appear. Sign back into the first account and verify its data returns.
7. Stop the Mac API, attempt a save, and verify an actionable error with no saved-success message. Restart it and retry. Try rapid apply taps, drag cancellation, all filters, and an exhausted deck.
8. Check that navigation reads Network, Applications, Jobs, Resume, Prep, with Jobs centered. Open Prep, switch between Technical and Behavioral, reveal a guide, and advance to another question. Open the top-right avatar to edit profile settings or sign out.
9. Check the smallest supported viewport and a large viewport, large accessibility text, keyboard avoidance, safe areas, and all five bottom tabs. Verify buttons provide alternatives to swipe gestures.

Record any problem with the screen, steps, and expected/actual result. Device delivery, native PDF rendering, LAN reachability, visual layout, and hot reload remain acceptance checks until exercised on the phone.
