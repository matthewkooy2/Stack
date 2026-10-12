# Swift resume review

MAT-36 restores editable resume details in focused sections using the app's existing Prep-style fields and actions. The parser belongs to MAT-8; this change does not add or alter extraction.

| Section | Editable fields |
| --- | --- |
| Contact | Name, email, phone, location, link, summary |
| Education | School, degree, date, GPA, location, individual detail bullets |
| Work experience | Job title, company, date, location, individual detail bullets |
| Projects | Project, date, individual detail bullets |
| Skills | Individual items |
| Additional details | Individual items |

Fields beyond this inventory remain editable and survive save. Server definitions expose extra named fields, including links. Unknown repeated sections appear in the overview and unknown single keys appear under Other fields. Repeated entries and bullets can be added, removed and moved. Removal of an entry asks first. Blank rows remain in the local draft until filled or removed; the server payload omits empty entries and blank bullets and renumbers entries in display order.

The original extraction is a separate read-only screen in original parse order, with warnings and accepted source text. MAT-8 preserves raw original fields and evidence before editable field/group caps; the editable copy may be shortened or omit overflow entries with warnings. Unsupported or oversize documents fall back to raw review. The original is never matched to a current entry by index or heuristic provenance. Editing a field shows its last saved value and an Undo change action. These saved values follow local entry identity during a draft; after save/reload they come from the current server version.

## Save, revision and account behavior

Drafts are keyed by account and resume, written atomically to Application Support with file protection and backup exclusion, debounced while typing and flushed when the sheet closes or the app backgrounds. A write failure remains visible while edits stay usable in memory and can still be saved to the account. Sign-out does not delete the old account's draft. Another account does not load it.

Reads protect both changed values and empty local rows. A newer server revision becomes an explicit conflict; it does not replace the draft. The user may discard local edits and reload. Save sends a full replacement map with the loaded revision; omitted keys remove entries. A successful draft save withdraws confirmation. Confirmation is explicit. In-flight responses are ignored after account changes, stale reads are ignored, and editing is disabled during save. The stored draft is cleared only if it matches the submitted snapshot. Older record-based resumes keep their raw-record editor and save route.

The server's limits govern entry counts, scalar fields, summaries, description lists, individual bullets and total text. Over-limit edits stay visible and are blocked from save with an explanation; the client never silently truncates typed text. The compatibility record projection has additional record/text bounds including generated labels and separators. The server validates that projection before saving; a rejection stays visible and keeps the draft. The client checks editable-field bounds without guessing backend projection formatting. Structured processing uses the import lane. LaTeX processing retains the source lane.

The frozen synthetic MAT-8 fixture is in `ios/StackTests/Fixtures/resume-review-contract.json`, SHA256 `187d0a564f1b0de9f04faae4f98ea0fcf88aaeb9ecd240140fa6d022aaab8532`. It came from parser HEAD `63521ee33e16dde1abf2e0245960eb283621a8b4` plus tracked diff SHA256 `8b0dc3316cac4acfe8b490f22821e5d9099959294335e2192ea658c58a697ccd`. It includes revision 3, object warnings, definitions/limits, 21 original education entries versus 20 editable, reordered employment versus original order and completed import processing. Native tests decode this exact fixture. Parser runtime acceptance is owned and reported separately by MAT-8.

## Verification and native acceptance

Windows can run `python scripts/ci/ios-swift-static.py` and `python -m unittest discover -s tests -p test_ios_swift_static.py -v`. These prove structure and published call names, not Swift compilation, runtime behavior or layout. The old 38-method/192-assertion macOS shim result covers only the original checkpoint, not this candidate.

On a suitable hosted macOS runner with Xcode 15.4 or newer and XcodeGen, run `STACK_API_URL=https://stack.invalid bash scripts/ci/ios-swift.sh test` on the exact candidate. The Stack scheme includes both native unit and UI targets. Keep the xcresult and exported screenshots. Do not infer a pass from source inspection.

Required acceptance includes ResumeDocumentTests, ResumeDraftStoreTests and ResumeReviewControllerTests, plus every ResumeReviewFlowUITests case. Inspect focused layouts and keyboard scrolling on small and large iPhones with long text. Exercise import queued/parsing/completed/failed retry, reads arriving during edits, dismissal/background/restart, saved reorder versus original order, revision conflicts, save errors, draft-write errors and account switching during reads/saves. The offline fixture uses fictional data, a stub transport and a separate synthetic server store; saved values, revisions and confirmation survive relaunch.

Native compilation, native XCTest, rendered UI and device acceptance remain required before review/publication readiness can be declared. This task authorizes no push, PR, merge, signing, deployment or production changes.
