# Resume Parsing

Stack uses OpenResume's layout-aware parser locally on the Mac. The iPhone uploads
the PDF to its existing private account store. Node reads it with PDF.js, applies
the vendored OpenResume extraction stages, and returns structured JSON. Jac owns
the review representation, authorization, persistence, and confirmation. No AI
requests, subscriptions, external parser service, or telemetry are involved.

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
