# Reviewed PDF/DOCX tailoring (MAT-25)

The backend accepts a text-based PDF or DOCX without requiring LaTeX. It retains
the original bytes and imports each visible text line into editable records.
Import does not infer employers, dates, achievements or credentials and does
not silently confirm facts. A reviewer must check reading order, line wrapping,
and completeness, then explicitly confirm the records and choose a Stack
template. The output uses that template; the uploaded layout remains in the
unchanged original file.

## API and worker flow

1. `upload_resume(name, content)` accepts base64 PDF/DOCX up to 10 MB and queues
   an account-owned `import` ticket. The existing resume worker claims it via
   `resume_processing_claim`, calls `import_records`, and finishes it with the
   extracted records. Import failures can retry using
   `retry_resume_processing(id, kind="import")`. Leases reject stale/deleted work.
2. `agent_extract_resume(id)` returns processing state or the imported records,
   original extracted records, revision and confirmation state. `read_resume`
   returns the original bytes plus that review. Identical uploads under the same
   filename are idempotent; separate names/accounts have independent files.
3. `resume_save_records(id, revision, records, confirm, template)` requires the
   current revision. Each record has a unique `r<number>` id, `kind` (`title`,
   `heading`, `paragraph`, `bullet`) and text. Optional `allow_omit: true`
   explicitly marks a bullet eligible for
   model selection; records remain by default. Review can correct extraction,
   combine wrapped lines, set semantic roles or select content. Reconfirm after
   editing. Supported templates are `classic` and `jake`; changing template
   increments the source revision. Uploaded LaTeX still takes precedence until
   a reviewed-record template is selected through `use_resume_template`.
4. Start the existing `resume` agent for a saved real job. Unconfirmed imports
   are refused. The worker retrieves records only under a valid owner/run/lease
   and supplies their stable outline to the configured provider. No provider
   permission or budget gate is bypassed.
5. Supported proposals reorder contiguous bullet groups, select explicitly
   eligible undated bullets
   without known credential wording, or remove initial `I `, `Successfully ` or
   `Duties included: ` while keeping the remaining claim exactly. General
   paraphrases are ignored with notes. Records containing numeric dates/metrics,
   headings and paragraphs
   cannot be automatically removed. The eligibility flag must be reviewed carefully
   for written-out dates/metrics or credentials unfamiliar to the guard; unmarked
   records cannot be omitted. There is no automatic one-page trimming.
6. `agent_approve(id, step="approve_resume", review_hash, edits={"rejected":[]})`
   approves the exact change plan. Rejected rewrites, omissions and ordering
   changes revert independently. The final worker rebuild checks the current
   source digest; any record/template revision invalidates the previous proposal.
7. `read_tailored_resume` returns both generated files and a factual change
   record (upload digest, reviewed records/revision, proposed changes, notes and
   rejected ids). Files are saved separately from uploads. `check_tailored_resume`
   independently extracts PDF and DOCX text and compares both with the approved
   records. Export includes these files; resume/account deletion removes both.

The new review/save API is allowed through the gateway. Mobile/web review and
DOCX download UI are separate product work; this issue delivers the backend.
The retired semantic `resume_save_details` endpoint stays disabled and existing
confirmed facts are retained. Multi-column PDFs need reading-order review.

## Document and input limits

PDF input uses the existing OS-bounded parser. DOCX ZIP/XML uses that same
isolated subprocess lane, with no site hooks and two bounded document slots.
ZIPs are limited to 256 members and 8 MB total expansion. Macro/embedded content,
headers/footers, tracked changes, drawings and unsupported XML content are
refused so facts are not silently lost. DOCX tables are read in XML order and
must be checked during review. Image-only PDFs need a text-based export; no OCR
or model-based fact extraction is performed.

Records are limited to 300, 2,000 characters each and 60,000 total characters.
PDF output uses bundled Vera fonts and letter pages with 0.6-inch margins.
Unsupported glyphs fail generation instead of disappearing. DOCX uses native
editable OOXML paragraphs, bold titles/headings, hanging bullet indentation and
matching letter-page margins. Templates differ in spacing. Long resumes retain
their records across pages. Both files must independently extract to the approved
text before the worker can return them.

## Fixed verification fixtures and commands

`tests/fixtures/record-resume.json` is fictional and fixed before model tuning:
Alex Éxample; Jan 2022–Dec 2024; a 25% dashboard metric; AWS Certified Cloud
Practitioner; and an explicit statement that the person did not lead a team or
hold a CPA license. Input PDF and DOCX fixtures are produced independently of
the output generator. Checks cover import, supported/unsupported edits, rejected
changes, multiple pages, unsafe documents, review revisions, complete worker/API
flow, persisted reload, two-account isolation and original-byte preservation.
Independent readers inspect PDF text, page geometry/positions and OOXML text,
package integrity and page settings.

```sh
jac check main.jac agents/worker.jac agents/provider.jac agents/resume_processing.jac core/automation.jac agents/gateway.jac agents/experience.jac
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_record_resume.py
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_resume_processing.py
# Opt-in, with an already configured local inference service:
STACK_TEST_REAL_MODEL=1 STACK_TEST_MODEL=your-local-model \
  STACK_TEST_MODEL_URL=http://127.0.0.1:1234 JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 \
  jac run --no-serve tests/test_record_resume.py
```

The live run uses real provider HTTP inside the worker, retains accepted model
response logs, and prints source format, reported model, elapsed seconds and API
cost. It rejects all model-proposed edits in the acceptance fixture to check that
the user retains control. Deterministic checks separately apply and reject
supported changes. Provider calls are the only controlled part of the standard
integration test; import, rendering, extraction, API, storage and workers are real.

Implementation, verification, independent review, merge and deployment are
recorded separately in MAT-25 and the PR. Test success is not a deployment claim.
No production deployment or physical-device/UI quality verification is included.

## Observed local verification (2026-10-06)

Jac 0.37.21 passed checks for all eight affected server modules. Four document
checks initially passed on Windows Python 3.11.15. An additional regression
preserves native DOCX nonbreaking hyphens in negative metrics through both
outputs; tracked moves are refused along with insertions and deletions. A further
regression retains an unfamiliar credential while allowing explicitly reviewed
selection of a noncredential bullet. The initial deterministic Jac suite passed six
checks; the expanded suite has eight checks. The corrected live worker suite
passed all eight, including both uploaded
formats, actual provider responses, independent file extraction, reload,
account isolation, template selection, stale leases and deletion of both files.
Native DOCX package validation opened, edited, saved and reopened the generated
file with python-docx 1.2.0. PyMuPDF 1.26.7 rendered the PDF for visual inspection.

The live provider was LM Studio (CLI revision `efce996`), model alias
`mat25-qwen3`, with Qwen3-4B-Instruct Q4_K_M weights. The GGUF SHA-256 was
`85e4a5b7b8ef0e48af0e8658f5aaab9c2324c76c1641493f4d1e25fce54b18b9`.
Context was 32,768 tokens with a 2,048-token output limit. The fictional fixture
was fixed before these calls. Accepted responses proposed supported filler
removals and an eligible content omission; rejecting them retained all ten source records.

| Measurement | Observed value |
| --- | --- |
| PDF worker through approval/export/reload | 31.17 seconds |
| DOCX worker through approval/export/reload | 26.16 seconds |
| Corrected live suite execution | 177.581 seconds |
| Initial live Jac command, including compilation and shutdown | 200.49 seconds |
| Initial live Jac command maximum resident memory | 1,977,768 KiB |
| Loaded GGUF file | 2,497,280,480 bytes |
| Reported API cost | 0 cents (local inference) |

The host had a Ryzen 5 2600 (6 cores/12 threads), approximately 16 GiB RAM and
an RTX 2070 SUPER with 8,192 MiB VRAM. Command memory excludes the separate
Windows inference service. The service used an isolated model alias and a local
WSL/Windows HTTP relay; requests still reached the actual provider. Measurements
are fixture observations, not production throughput estimates. Raw check and
resource logs are retained with the task evidence; the PR/issue identify the
reviewed source revision. UI/device quality and deployment remain separate gates.

The existing uploaded-LaTeX/review workflow suite also passed two tests with
actual Tectonic compilation (256.07 seconds). Legacy durable processing passed
nine tests (139.478 seconds). Six document regressions passed on Windows after
the independent review corrections.

One corrected live attempt was refused by source-quotation validation and
produced no final DOCX files. A diagnostic rerun retained full accepted provider
responses and completed both formats. The refusal is preserved in the raw
evidence; source validation was not relaxed.
