# Stack for iPhone

A job deck, an application tracker, a contact directory and a document library serve different tasks. Their contents should identify them at a glance. The second pass gives each a distinct layout and keeps the shared chrome to a title, account access and five labeled tabs.

## What changes as the account fills up

| Tab | Empty | One | A few | Many |
| --- | --- | --- | --- | --- |
| Applications | A tray and **Browse jobs** occupy the center of the available screen. | A large role title, employer mark and short dated history give the application its own page. A scheduled follow-up appears when one exists. | Two roles have separate, shorter histories. | From three roles, compact rows group by the stages actually present. Application tools include a stage filter when there is a choice. |
| Network | A people symbol and **Add a contact** lead straight to the name field. | The person's initials, name and available contact details sit together, with a direct way to open their record. | Two to four people fit in a small grid that reflows into a column at accessibility sizes. | From five contacts, search and alphabetical sections support finding a specific person. Presence holds profile drafts and LinkedIn review. |
| Resume | A folded sheet, accepted formats and **Choose file** identify what belongs here. | The original document is prominent, with the filename and available metadata below it. | A two-document shelf lets people distinguish their originals by sight. Small supported PDFs can show an actual first page. | From three documents, the default file leads a compact list. Management opens from each file. |
| Jobs | The action depends on the reason the deck is empty, such as changing requirements or loading more. | Swipe left to pass or right to save. The card uses the height previously occupied by buttons. | Undo stays available immediately after a decision. | The same gestures work through the deck. VoiceOver exposes Save and Pass as named actions. |

Count thresholds above are design choices for this build. They reflect the point where Stack changes from showing the item to helping the user find one. Loading, failed requests and missing optional metadata have separate treatments.

## Research behind the changes

- **Put the task before the explanation.** Apple’s writing guidance favors short, useful interface text. We removed repeated introductions and gave each first-use collection one visible next action. Accepted upload formats stay beside the file picker because they affect the choice. [Apple Human Interface Guidelines — Writing](https://developer.apple.com/design/human-interface-guidelines/writing)
- **Let people recognize their work.** Contacts starts with names, Books makes covers recognizable, and Files offers list and icon views. Stack uses people’s initials and employers, actual dated activity and original document previews as visual cues. Each cue is backed by account data. [Apple Contacts](https://support.apple.com/en-ca/guide/iphone/iph3e0ca2db/ios) · [Apple Books](https://support.apple.com/en-mk/guide/iphone/iphab219b91/ios) · [Apple Files](https://support.apple.com/en-gb/guide/iphone/iphc61044c11/ios) · [NN/g — Recognition Rather Than Recall](https://www.nngroup.com/articles/recognition-and-recall/)
- **Bring structure in when it earns its space.** Reminders uses sections to organize related items. Things brings dated work into view and supports finding items by typing. In Stack, real history helps someone return to one role, stage headings help locate one among many, and search appears when the contact directory grows. Gmail setup, CSV import and document administration remain one menu away. [Apple Reminders](https://support.apple.com/guide/iphone/edit-and-organize-a-list-iph82596cb20/ios) · [Things — Upcoming](https://culturedcode.com/things/support/articles/4001304/) · [Things — Quick Find](https://culturedcode.com/things/support/articles/2803584/) · [NN/g — Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)

## Route inventory

| Area | Coverage |
| --- | --- |
| [Access, Jobs, Applications and Profile](discovery.md) | Admission, onboarding, role and location pickers, deck, browser, filter panes, application details, Calendar, Gmail, reminders, preparation plan and settings. |
| [Network, Resume and Agents](workspace.md) | Contacts, discovery, profile drafts, LinkedIn PDF reviews, file upload, editing, formats, tailoring, Memory bank, agent tasks and remote browser. |
| [Prep, interviews and recording](practice.md) | Practice home, typed and spoken answers, coaching, saved sessions, role-specific interviews, technical exercises, recording, playback and Live Activity. |

The shared shell restores a signed-in account, retains visited tab roots, and routes incoming links and notifications. Sheets keep their dismissal controls reachable. System pickers, Safari, permission prompts and document preview use their native controls. The [interface guide](../../ios/UI_STYLE.md) describes layout and motion.

## Open the design on a physical iPhone

From a Mac clone, fetch `origin/codex/ios-interface-redesign` and use a worktree at that revision. Run `bash scripts/ios-phone.sh` there to build, sign, install and open Stack on the paired phone. Normal launches use the configured account and backend.

A Debug build can also show the actual SwiftUI tabs with fictional accounts. Set one Xcode launch argument from the table and run on the connected phone. Each opens Applications, with Network and Resume available in the tab bar.

| Launch argument | Records per collection |
| --- | --- |
| `--screen-flow=collections-empty` | 0 |
| `--screen-flow=collections-one` | 1 |
| `--screen-flow=collections-two` | 2 |
| `--screen-flow=collections-full` | 12 |

Remove the argument to return to the live account. The optional `--motion-lab` argument exposes component replay and a population picker during development. Native rendering, gestures and frame pacing still need the physical build.
