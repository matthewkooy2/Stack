# Access, Jobs, Applications and Profile

The source audit follows production presentation paths from `RootView`, including conditional account states and system-owned sheets. The changes favor visible choices for everyday actions, progressive disclosure for setup, and native scrolling for long text.

## Access and first use

| Entry or state | Source finding and treatment |
| --- | --- |
| Signed out → welcome | An expanding logo occupied the flexible height above a fixed authentication stack. The mark and Stack name now have a bounded size and the entire welcome can scroll on short screens. Apple, Google, pending Google authentication, cancellation, account creation, sign-in, privacy and support stay available. |
| Sign in / create account | Forced line breaks, a fixed 48-point split-color heading and promotional copy competed with the form. A single Dynamic Type heading leads directly into named fields. Password AutoFill receives the existing/new credential type. Validation, invitation disclosure, keyboard dismissal and account switching retain their original handlers. |
| Signed in → invitation / recover existing Stack account | Admission and account recovery continue to use an invitation field, optional recovery credentials and explicit cancel. The shared adaptive fields, cards, error treatment and buttons carry into both forms. Apple/Google authorization and external privacy/support pages use their own system interfaces. |
| New account → search setup | Three separate field surfaces repeated the word “optional.” A single grouped list shows each preference and its current value. Continue and Skip stay outside the scroll area. |
| Setup → role / location / career stage | O*NET search, All professions and empty results use an adaptive field and selected-row semantics. Apple Maps completion retains US selection, progress, unsupported region and lookup failure states. Each picker keeps a compact Back toolbar above one scroll surface containing search, status and results. The keyboard can be dismissed during scrolling. Career stage has a distinct Back action. |
| Setup → resume upload | The resume picker, selected-file progress, retry and skip remain on the actual onboarding path. Skipping search setup still prepares the Jobs tab behind the upload screen. See the Resume audit for the upload surface itself. |

## Jobs

| Entry or state | Source finding and treatment |
| --- | --- |
| Jobs tab → deck | Swipe right to save and left to pass. VoiceOver exposes both decisions as named actions. The Jobs heading holds profile and requirements, and the card’s information control opens details. The card extends into the area previously occupied by decision buttons. |
| Deck → read a card | Tall location imagery and a heavy job title competed for space. The photo now scales to available height, the logo and employer occupy a compact line, and location, employment and pay can be read before scrolling the excerpts. The card surface adapts to appearance. |
| Deck → loading / empty / errors | Filters and profile remain in one location through startup, paging, network failure, missing graduation, empty matches and exhausted results. Existing Retry, Set graduation, Load more and Change requirements actions remain contextual. Feed errors and search notices stay accessible while browsing. |
| Save or pass → Undo / Tailor | The confirmation names the role. At accessibility text sizes its actions move onto a second row. Undo restores the card. Tailor still commits the pending save and opens that application's existing resume workflow. |
| Read listing → Safari / details | A safe link opens the native in-app Safari controller with its own back, forward, sharing, reload and dismissal. The card's information control always opens Stack details. Missing or unsupported links fall back to those details. The sheet keeps dismissal pinned and the full role title in the scrolling body. |
| Job details → evidence | Posting date, load/retry, open application page, match checks, confirmation questions, timeline evidence, requirements, fit and tags, employer excerpts and provider attribution retain their conditional display. The employer link is the primary action. |
| Header requirements → current search | Previously Pay and dates, Matching and More showed the same mixed controls. The form now exposes quick picks and sort on the first page. Summary rows display current values on a wrapping line, including the pay floor and period, posting window and dated-only flag, selected occupation, listing-evidence rule, and graduation matching policy. **Back** returns from a group and **Close** dismisses the whole form. |
| Search → role / location / arrangement / level / employment | Role and location reuse the onboarding pickers. Single- and multiple-choice option groups preserve their selected states, the level-stated toggle and staged edits. |
| Search → pay and dates / matching / more | Compensation and posting windows live together. Occupation, evidence rules, graduation matching and profile-sourced requirements live under Matching, including Edit profile preferences. More contains overrides, discard/reset, timeline and live-source utilities. Immediate actions are guarded while a local draft is dirty. |
| Timeline / live sources | Expected graduation and availability retain save/error handling. Live sources includes an empty result alongside loading, failure and per-provider health rows. |

## Applications

Things places scheduled items near the work they concern, showing dates only where there is something to do. Apple Reminders organizes a busy list into sections. Stack uses the first idea for the history and follow-up of a single role, and the second for larger pipelines. [Things lists and calendar events](https://culturedcode.com/things/support/articles/4001304/) · [Reminders list sections](https://support.apple.com/guide/iphone/edit-and-organize-a-list-iph82596cb20/27/ios/27)

| Entry or state | Source finding and treatment |
| --- | --- |
| Zero applications | A count, filter row, setup guidance and two calls to action previously surrounded an empty list. The viewport centers a tray symbol, “No applications yet” and Browse jobs. Calendar, follow-ups and Gmail remain in the top menu. |
| One application | A single list row left the page largely blank. The role now occupies a centered composition with the employer logo or initial, full role name, stage and location. A short trail shows up to three recorded status events or the addition date, plus the earliest open reminder for that role when present. Dates without evidence stay absent. |
| Two applications | Each role keeps its employer identity, with a shorter trail of up to two events and one open reminder. A fine separator distinguishes the roles. The layout scrolls naturally. |
| Three or more | Compact, employer-identified rows group under the actual stages present. A stage appears once above its roles. Newly introduced stage names still display. The top menu filters stages, and a visible clear action restores all roles. |
| Navigation | Browse jobs switches to Jobs. A tap on a role opens its details. Pull to refresh, application notification deep links and the Calendar, Follow-ups and Gmail routes retain their original handlers. |
| Application → details | The employer, role, stage and location lead. Open employer site and Mark as submitted handle saved roles. Interview-stage applications have direct access to role-specific interview practice. An open follow-up shows its real title and due time. Demo status remains visible and its existing restrictions apply. |
| Details → resume / notes / history / reminder | Add follow-up, attached resume, notes and status history precede agent setup. History groups each event with its date and source, newest first. Resume selection, draft notes and save/retry remain available. The expandable reminder sheet also serves contacts and existing reminders. |
| Details → agent help / task / interview plan | Fit, tailoring, autofill, mock interviews and the role-specific plan still start on request. Active tasks and unmet setup requirements stay visible. Autofill explicitly warns that forms may autosave and the user submits. The plan links real question and application identifiers to practice, with loading, retry and empty states. |
| Calendar | Month and date selection lead, followed by that day's activity, linked reminders and interview events. Today’s activity streak appears beneath the day’s details. The Calendar connection requests approval before writing interview events. |
| Gmail tracking → scan / review / manage | Connect, scope disclosure, scan and manage-connection states remain. Scan progress uses one labeled indicator. The form retains its start date, stop/resume, counts, review/ignore, and Calendar approval notice. Manage replaces the overview, so routing from Agents can dismiss straight to the destination tab. |
| Follow-ups | Open and completed reminders retain their date order. Complete is inline. A menu exposes Edit and Delete, with destructive confirmation. |

## Profile

| Entry or state | Source finding and treatment |
| --- | --- |
| Account control → profile hub | Six equally weighted rows became two labeled groups. Account identity has a fallback icon, and group rows retain live agent/reminder summaries. The profile and every pane use the same fixed sheet toolbar. |
| Your details / job matching | Named fields and wrapping choices inherit the shared design. Personal details, timeline, experience, work mode and employment type remain editable. Pay, exclusions and optional matching criteria stay grouped behind More preferences. Moving between panes retains unsaved values. |
| Memory bank / Agents / Follow-up reminders | Each opens the existing full-screen or sheet destination. Dismissing returns to Profile. The Memory bank and Agents audits cover their editing and task branches. |
| Account → Google credentials / reminder notifications / daily accountability | Link, cancel and recover remain available as applicable. Frequency choices wrap at larger text sizes. Scheduling windows, permission-denied guidance and iPhone Settings handoff retain their prior behavior. |
| Account → model / support / sign out / deletion | Model selection shows provider-specific messages and asks for explicit confirmation before a switch that would stop active AI tasks. Support and privacy links, notification settings, sign-out and account-deletion confirmation remain available. The displayed version comes from the app bundle. |

## Physical iPhone review

- On a small phone and with accessibility text, sign in with credentials and AutoFill, dismiss the keyboard, inspect the optional invitation, skip setup, and upload or cancel a document. Check welcome and account controls with each enabled sign-in provider.
- Read and scroll a long job card in both appearances. Open details, open and close Safari twice, swipe to save and pass, repeat with VoiceOver actions, undo, and open Tailor. Check card and banner height with Reduce Motion and the largest text settings.
- Change and discard filters, apply staged edits, reset to profile, select an Apple Maps result and inspect both healthy and unavailable providers in Live sources. Verify the selected filters after returning from Safari.
- Check the tracker empty and populated, open an application from a notification, edit notes, inspect history and follow-ups, change months, exercise connected/disconnected Gmail, and complete the return journey from a practice plan.
- In Profile, move between panes with an unsaved draft, inspect the reminder schedule with notifications denied, open Memory bank and Agents, and cancel account deletion. Use VoiceOver for selected dates, job decision buttons, menu choices and returning focus after dismissals.
