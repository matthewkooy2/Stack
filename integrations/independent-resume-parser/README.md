# Independent resume parser (standalone prototype)

This module is an original, deterministic implementation from the task's functional
requirements and the public PDF.js API documentation. It does not import or call
Stack's previous resume parser. No application routes, Jac code, review UI, or
repository licensing are changed.

## Run

Requires Python 3.11+ and Node 22.13+ (Node 24 LTS recommended). From this directory:

```sh
npm ci --ignore-scripts
python -m resume_parser /path/to/resume.pdf > review.json
python -m unittest discover -s tests -v
```

Use `--node /absolute/path/to/node` if your default Node is older. For tests, set
`STACK_PARSER_TEST_NODE` to that path. Python uses only the standard library.
The optional canvas package must remain installed: PDF.js loads its geometry
classes in Node even though this module does not render pages.

```python
from resume_parser import parse_pdf, ParseError, Limits

try:
    result = parse_pdf('resume.pdf')
except ParseError as error:
    print(error.code)  # stable code, never resume text
```

## Output and review contract

- `source.pages[].spans[]` retains every PDF.js text item verbatim (normalization
  disabled), including empty items, direction, end-of-line marker, and coordinates.
  IDs identify page/item positions. `bbox` is `[x, baselineY, width, height]` in
  page viewport points, with top-left origin; it is not a precise glyph rectangle.
- `contact` contains name, email, phone, and URL **candidates**. Pattern matches
  include exact values, line character ranges, heuristic confidence, reasons,
  and source span IDs. The first-line name candidate has deliberately low confidence.
- `sections` contains education, employment, projects, skills, unclassified, and
  contact blocks. Blocks contain editable text, original lines, literal date tokens,
  confidence, reasoning, and provenance. It does not invent an employer, title,
  degree, date boundary, skill, or achievement to fill a schema slot.
- Every nonempty source item belongs to exactly one section block. Contact/date
  candidates additionally reference the same evidence. Unknown text stays in a
  block; display line construction may add separating spaces or newlines but
  never replaces the underlying span text.
- `status` is always `needs_review`; confidence is a heuristic score, **not a
  calibrated probability**. `reviewed` begins false. Preserve `source` separately
  when saving user edits; it is ordinary JSON, not cryptographically immutable.

A future independent review UI should show the source and candidate blocks side by
side, allow moving/splitting blocks and editing fields, surface uncertain matches,
and require explicit user acceptance before writing a profile. Render all text as
text, never trusted HTML. This PR supplies editable data, not a review UI or adapter.

## Coverage and limitations

English headings and a small set of conservative heading-free cues are supported.
Repeated whitespace supports ordinary two-column layouts; each column has separate
heading state. Full-width headers are retained. Dates at a right margin should not
become a separate column. Page changes reset heading state to avoid false carryover.

Complex mixed layouts, three columns, tables, rotated/vertical text, right-to-left
reading order, unusual fonts, broken character maps, localized headings, and
continuations without headings may be ambiguous. Text is preserved for correction,
but reading order and category inference are not guaranteed. A section block may
contain multiple jobs/projects; this first version does not claim record-level
employer/degree extraction. No real-world accuracy percentage is claimed.

Image-only/scanned PDFs return `NO_EXTRACTABLE_TEXT`, with no fabricated content.
No OCR, LLM, external service, URL fetch, annotation/attachment extraction, or PDF
JavaScript execution is performed. Text unavailable to PDF.js cannot be recovered.
Password-protected PDFs require an unlocked copy. Structural errors reject the
whole parse rather than silently delivering partial output.

## Hostile input controls

The Python entry point is mandatory; do not expose `extract.mjs` directly.

| Control | Default |
| --- | --- |
| Input bytes | 10 MiB |
| Pages | 20 |
| Extracted UTF-16 code units | 250,000 |
| Text items | 25,000 |
| Extractor output | 12 MiB |
| Worker memory | 1.5 GiB |
| JS old-space heap | 192 MiB |
| Wall time | 20 seconds |
| POSIX CPU time | 15 seconds |
| Captured diagnostics | 4 KiB; worker killed at cap |

Each request uses a private random temporary directory and a copied regular-file
input; temporary files are removed on success and failure. Uploaded names are never
used as paths inside the directory. No shell is used to launch the extractor.
Node preload hooks, proxy variables and credentials are not inherited. Source PDF
bytes travel via a private file, with only control JSON on stdin. The worker waits
for the supervisor before importing PDF.js or reading the document.

Windows uses a Job Object with aggregate committed-memory and active-process limits
and kill-on-close. POSIX uses address-space, CPU, file-size, file-descriptor and
core-dump limits. A JS heap cap alone is **not** considered a memory limit. Setup
failure rejects parsing. Timeouts kill and reap the process; no partial result is
returned. Windows committed memory and POSIX virtual-address limits are different
metrics. Other POSIX platforms require validation before support is claimed.

These controls contain resource abuse; they are not an exploit-proof OS sandbox.
For a public upload service, run under a dedicated low-privilege identity/container
with networking disabled, restrict filesystem access, cap request concurrency,
and apply an upload quota before calling this module. Call from a dedicated worker
process on POSIX: Python `preexec_fn` is unsuitable inside a multithreaded service.
Ordinary parsing makes no network calls, but this module does not install a network
firewall. File paths, executable paths and limit overrides are trusted caller
configuration, not end-user form fields.

Errors include `INPUT_LIMIT`, `INPUT_UNREADABLE`, `NOT_REGULAR_FILE`, `INVALID_PDF`,
`PASSWORD_REQUIRED`, `PAGE_LIMIT`, `TEXT_LIMIT`, `SPAN_LIMIT`, `OUTPUT_LIMIT`,
`INVALID_GEOMETRY`, `TIMEOUT`, `WORKER_FAILED`, `RESOURCE_SETUP_FAILED`,
`NODE_NOT_FOUND`, `RUNTIME_UNSUPPORTED`, `DEPENDENCY_FAILED`, and `INVALID_OUTPUT`.
Memory/CPU termination reports `WORKER_FAILED`; the OS may not identify the cause.

## Independence and validation

No contents from `vendor/open-resume`, `integrations/resume-parser`,
`agents/resume_parser.jac`, or `mobile/components/ResumeReview.jac` were read,
copied, translated, or adapted during this implementation. Renaming or rewriting
copied code would not remove its license. This work does not make a claim about
the license status of other Stack files or releases. Dependency details and
redistribution notices are in [DEPENDENCIES.md](DEPENDENCIES.md).

All test resumes are fictional and generated by `tests/fixtures.py`, an original
minimal PDF writer. No downloaded resume fixtures or real personal data are used.
Tests verify text coverage/provenance and category isolation, not just snapshots.
Resource tests exercise actual subprocess timeouts and external-buffer exhaustion.
Synthetic coverage does not replace a future consented evaluation corpus.

API references consulted: [PDF.js API](https://mozilla.github.io/pdf.js/api/),
[document parameters](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib.html).
