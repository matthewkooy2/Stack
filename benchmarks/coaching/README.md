# Stack coaching benchmark

Portable manual benchmark for choosing a cheap API for Stack's interview and prep
coaching. Actual provider calls are intended to run on the PC. Python 3.10+ and
the standard library are sufficient; no Jac runtime, CLI AI subscription, GPU,
third-party Python packages, or running Stack server is needed.

Status: dataset and offline runner built; live provider access, response formats,
quality, latency, and billing still require the PC smoke test and full run.
No empirical provider winner has been established.

## What is included

- **60 distinct questions with 60 authored answers:** 24 behavioral, 36 technical.
- **6 additional answer variants:** formatting, hesitation, and concise wording,
  for **66 total cases**. Variants retain their parent's reference scores.
- Strong, partial, and incorrect answers, including polished misinformation,
  prompt injection, no answer, limited experience, unsupported metrics, and
  transcript uncertainty. Examples are fictional and contain no real user data.
- Per-criterion 0–4 reference scores, a one-point tolerance, case-specific review
  guidance, and separate general rubric anchors.
- 55 development cases and 11 holdout cases, assigned deterministically by question
  family. Variants never leak across the split.
- Four candidate API adapters, resumable run records, planning budget checks,
  actual reported token/cost estimates, repeat stability, and blinded review cards.
- Optional cross-provider semantic reviewers to inspect correctness, grounding,
  actionability, calibration, and serious coaching defects.

These are **synthetic, agent-authored provisional references**, not human-rated
ground truth. Three repeat calls test nondeterminism; they do not create three
independent examples. Do not claim statistical certainty from this sample.

## API keys needed on the PC

| Environment variable | Candidates | Optional reviewer |
|---|---|---|
| `OPENAI_API_KEY` | `gpt-6-luna` | `gpt-6.1-sol` |
| `ANTHROPIC_API_KEY` | `claude-haiku-5-5` | `claude-sonnet-5-5` |
| `GEMINI_API_KEY` | `gemini-3.1-flash-lite`, `gemini-2.5-flash-lite` | — |

The accounts need API billing and access to these model IDs. A consumer chat or
coding subscription is not the credential this runner uses. A free Gemini quota
may introduce throttling that is unrepresentative of the intended paid setup.
If an ID is unavailable, record the failure, choose a currently accessible ID in
`models.json`, update its prices from official docs, and start a fresh directory.
Never silently substitute a model in the middle of a run.

Set keys in the PC agent's environment or Windows secret management. Do not put
keys in source, chat, config JSON, or command-line arguments. For a temporary
PowerShell session, these prompts hide the input:

```powershell
$env:OPENAI_API_KEY = [System.Net.NetworkCredential]::new('', (Read-Host 'OpenAI API key' -AsSecureString)).Password
$env:ANTHROPIC_API_KEY = [System.Net.NetworkCredential]::new('', (Read-Host 'Anthropic API key' -AsSecureString)).Password
$env:GEMINI_API_KEY = [System.Net.NetworkCredential]::new('', (Read-Host 'Gemini API key' -AsSecureString)).Password
```

## Run on Windows

Extract the supplied standalone archive, then open PowerShell in its `coaching`
folder. From a repository checkout, use `benchmarks/coaching` instead. Replace
`py -3` with `python` if that is how Python is installed on the PC.

First run offline validation and the local harness tests:

```powershell
py -3 benchmark.py validate
py -3 -m unittest discover -s . -p 'test_*.py' -v
py -3 benchmark.py plan
```

Smoke test **each provider separately** before the full matrix. This checks model
access, the documented JSON dialect, output allowance, quota, and billing fields.
Each command makes two requests; failures stop without hidden automatic retries.

```powershell
py -3 benchmark.py run --candidates luna --limit 2 --repeats 1 --out results/smoke-luna --budget 1
py -3 benchmark.py run --candidates haiku --limit 2 --repeats 1 --out results/smoke-haiku --budget 1
py -3 benchmark.py run --candidates gemini --limit 2 --repeats 1 --out results/smoke-gemini --budget 1
py -3 benchmark.py run --candidates gemini25 --limit 2 --repeats 1 --out results/smoke-gemini25 --budget 1
```

Inspect the smoke records, including truncation, token usage and model reported by
the provider. If any request parameter needs adjusting, rerun the offline tests and
all smoke tests using new output directories before starting the full run.

Full candidate comparison: **66 cases × 4 models × 3 repeats = 792 requests**.

```powershell
py -3 benchmark.py run --out results/pc-full-01 --repeats 3 --budget 5
py -3 benchmark.py report --out results/pc-full-01
```

The full run is serial and interleaves models/cases in a reproducible shuffled
order. It may take hours depending on latency and quotas. The program prints
progress and flushes each attempt to disk. Rerun the same command to resume known
attempts; completed and failed attempts are never silently repeated. The $5
allowance includes any judge costs already recorded in that directory.

Optional blinded semantic review of the **first repeat** (264 reviews):

```powershell
py -3 benchmark.py judge --out results/pc-full-01 --repeats 1 --budget 25
py -3 benchmark.py report --out results/pc-full-01
```

`sonnet-judge` reviews Luna/Google outputs, while `sol-judge` reviews Haiku outputs.
Reviewer inputs omit candidate provider/model identity and include the answer,
feedback, and provisional references. The reviewers use high effort; candidate
models use low effort, with thinking disabled for Gemini 2.5 Flash-Lite. Output
caps are 4,096 tokens by default. Reasoning may exhaust the allowance and produce
an incomplete response; that counts as a failure, not a successful evaluation.

Judge calls cost extra and can cost substantially more than the cheap candidates.
The $25 cumulative allowance is a stop estimate, not a promised final bill. Use
`judge --limit 10 --repeats 1` for a smaller initial review and later resume without
the limit. Check the provider dashboards as well as the runner's usage estimates.

To tune prompts, use `--subset development`, then freeze the dataset, runner,
models, and settings before inspecting `--subset holdout`. Use a new directory
for every protocol change. The full-all command is appropriate for an initial
comparison without prompt tuning; once the holdout has influenced tuning, replace
it with genuinely new cases before claiming held-out performance.

## Outputs and interpretation

| File | Purpose |
|---|---|
| `manifest.json` | Dataset, config, runner and prompt hashes; request settings and Python version |
| `attempts.jsonl` | Every candidate attempt, raw response, model identity, usage, cost, latency, feedback, and validation |
| `judgments.jsonl` | Separate reviewer attempts and costs; links to candidate task IDs |
| `summary.json` | Per-model metrics plus behavioral/technical and development/holdout slices |
| `comparison.md` | Readable comparison, with missing metrics explicitly pending |
| `blind-review.json` | Shuffled feedback cards for another agent or a person to inspect |
| `review-key.json` | Review-ID mapping; keep away from a blinded reviewer until after their assessment |

Reference MAE measures distance from provisional authored scores. Within-one rate
uses a generous one-point tolerance; do not treat it as coaching accuracy. Exact
quote checks detect invented quotations but cannot establish that an interpretation
is correct or that every factual claim is supported. Semantic reviewers address
that gap, but they can also be wrong. Their outputs are estimates, not truth.

Judges differ across candidates to avoid direct self-review. This creates a
reviewer-confounding effect: **do not rank models solely by judge averages**.
Inspect a common blinded sample across all four models and independently adjudicate
disagreements and all critical issues. This review can be done by a separate agent;
a small user spot-check remains useful for personal coaching preferences.

Selection should consider all of the following, on the same cases/repetitions:

1. Schema/completion and grounded-quote reliability; never hide failed attempts.
2. Technical correctness and absence of fabricated candidate facts or unsafe advice.
3. Actionable improvements and follow-ups, not generic praise or demands for invented metrics.
4. Reference agreement, including behavioral/technical and holdout slices.
5. Stability across repeats and the paired answer variants.
6. Total candidate cost per valid feedback result and p50/p95 response latency.

The report deliberately does not invent a winner before comparable live results
and semantic review exist. Partial coverage and reviewer disagreements must remain
visible. Record the eventual decision with the run's hashes and justified tradeoff.

## Cost, failures, and reproducibility

Prices in `models.json` were checked against official sources on **2026-10-28**:

| Candidate | Uncached input USD / 1M | Output USD / 1M |
|---|---:|---:|
| Luna | 0.10 | 0.50 |
| Haiku 5.5, prompts <=100K | 0.10 | 0.50 |
| Gemini 3.1 Flash-Lite | 0.25 | 1.50 |
| Gemini 2.5 Flash-Lite | 0.10 | 0.40 |

Sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[Google pricing](https://ai.google.dev/gemini-api/docs/pricing).
API shape references: [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs),
[Anthropic structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs),
[Gemini REST structured outputs](https://ai.google.dev/gemini-api/docs/generate-content/structured-output).

The offline plan currently reserves about **$3.04 for candidates only**, assuming
one input token per UTF-8 byte plus framing/schema allowance and the full output
cap. This conservative estimate is not a tokenizer or an invoice guarantee.
Caching, actual reasoning, tokenizers, and provider-side accounting can change the
cost. Usage-based estimates include OpenAI reasoning once, Google thought tokens
in addition to candidate tokens, and Anthropic cache reads separately from base
input. No cache writes are requested. Unknown usage is **unknown**, never zero.
Rates for long contexts and regional endpoints are outside this small-text setup.

An HTTP/network failure with unknown billing stops the run. Inspect the provider
dashboard before using a new run directory. A persisted `inflight.json` means the
process stopped during a request: **do not delete it and blindly retry**. Reconcile
the possible charge and keep that directory for audit, then use a new directory
for remaining comparisons. Results from different directories must not be casually
combined; retain their manifests and record why coverage differs. The runner never
prints API keys or HTTP error bodies. It refuses redirects and does not auto-retry.

The output directory is a single-writer journal: do not start two runner processes
against it. Protocol hashes prevent accidental mixed-version resumes, but provider
aliases may change behind the same model ID. Preserve reported model versions and
dashboard records. Use pinned versions if supported and rerun all candidates after
changing one. Sequential latency includes cold schema-compilation requests; it is
not a throughput/concurrency benchmark.

## Relationship to Stack

Grounded in the question catalog in `agents/prep.jac`, the provider policies in
`agents/provider.jac`, and the saved-role interview flow in `agents/interview.py`
at baseline commit `859fa64`. The normalized benchmark output is a **proposed
structured coaching contract**, not the current production interview API. Current
interview coaching uses plain text, and prep uses a different route. This benchmark
does not change those flows or prove an end-to-end migration, multi-turn interview,
speech recognition, native UI, or concurrent production service.

Technical reference checks include trusted local SQLite and algorithm counterexamples;
the runner never executes model-provided code. The local tests also exercise all
four adapters with simulated responses, repeats, resumption, independent judging,
and reporting. Simulated results are test fixtures and are never packaged as live
comparison evidence. No CI jobs or blocking gates were added.
