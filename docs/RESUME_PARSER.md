# Resume Parsing

Stack uses OpenResume's layout-aware parser locally on the Mac. The iPhone uploads
the PDF to its existing private account store. Node reads it with PDF.js, applies
the vendored OpenResume extraction stages, and returns structured JSON. Jac owns
the review representation, authorization, persistence, and confirmation. No AI
requests, subscriptions, external parser service, or external telemetry are involved.

## Setup

Requires Node 22.13+ (or 24+) and Jac 0.37.21. `scripts/setup` includes:

```sh
npm --prefix integrations/resume-parser ci --no-audit --no-fund
npm --prefix integrations/resume-parser run build
```

The generated bundle is `.jac/resume-parser.cjs`. Do not delete `.jac`; it also
contains account data. `scripts/dev` starts the API, workers, and Metro as before.

Tailoring edits your uploaded LaTeX source when you provide one. Otherwise it fills a
built-in LaTeX template from these confirmed details. See `docs/RESUME_TAILORING.md`.

## Review Contract

**Resume > Review resume details** opens labeled, editable rows in collapsible
sections. Missing fields remain blank. Education, experience, and project entries
can be added. Other detected sections appear in Additional details. Original
extracted text is available separately to check omissions. PDFs are never modified.

Parsing saves an unconfirmed review and does not replace existing facts. Opening
the review again returns saved edits, not a new parse. Save draft replaces only
that resume's facts with unconfirmed entries. Confirm resume details replaces
them with confirmed, section-grouped facts; it never changes other resumes or
global profile facts. Optimistic revisions prevent stale saves from overwriting
edits. Account export includes the review; account deletion removes it with the PDF.

OpenResume primarily targets single-column English text PDFs. It can misclassify
fields and omit material, especially in multi-column layouts. No OCR is included.
Scanned/empty PDFs fail with an explicit message. Limits: 10 MB, 20 pages, 20,000
text items, 20 seconds, 20 entries per repeated section, 8,000 characters per
field, and 100,000 characters across review values. Grouped facts must also fit
the existing 8,000-character fact limit; oversized values produce an error, not
silent truncation. Confirmation is human review, not a parser accuracy guarantee.

## License and Provenance

User-approved AGPL-3.0 integration. Vendored source and full license:
`vendor/open-resume/`. Revision and modifications: `vendor/open-resume/NOTICE.md`.
The sample `tests/fixtures/openresume-laverne.pdf` comes from the same upstream
revision's `public/resume-example/laverne-resume.pdf`.

Stack's review UI, Jac parser adapter, and integration modifications are released
under AGPL-3.0. For distribution or hosted use, supply complete corresponding
source for the covered combined work, including modifications and build scripts,
to recipients/remote users as applicable. Do not publish this integration as a
closed-source service. Before deployment beyond this local personal setup,
provide an in-app source offer for the exact deployed version and complete the
appropriate license review. Linking only to the unmodified upstream is not enough.

## Verification

`JAC_TEST_JOBS=0 ./scripts/jac test tests/resume_parser_tests.jac` exercises the real
parser on the upstream sample, blank PDFs, validation, cached edits, confirmation,
legacy-fact replacement, revisions, account isolation, and application reload.
`node tests/native.cjs` covers the generated Jac review controls. These checks do
not certify arbitrary resumes or physical-iPhone layout.

## Persistent uploads and latency

PDF uploads now save the original and a durable parsing ticket before returning.
LaTeX and template uploads save their input and enqueue source parsing/compilation.
The existing agent-worker process starts an independent resume worker thread, so
model/browser work does not hold up this queue. The app shows bytes transferred,
then Queued, Parsing, Compiling, Completed, or Failed. Closing the app stops only
its polling; reopening reads the saved processing state. A failed job can retry
its retained input. Duplicate upload responses, lease expiry, source replacement,
and deletion cannot produce a second result or overwrite newer input. Parsing
still requires explicit review/confirmation before extracted facts become verified.

`stack.resume` logs job ID, kind, attempt, stage, and elapsed milliseconds without
resume text, filenames, account IDs, or tokens. Saved `processing` records expose
`transfer_ms`, `queue_ms`, `parse_ms`, and `compile_ms`. Transfer duration measures
the client request through the server's save acknowledgement; it is unknown until
the client reports it. Queue wait excludes an expired worker's execution lease.
Parsing and compilation use monotonic clocks, including failures. Preview recovery
also queues rebuilding rather than compiling inside a phone request.

Measured on October 1, 2026 using the repository sample: PDF parsing 0.29 seconds,
source parsing 0.0013 seconds, first compile into an empty SSD cache 59.21 seconds,
then repeat compile 0.51 seconds. The phone request timeout remains 20 seconds;
compilation's existing 120-second bound remains unchanged. Package/format cache
startup was the measured bottleneck. Timing evidence and local validation logs
are in `.jac/upload-diagnostics/`.

Compiler scratch/output goes to `.jac/resume-work/`, package/format caching to
`.jac/tectonic-cache/`, and original/generated files remain in `storage/resumes/`.
`scripts/jac` sends other temporary output to the short `.jac-tmp/` path beside the
common Git directory, on the repository's SSD. A deep worktree `TMPDIR` exceeds
Unix socket limits and can cause 60-second PostgreSQL startup waits. Use
`STACK_TMP_DIR` for an alternate short SSD directory and `STACK_JAC_CACHE_HOME`
for isolated test caches. Existing databases are preserved. On this SSD layout,
the launcher prefers the installed `.tools/jac/0.37.21/jac` over an incompatible
global development build; an explicit `STACK_JAC_BIN` still wins.

Additional verification:

```sh
./scripts/jac -m unittest discover -s tests -p test_resume_processing.py
STACK_TEST_UPLOAD_UI=1 node tests/native.cjs
JAC_TEST_JOBS=0 ./scripts/jac test tests/resume_parser_tests.jac tests/agent_experience_tests.jac
```

These tests cover byte progress, retry after a lost response, reopen, worker lease
recovery, compilation status/failures, input replacement, independent files,
ownership, and SSD paths. The native checks use mocked OS boundaries; physical
phone rendering/delivery is not certified. No deployment is performed.
