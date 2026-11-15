# Resume bullet bank

MAT-29 extends the existing private `Resume.review.records` store from MAT-25.
User-created entries have `review.kind=experience_bank`, an optional supporting
file, and remain outside the upload list, default selection and application
fallback. MAT-24's generic confirmed Resume source reader can reuse their current
records with its existing `resume:<jid>` identity and revision digest.

## Workflow

Open **Bullet bank** in the web workspace, or open the bank on the iPhone Resume
tab. Name an experience with its role/employer/project and dates, identify the
source, and enter one factual bullet per line. Save a draft or explicitly save
and confirm accurate facts. Editing retains the initial source and all saved
corrections; drafts cannot be selected for reuse. Imported resumes stay intact;
the iPhone's **Review details** screen edits and confirms extracted records.

Choose a confirmed PDF/DOCX record resume and select facts from other confirmed
experience groups or imported resumes. Save the selection, then start the usual
job-specific tailoring task. Imported headings and non-bullet context lines stay
in their original order to preserve employer/date/credential attribution. Stack
does not infer structured employment relationships or invent missing context.
Review the complete generated document and approve through the existing task.
LaTeX resumes continue using their existing source; bank composition requires
the reviewed-record path.

If a selected source changes, becomes a draft or is deleted, tailoring fails
closed. Reload the bank, remove the stale source or clear the selection, then
save again. New selections require the exact source revision. Final saved
documents retain their historical source snapshot; they do not become current
sources automatically.

## API and persistence

- `resume_bank`: private manual/imported records and record-resume selections.
- `resume_bank_save`: create/edit a manual group; optimistic revision and explicit
  confirmation. Original source plus up to 100 saved revisions are retained.
- `resume_bank_delete`: delete a manual group/history at the current revision.
- `resume_bank_select`: bind exact source revisions and record IDs to a confirmed
  record resume, with a target revision check.
- `resume_bank_attachment_save(id, revision, name, content)`: attach/replace one
  PDF or DOCX supporting document (base64, at most 10 MB). Empty name and content
  remove it. File changes increment the entry revision and return it to draft.
- `resume_bank_attachment(id)`: retrieve the current supporting document's name,
  size, SHA-256 digest and base64 content, within the signed-in account.

### Typed inputs (backend contract v1)

No client UI changes are included. `resume_bank` now returns `schema_version: 1`
and `entry_types`: the supported type keys, labels and field definitions. Each
field advertises an input hint, its text length limit and whether it is required
for confirmation. Dates are user-supplied text with a `month` input hint; links
are stored text with a `url` hint. The server does not fetch links or infer dates.

Types: `work_experience`, `project`, `skill`, `education`, `coursework`,
`certification`, `volunteering`, `leadership`, `award`, `publication`, `research`,
`language`, `activity`, `military_service`, `other`.

`resume_bank_save` additionally accepts `entry_type` and `fields` (a map of the
selected type's field names to text). Fields are replaced as a whole when sent;
omitting them preserves the saved fields. Omitting `entry_type` preserves the
saved type, or uses `other` for a new entry. Changing type requires sending the
new type's complete fields. Unknown types/fields are refused. Incomplete required
fields can be saved as drafts; confirmation requires them. Work experience needs
employer, job title and start date; projects have optional role, organization,
dates, technologies, project and repository links. Other definitions are available
directly in the response, rather than duplicated in a separate client schema.

`records` still contains user-authored paragraphs/bullets. Send `records: []` for
a field-only entry, such as a language with a proficiency. Drafts can start with
only a name and source; confirmation requires at least one field or record.
To select a field-only entry, use `record_ids: []`. All of an
entry's structured context accompanies any selected records, preserving employer,
date, credential and link attribution. Context consumes the existing composed
document limits. Type, fields and current file metadata are included in original
and revision snapshots and final composition provenance/digests. A supporting file
is stored as evidence; its contents are never automatically parsed or confirmed.

Storage adds versioned keys to the existing `Resume.review` JSON data; no table
replacement or destructive backfill is needed. Existing generic entries read as
`other` with empty fields, retain their IDs/history/confirmation and remain
editable through the old API. Imported resume sources are labeled `imported_resume`
and remain read-only in the bank. Older clients can continue sending their current
requests; editing a typed entry without the new parameters retains its metadata.
Confirmed structured context also appears in the existing story source reader.

Supporting documents use the existing private, account-scoped file store. Export
includes the current file content. Replacing/removing a file or deleting an entry
removes its previous file; history retains metadata, not historical file content.
Account deletion uses the existing Resume file cleanup.

The ordinary private graph/account boundary applies to every route. There is no
separate database. Account export includes manual records, original sources,
history and selections; account deletion removes the groups with other private
Resume nodes without assuming a file exists. Selected records are composed at
worker access and approval, remapped to unique IDs, and included in the tailoring
digest and final change record with source revisions, exact text and ID mapping.
History is excluded from model input. The model retains MAT-25's conservative
selection/rewrite guards and human approval boundary.

Bounds: 100 manual groups, 300 records/60,000 text characters per group or composed
resume, 2,000 characters per record. Overflow is rejected without truncation.
Export history before creating a replacement when the 100-revision bound is met.

## Verification

Lightweight checks: `python -m unittest tests.test_bullet_bank -v`.
Runtime lane: `python -m unittest tests.test_bullet_bank_workflow -v` and existing
`tests.test_record_resume`/`tests.test_gateway`, using a task-owned isolated Jac
cache and synthetic database. Check `main.jac`, gateway and both client components
with the pinned Jac compiler; build the web workspace and exercise the rendered
bank workflow. Physical iPhone checks remain separate from web/backend evidence.
