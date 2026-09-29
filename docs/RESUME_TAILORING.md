# Resume Tailoring

Tailoring edits a LaTeX resume for one saved job. The layout stays yours, the result
fits on one page, and every change is shown to you to keep or reject before the PDF is used.

## Why it changed

The previous version rebuilt a PDF from scratch with ReportLab. It put one paragraph per
confirmed fact, printed the field labels ("Company:", "Descriptions:"), and had no sections
or bullets. It could only reorder whole entries: the model had to keep every fact word for
word, so the result could never get shorter or more focused, and page count was never checked.

## How it works

1. **Source.** Each resume can have a *tailoring format*:
   - **Your LaTeX:** a `.tex` file, or Overleaf's source `.zip` (Menu → Download → Source).
     On upload, Stack does four things:
     - It lints the source, refusing `\write18`, `\openin`, `\directlua`, and paths outside the project.
     - It inlines any `\input` files from the project.
     - It compiles the source unchanged.
     - It finds the editable structure.
   - **Built-in template:** Jake's Resume or Classic (`agents/templates/`), filled from
     confirmed resume details (`agents/resume_templates.py`).
   - **Default:** with no format chosen, Jake's Resume is filled from your confirmed details.
2. **Structure.** `agents/latex.py` finds, by source position:
   - sections: `\section`
   - entries: heading macros with `\item` in their definition, such as `\resumeSubheading`
   - bullets: one-argument item macros such as `\resumeItem`, or plain `\item`
   - skill lines: `\textbf{Label}{: items}`

   Each item gets a stable id (`s1.e0.b2`). The model sees only this outline as plain text.
3. **Proposal.** The model returns a relevance ranking of every bullet, optional entry
   order, rewrites in plain text (`**bold**` allowed), and omissions. `agents/tailoring.py`
   discards any rewrite that:
   - adds a number not in that bullet or your verified facts
   - names a tool or proper noun that is not in your resume or facts
   - adds a skill to a skill line (skill lines can only be reordered or shortened)
   - grows much longer than the original

   Each discarded rewrite is listed with its reason.
4. **Edits.** Stack changes only content spans. Rewrites are escaped (`& % $ # _ { } ~ ^`), so
   the preamble, macros, and spacing stay exactly as uploaded.
5. **One page.** Stack compiles with Tectonic. If the result is over one page, it binary-searches
   how many of the lowest-ranked bullets to drop, never emptying an entry. After that it drops
   whole entries, never emptying a section. Everything left out is listed.
6. **Review.** The `approve_resume` step pauses for your review:
   - Keep or reject each rewrite, omission, and reorder.
   - Approval is bound to that exact proposal and your choices.
   - The worker then rebuilds and refits the PDF with only the changes you kept.
   - In **Prepare & apply**, this happens before the separate review of form answers and documents.

   Nothing is shared by approving resume changes.

Results show the PDF, each change with its reason, what was left out, the original and
tailored text, and the tailored `.tex` to copy back into Overleaf.

## Setup

`scripts/setup` installs Tectonic (`brew install tectonic`) and compiles the templates once,
so the package cache is warm. Stack runs Tectonic in `--untrusted` mode in a temporary folder.
Overleaf uses pdfLaTeX. To bridge that, Stack prepends a one-line compatibility shim when
compiling (`\pdfgentounicode`, `glyphtounicode`). The shim is never stored in your source.

## Limits

- **Only content is edited.** Stack never changes the header (name and contact), dates,
  or the formatting of entry headings.
- **Multi-column and heavily custom templates may expose fewer editable bullets.** If
  Stack finds no bullets, upload is refused and the message names the problem.
- **XeTeX spacing can differ slightly from Overleaf's pdfLaTeX** for some fonts. Stack
  checks the page count against its own compile.
- **The cover letter still uses the simple generated PDF.**

## Verification

- `PYTHONPATH=tests:. .jac/venv/bin/python -m unittest tests/test_latex.py` covers:
  - loading, zip unwrapping, and flattening
  - refusing unsafe sources
  - structure of Jake's Resume
  - escaping, and preamble bytes kept
  - discarding unsupported proposals
  - real compiles, with error lines
  - fitting a two-page resume onto one page
  - rebuilding without rejected changes
- `JAC_TEST_JOBS=0 ./scripts/jac test tests/agent_experience_tests.jac` covers the built-in
  template path and the uploaded-LaTeX path end to end:
  - worker dispatch with a stand-in model
  - review and rejection
  - the rebuilt final PDF
  - ownership checks
  - approval before **fill** in the application flow
- `STACK_TEST_TAILOR_UI=1 node tests/native.cjs` covers the phone review: reject and keep
  kept through refresh, approval sending the rejections, and the final result with LaTeX.
