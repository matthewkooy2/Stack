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
| Jobs tab → deck | A floating filter icon was the only visible tool, with saving and passing discoverable primarily by swiping. A shared Jobs heading exposes profile and requirements. Fixed **Pass** and **Save** buttons provide the same actions as horizontal gestures. The information button opens job details directly. |
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

| Entry or state | Source finding and treatment |
| --- | --- |
| Applications tab → tracker | Gmail setup occupied the first screen above the user's jobs. The tracker now opens on the role list. Each row has a wrapping title, employer and status. A status filter menu replaces the horizontal chip strip. Tools contains Calendar, Follow-ups and Gmail tracking. |
| Empty tracker | Browse jobs goes directly to the deck. Track with Gmail provides a second route for applications made elsewhere. Pull to refresh and application notification deep links retain their original behavior. |
| Application → details | Long titles stay in the scroll content with company and location. The fixed toolbar remains reachable on long records and missing applications. For a saved role with a valid employer link, Apply on the employer site is primary and confirming submission is secondary. Without a usable link, confirmation becomes primary. Demo entries retain their existing restrictions. |
| Details → agent help / task / interview plan | Fit explanation, tailoring, browser autofill, mock interview and building the job-specific practice plan stay behind deliberate actions. Active tasks and setup needs remain visible. The generated-plan sheet carries real question and application identifiers into practice, including loading, retry and empty states. |
| Details → resume / notes / history / reminder | Attachment selection, editable notes, save/retry and history are disclosures. The shared reminder editor scrolls, expands to a large sheet, shows save errors in context and disables repeat saves during a request. It is also used for contact and existing-reminder edits. |
| Tools → calendar | Month browsing now selects a day in the displayed month so the details cannot silently describe a different month. Selected dates have a blue surface, an accessibility selected state and high-contrast activity dots. Day details list application activity, follow-ups and interview events from their existing sources. Calendar authorization follows the existing consent path. |
| Tools → Gmail tracking | Tracking has a dedicated sheet with connect, unavailable, scope disclosure, scan and manage-connection states. Manage replaces the overview with Agents email and calendar settings in the same presentation, so account-fix links can dismiss directly to their destination tab. |
| Tracking → scan / uncertain match review | A user chooses the starting date, then explicitly starts the scan. Loading, running/stop, resume/new, completion counts and review remain distinct. A review can match an existing application, create a new one, set status, save, or ignore. Google Calendar changes retain their approval step. |
| Tools → follow-ups | Upcoming and completed reminders retain their date order. Complete is the inline action. A menu exposes Edit and Delete, with the existing destructive confirmation. |

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
- Read and scroll a long job card in both appearances. Open details, open and close Safari twice, save and pass by both button and swipe, undo, and open Tailor. Check card and banner height with Reduce Motion and the largest text settings.
- Change and discard filters, apply staged edits, reset to profile, select an Apple Maps result and inspect both healthy and unavailable providers in Live sources. Verify the selected filters after returning from Safari.
- Check the tracker empty and populated, open an application from a notification, edit notes, inspect history and follow-ups, change months, exercise connected/disconnected Gmail, and complete the return journey from a practice plan.
- In Profile, move between panes with an unsaved draft, inspect the reminder schedule with notifications denied, open Memory bank and Agents, and cancel account deletion. Use VoiceOver for selected dates, job decision buttons, menu choices and returning focus after dismissals.
