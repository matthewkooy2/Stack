# Memory-grounded resume tailoring

Tailoring a reviewed PDF/DOCX resume for a saved job now reads the user's whole
confirmed memory bank, the confirmed resume and the listing. The local model
(Qwen 3.8 27B on NInfer in the operator setup) selects entries, orders them and
words bullets. Stack decides what is true: every line must cite source line IDs,
fixed headers come from the user's own fields, and nothing is saved until the user
approves the reviewed change list. LaTeX and built-in template tailoring are unchanged.

## Memory access (`agents/memory_access.py`)

`_memory_snapshot()` in `main.jac` collects the signed-in, or leased, account's
own nodes and passes plain dicts to `memory_access.collect`. It holds no storage
handle of its own, so it cannot read across accounts. A snapshot contains:

| Kind | Included when | Key |
| --- | --- | --- |
| Memory bank entry (typed, any of the 15 types) | confirmed | `bank:<id>` |
| Imported resume records | confirmed | `resume:<id>` |
| Agent memory fact | verified | `fact:<key>` |
| Behavioral story | has reviewed STAR quotes | `story:<id>` |

Drafts and unverified facts are listed in `excluded` with a reason, never dropped
without notice. Every entry has stable line IDs (`name`, `f.<field>`, record IDs),
a deterministic header (title, organization and supplied dates; a missing end date
is never shown as Present), a digest, and a snapshot digest over all entries.

Reuse:

- **Worker steps** read it through `agent_worker_memory(token, id, owner, lease)`,
  which requires the worker token and a live lease for `tailor`, `approve_resume`,
  `interview_turn`, `interview_coach` or `coach`. `memory_access.validate` checks
  the owner and digests on the worker side. The gateway does not expose the route.
- **Interview coaching**: `interview_create` adds up to 6,000 characters of the most
  job-relevant confirmed experience, project, research, leadership, volunteering and
  service entries after the resume's own facts. `data.memory_coverage` names every
  candidate entry and whether it was included.
- Other features call `_memory_snapshot()` in the API or `leased_memory()` in the worker.

## Tailoring flow (`agents/memory_tailoring.py`)

1. **Plan the context.** The request size is counted the way `local_model.complete`
   counts it (UTF-8 bytes of system, JSON input and schema, plus output and 512 tokens
   of framing). The limit is the smaller of `local_model_context_tokens` and the
   context the server reports in `/v1/models`. Local compose requests reserve 6,144
   output tokens; screening and verification reserve 2,048. Paid providers keep their
   configured output limit.
2. **One call when it fits.** The compose request carries the listing, the resume
   (masthead, sections, entries, line IDs) and every memory entry in full.
3. **Screen when it does not.** Entries are packed into context-sized chunks of at most
   30 entries. The model rates every entry (0 to 100) and marks useful lines. The
   schema of each request requires one rating per entry handle in that chunk; with an
   open array, Qwen returned no ratings at all. An entry larger than a chunk is split
   into parts with its header repeated. Entries the model skips are asked once more. Then the compose request carries the highest-rated entries, in full
   or with only their marked lines when space is short. Coverage records which
   requests read each entry.
4. **Compose.** The model returns sections of items (`R.e<n>` resume entries,
   `E<n>` memory entries, or `SKILLS`), each with cited lines and a reason, plus every
   unused entry with a reason.
5. **Check every line.** A line must cite lines of its own entry. Two exceptions: a
   memory entry with the same organization and title as a resume entry's header may be
   cited inside that entry, and Skills lines may cite skills anywhere. A line is refused
   if it adds a number (digits or number words), a name, tool or acronym, or a scope or
   seniority word (led, managed, owned, team of, senior, certified, ...). It is also
   refused if it drops a negation or drops team credit ("Our team cut..." cannot
   become "Cut..."), if it is much longer than its sources, or, in Skills, if it lists
   an item or proficiency not in its sources. A refused line is replaced by its cited
   lines exactly as confirmed: resume content, or memory bullets inside the reviewable
   addition. Fields, headers and first-person notes ("I did not deploy it") are never
   printed alone, so those refusals are left out. Each refusal is a note. Typed jobs,
   degrees and credentials are placed under their own kind of section (the resume's
   heading when it has one), never under Projects or Skills.
6. **Verify.** Every reworded non-skills line goes to a second model request with its
   sources and any words borrowed from the listing. The schema requires a verdict for
   every line. Unsupported or unchecked lines revert the same way, so a verification
   outage cannot let a rewording through. Skills lines skip this request: their exact
   item check is stricter, and Qwen rejected correct skills lines.
7. **Review.** Changes are individually rejectable:
   `add:<entry>` (a memory entry), `add:<line>` (a same-role memory line),
   `rewrite:<line>`, `omit:R.e<n>` / `omit:R.r<n>`, and `order:sections`,
   `order:section:<heading>`, `order:item:<entry>`. Rejecting a rewrite prints the
   confirmed text. A resume line leaves the result only through an approved omission;
   anything else is restored to its entry in original order. The masthead is always
   kept verbatim. The review also shows the coverage report, the notes, page count
   and before/after scores.
8. **Finalize.** After approval the worker reads the resume and memory again. The
   resume digest, every cited memory entry's digest and header, and every cited line
   must be unchanged, and every line must pass the checks again. Then Stack builds the
   PDF and editable DOCX, checks their text and saves them under Tailored resumes with
   a change record that includes the memory sources and coverage.

Coverage statuses: `used`, `left_out` (model reason), `screened_out` (rated under
20), `did_not_fit` (relevant but no room; also a note asking for more context), and
`rated: false` when the model never rated an entry (Stack then ranks it by keyword
overlap and says so). If the listing and resume alone do not fit, the task pauses
with the required and available sizes. If the server rejects a prompt as too long,
Stack retries with 70% of the planned size, at most twice.

## Model capacity (operator PC, 2026-11-02)

NInfer 0.16.1 serves `qwen3.8-27b-ninfer` (17.0 GiB weights, `rk4v4` KV, DFlash2) on
an RTX 3090 (24 GiB). It was running with 32,768 tokens of context. The guarded
restart in `output/ninfer-stack-64k/restart.ps1` raised it to 65,536:

| Context | NInfer runtime | Free beside model | Card in use |
| --- | --- | --- | --- |
| 32,768 | 1.80 GiB | 4.50 GiB | 19.7 GiB |
| 65,536 | 2.56 GiB | 4.00 GiB | 20.3 GiB |

A 57,038-token prompt completed in 28.7 seconds and recalled its final line. A longer
prompt got HTTP 400 `context_length_exceeded` (no truncation). Because Stack counts
bytes, 65,536 tokens hold roughly 58 KB of request, enough for a typical whole bank in
one call; larger banks are screened. Stack's configuration cap rose from 32,768 to
262,144 tokens. Deploying this branch needs `local_model_context_tokens: 65536` in
the private agent configuration (both the top level and `model_options.local`).
The server-reported value still caps planning if the server holds less.

## Verification

```sh
jac check main.jac agents/worker.jac agents/provider.jac agents/local_model.jac agents/contracts.jac agents/experience.jac core/automation.jac
jac run --no-serve tests/test_memory_tailoring.py
JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_memory_tailoring_workflow.py
# With the local model:
STACK_TEST_REAL_MODEL=1 STACK_TEST_MODEL=qwen3.8-27b-ninfer STACK_TEST_MODEL_URL=http://<host>:<port> \
  JAC_DB_SCRATCH=1 JAC_TEST_JOBS=0 jac run --no-serve tests/test_memory_tailoring_workflow.py
```

The fixtures in `tests/memory_tailoring_cases.py` are fictional and were fixed before
any model run. They include traps: listing-only requirements (Power BI, healthcare
claims, leading projects, a Green Belt, SolidWorks), negated facts ("did not deploy",
"have not earned a Green Belt"), an assisted-not-managed changeover, an unconfirmed
draft, a second account's memory, and an 86-entry bank.
