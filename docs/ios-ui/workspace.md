# Network, Resume and Agents

This inventory follows the production SwiftUI routes on the redesign checkout. Findings come from the view hierarchy and its state branches. Visual and interaction acceptance require a physical iPhone.

## Network

Apple Contacts puts people first, with direct actions to add or find a contact. Things searches within its collection and displays matches as you type. Stack applies these patterns to its real outreach contacts. [Apple iPhone User Guide](https://support.apple.com/en-ca/guide/iphone/iph3e0ca2db/ios) · [Things Quick Find](https://culturedcode.com/things/support/articles/2803584/)

| Route or state | Implemented design |
| --- | --- |
| Network → People or Presence | People opens first. A short underlined selector opens Presence with one tap. Both share the page heading and pinned account access. |
| People → empty | A centered two-person outline, “No contacts yet” and one Add a contact button. The button opens the name field directly. Loading and first-load failure have separate states. Failed refresh keeps the last successful roster visible with a retry. |
| People → one | A portrait in the upper-middle of the available height shows real initials, a name and a View contact action. Role, company, email and relationship appear when supplied. The composition also works for a name alone. The portrait and action open the same contact. |
| People → two to four | A compact grid shows initials, name, work detail or email and a short relationship note when available. Tiles become a single column at accessibility sizes. A header plus opens the add form. |
| People → five or more | Directory rows group names alphabetically. An inline search field filters by name, role, company, email or relationship and offers one-step clearing. |
| People → add / import CSV / outreach settings / contact | New contacts and pasted CSVs have dedicated forms. Unfinished text survives closing and switching sections. Outreach settings retain follow-up timing and setup. A contact opens individual actions for selection, draft, task review and stop. |
| People → options → discovery catalog → draft, private notes or reminder | Catalog and saved filters use their own records. Contact notifications open the supplied real person or saved catalog record. A deleted real contact or catalog record has a dismissible explanation. |
| Presence → LinkedIn review | A fresh profile can start a PDF review. Existing reviews show actual findings or status. Structured reviews expose the proposed wording, current-wording disclosure and rewrite editor. Full review and reviewing another PDF remain accessible. Loading and failed requests have explicit states. |
| LinkedIn review → Files → reviewing → results | The optional target role and PDF picker lead, with import instructions on demand. Pending and failed reviews keep their recovery actions. Results retain findings with expandable evidence, strengths, questions, rewrite editing, approval and copy. |
| Presence → profile drafts → field | Three rows open LinkedIn, GitHub and Portfolio. Each shows its first saved nonblank field or a short description of available fields. The selected provider opens directly with saved values. Individual fields retain Save and Cancel and are scoped to the signed-in session. |

## Resume

Apple Books displays recognizable covers in a small collection, and Files supports compact list browsing and per-document actions. Stack adapts these patterns to the number of originals in the account. Preview images and all displayed metadata come from the user’s files. [Apple Books library](https://support.apple.com/en-mk/guide/iphone/iphab219b91/ios) · [Apple Files](https://support.apple.com/en-gb/guide/iphone/iphc61044c11/ios)

| Route | Finding and implemented direction |
| --- | --- |
| Empty Resume / optional onboarding upload → Files → reading, uploading, failure, retry | A folded-paper illustration and the accepted formats sit above one Choose file action. Onboarding keeps Skip for now. A failed upload with retained bytes offers retry and choose another file. The empty tab’s options still open Memory bank, existing tailored versions and tailoring. |
| One or two documents → selected file | One document features a centered first page that scales to the viewport, with its name and metadata directly beneath it. Two files sit side by side, switching to one column at accessibility sizes. Size, upload date, default and review state identify each file. Tapping its cover or filename opens file actions. Tailoring, saved versions and Memory bank follow the documents. |
| Three or more documents → selected file | A compact list places the default first and orders the remainder by upload date. Filenames truncate in the middle and VoiceOver receives the full name. The Add control, tailoring action and options for Memory bank and saved versions keep secondary flows in reach. Processing and retry stay attached to each file. |
| Document covers | A visible small collection reads originals up to 1 MiB through the authenticated API. Actual bytes identify Word packages and PDF pages, including after renaming. A PDF gets a thumbnail rendered off the main thread. A Word file gets a labeled cover. Larger and unavailable files retain a neutral cover. Thumbnails and verified types stay in session memory. Large collections never request previews. |
| File manager → preview, review, format, manage | PDF preview keeps its own Close control. Review details, format and changing the default have direct rows. Rename and confirmed deletion remain under Manage, with rename text retained through nested navigation. |
| Agent link → Memory bank / Resume details | The named action opens the bank or the default document’s details after returning to the tab. A missing default falls back to the first document. An empty library keeps the upload invitation. |
| Resume details → section expanded → edit → original extraction / raw records | Contact details, work, education, projects, skills, additional and extra fields keep inline editing, add/reorder/remove, original extraction, record fallback and conflict recovery. Section controls announce item counts or summaries and expansion. Field labels stack above their values at accessibility sizes. |
| Parsing or design processing → retry | User-facing status, retry and save state remain visible. Internal transfer/queue/compiler timings no longer compete with the result. |
| Tailor for a job, including entry from an application → choose job / resume / upload | The old 210–260 pt placeholder or PDF appeared before either input. Resume and saved job are now labeled first. A real preview opens on demand. Empty accounts can navigate to Jobs. Fit assessment retains its evidence disclosure, and score expansion respects Reduce Motion. |
| Tailor → Prepare your resume → confirm details / select design → preview → start task | Setup still enforces actual eligibility. Both design entry points share one native menu and the same six template IDs. Existing custom and legacy layouts stay representable through their format details. Profile suggestions and previous profile tasks remain in More options. |
| Tailoring format → source replacement / source text / PDF | Advanced file actions use plain-language labels and wrap on compact screens. Build, retry and format confirmation still use the existing processing state. |
| Tailored resumes → version, before/after score, PDF, source, delete | Outputs stay grouped by job. Version inspection retains its preview and score. The wrapped secondary controls accommodate larger labels, and deleting still requires confirmation. |
| Memory bank → add/edit, choose facts per resume, source history, delete | Selecting a confirmed fact works from the entire row. Changed revisions and failed saves retain explicit messages. Drafts, deletions, confirmed facts and per-resume choices keep their existing semantics. |

On an iPhone, compare zero files, a single PDF, two mixed-format files and three or more with long names. Switch tabs while thumbnails load, change the default, and confirm that failed processing offers the correct retry under its document. Repeat with large accessibility text and Dark Mode.

## Agents

| Route | Finding and implemented direction |
| --- | --- |
| Account / application / network fix → agent center | Five horizontally scrolling pills hid later destinations. A section menu names the active area and offers all five sections. The agent sheet now keeps its title and close action pinned. |
| Needs you / Activity → task | The queue still separates unresolved messages, ongoing work and recent tasks. Status sits above the task title, leaving room for long titles. Row summaries are shortened visually with the full explanation in detail. |
| Features / Email & calendar / Facts | Feature setup, OAuth, Gmail tracking and scan, message-to-application resolution, calendar proposals, advanced outbound permissions, disconnect, confirmed answers and adding a fact remain available from the section menu and targeted links. |
| Task detail → review, answers, blockers or recovery | Pending decisions come before the expanded history. Each task shows its state, title and context. The progress indicator exposes the entire step list on request. Approvals, edits, answers, uncertain outcomes, retry, feedback and cancellation stay explicit. |
| Task → browser | Close stays reachable. The page and controls scroll when the keyboard opens, and remote editing keys wrap. Loading, live, paused, owned, reconnecting, stale and failed states still use the real browser model. |
| Tailoring review → individual change, all suggestions, options/details, proposed PDF, apply | A single progress indicator reflects the number actually reviewed. The old per-item strip could become wider than the screen. Before/after comparison uses adaptive surfaces and semantic text styles. The two decisions stack at accessibility sizes. |
| Task results → tailored output / cover letter / LinkedIn artifact / other results | Final and proposed versions retain PDF preview, score, changes, original text, tailored text and source. Older results retain their fallback. LinkedIn reviews can open the existing rewrite editor and approved-copy flow. |

The older ExperienceBankView has no production caller in this checkout. LocalDraftUITestScene, the tailoring and motion labs, review samples and ScreenFlow fixtures are development entry points. Their production controls use the changes above.

## Physical-device checks

1. On a small iPhone in portrait, open each section, then repeat with accessibility text sizes and VoiceOver. Confirm that sheet titles, profile controls, long filenames, stale rows and field labels fit. Check light and dark appearance and Reduce Motion.
2. Import and cancel a file in onboarding and in Resume. Test a failed upload and retained-file retry, then review and edit structured details, fall back to raw records, preview a document and close nested sheets with a pending rename. Compare template selection in both entry points.
3. Check People with zero contacts, one name-only or name-and-email contact, two to four contacts, and five or more with mixed scripts and long names. Search by company, email and relationship, clear a no-match query and open a result. Open a real contact notification and a catalog reminder. Close an unfinished add/import form, switch sections and reopen it. Review a LinkedIn PDF, compare long wording, copy a rewrite and verify separate provider drafts appear on Presence.
4. Test a long queue and a task in each available state. With an approved test account, inspect a pending action, compare tailoring changes, open a generated PDF, and test remote clicks, page swipes, keyboard dismissal and scrolling outside the remote viewport.
