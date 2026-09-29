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
   - **Neither:** a resume that is only a PDF is never tailored. **Tailor for this job** asks for
     its LaTeX right there, then starts. A job uses its own resume, else the default resume.
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

## Scores

Tailoring is scored for the job before and after: job match and resume quality. It is guided by the
original resume's gaps. See [RESUME_SCORING.md](RESUME_SCORING.md).

## Where tailored resumes go

When a tailoring task finishes, Stack saves the final PDF and `.tex` under
**Resume → Tailored resumes**. That list is separate from **Your uploads**. Each item shows:

- the job and company it was tailored for;
- the resume it came from;
- a parser check.

The upload itself is never changed. Deleting a tailored resume removes only that copy.

## Parser check

Each tailored PDF is read back with the local OpenResume parser (`agents/parse_check.py`).
The parser's result is compared with what Stack wrote:

- the header's name, email and phone, which must match exactly;
- each work, education and project entry, with its bullets;
- every skill line;
- the absence of leaked LaTeX such as `[3pt]`.

The same check runs on the original upload's PDF. Issues that the original also has are marked
**also in your original upload**; tailoring did not cause those. The summary reads
"No new parser issues" when every issue is pre-existing. **Check again** reruns the check.

## Layout safety

- Skill blocks written as `\textbf{Label:} items \\[3pt] ...` inside one `\item` are read as
  separate skill lines, even when their items wrap over several lines. Labels and line breaks are
  never rewritten.
- A bullet containing line breaks is never reworded.
- Work, experience and education sections always keep their order; projects may move.
- If any LaTeX code shows up in the tailored PDF's text, no resume is produced.

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
- **Switching the phone preview with `./dev agent-experience` replaces this worktree's data with
  mainworktree's**, which has no LaTeX support, so uploaded LaTeX must be added again. Start the
  preview with `./scripts/dev` inside this worktree to keep its data.

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
- `./scripts/e2e-tailoring` runs the real phone screens against an isolated API, agent worker, your
  local Codex subscription (or `STACK_E2E_PROVIDER=claude-cli`), and Tectonic, on its own Postgres and
  port 8300. It covers both paths:
  - A job saved before any resume; the PDF-only resume is refused up front; LaTeX is added under
    the job (a broken file shows the compile error); then tailor, review, and approve.
  - A task whose resume lost its LaTeX after starting pauses as **Needs your LaTeX**. The LaTeX is
    uploaded from the task, and it continues to a final one-page PDF.

  It makes about three real model requests and takes several minutes.
- `STACK_TEST_TAILOR_UI=1 node tests/native.cjs` covers the phone review: reject and keep
  kept through refresh, approval sending the rejections, and the final result with LaTeX.
