# Network, Resume and Agents

This inventory follows the production SwiftUI routes on the redesign checkout. Findings come from the view hierarchy and its state branches. Visual and interaction acceptance require a physical iPhone.

## Network

| Route | Finding and implemented direction |
| --- | --- |
| Network tab → Your Presence / Your Network | The page began with two pills and hid account access in overflow. Both sections now share the Network title and account control. Their selector wraps on a narrow screen or at large text sizes. Each section keeps its own scroll position and editing state. |
| Your Presence → LinkedIn expanded or collapsed | An inset under the avatar left too little width for real profile text. The current and suggested wording use the width of a single raised surface. A new review, an existing review, edit, retry and status each have a contextual action. |
| LinkedIn review → upload PDF → Files → reviewing → results | Four permanent import instructions preceded the optional role field. Instructions open on demand. Choosing a PDF, retrying a failed read or review, returning from results and starting another review retain their distinct actions. The wait screen distinguishes sending the PDF from a review accepted by the server. People can close the screen and find an accepted review in Agents. A pending review can be rechecked using its ID. |
| Review results → findings, suggested wording, strengths, questions | Findings expose supporting quotes and rationale on demand. Headings scale with text size and expansion respects Reduce Motion. The rewrite editor preserves field edits, inclusion switches, approval and copying, including when opened from an agent task. |
| Your Presence → GitHub / Portfolio, or overflow → Public profile drafts → individual field | All three provider-specific lists share a grouped editor with a pinned title and close action. Platform choices wrap. Each field opens with Save and Cancel. Session scope is stated alongside the drafts. |
| Your Network → real roster → contact or manager | The first contact previously had a unique blue avatar despite having no special status. Every real contact now uses equal visual weight and compact role/company metadata. Manage remains above long rosters. The empty state can start a new contact directly. Loading, stale rows, failure and retry remain distinct. |
| Contact manager → add / import CSV / edit timing, or contact → outreach | The add form now precedes the roster. Setup guidance opens automatically when the account needs it. Existing select, draft, review, stop, timing and connection-repair actions are available. Closing preserves unfinished fields. |
| Overflow → discovery catalog → contact draft, private notes → reminder | Saved/all filtering stays separate from the real roster. Catalog detail uses the pinned sheet header. A removed profile now has a readable, dismissible state. Reminders retain their existing target. |
| Contact, catalog and attention notifications | A contact notification still selects the roster, then opens its contact tools or resolves a saved catalog record. The presence and roster surfaces stay mounted when switching tabs. |

## Resume

| Route | Finding and implemented direction |
| --- | --- |
| Empty Resume / optional onboarding upload → Files → reading, uploading, failure, retry | A paper illustration was the only upload control. An explicit Choose file action now accompanies the accepted formats and size limit. A retained failed file gets a primary retry. Status and errors wrap, and onset of the picker no longer depends on a decorative animation. |
| Resume with files → selected file | Repeated visits previously opened on a full-width upload action. Saved files now lead, with Upload beside their heading, followed by tailoring, saved tailored copies and Memory bank. Default and review status remain associated with each file. |
| File manager → preview, review, format, manage | Preview opens the PDFKit document with its own Close control. Review and format retain visible rows. Rename/default/delete stay behind Manage, including delete confirmation and preserved rename text during nested navigation. |
| Resume details → section expanded → edit → original extraction / raw records | Contact details, work, education, projects, skills, additional and extra fields keep inline editing, add/reorder/remove, original extraction, record fallback and conflict recovery. Section controls now announce item counts or summaries and expansion. Field labels stack above their values at accessibility sizes. |
| Parsing or design processing → retry | User-facing status, retry and save state remain visible. Internal transfer/queue/compiler timings no longer compete with the result. |
| Tailor for a job, including entry from an application → choose job / resume / upload | The old 210–260 pt placeholder or PDF appeared before either input. Resume and saved job are now labeled first. A real preview opens on demand. Empty accounts can navigate to Jobs. Fit assessment retains its evidence disclosure, and score expansion respects Reduce Motion. |
| Tailor → Prepare your resume → confirm details / select design → preview → start task | Setup still enforces actual eligibility. Both design entry points share one native menu and the same six template IDs. Existing custom and legacy layouts stay representable through their format details. Profile suggestions and previous profile tasks remain in More options. |
| Tailoring format → source replacement / source text / PDF | Advanced file actions use plain-language labels and wrap on compact screens. Build, retry and format confirmation still use the existing processing state. |
| Tailored resumes → version, before/after score, PDF, source, delete | Outputs stay grouped by job. Version inspection retains its preview and score. The wrapped secondary controls accommodate larger labels, and deleting still requires confirmation. |
| Memory bank → add/edit, choose facts per resume, source history, delete | Selecting a confirmed fact now works from the entire row. Changed revisions and failed saves retain explicit messages. Drafts, deletions, confirmed facts and per-resume choices keep their existing semantics. |

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
3. Open a real contact notification and a catalog reminder. Start a contact draft, switch sections, close and reopen. Review a LinkedIn PDF, inspect long before/after text and copy a selected rewrite. Confirm independent GitHub and Portfolio drafts.
4. Test a long queue and a task in each available state. With an approved test account, inspect a pending action, compare tailoring changes, open a generated PDF, and test remote clicks, page swipes, keyboard dismissal and scrolling outside the remote viewport.
