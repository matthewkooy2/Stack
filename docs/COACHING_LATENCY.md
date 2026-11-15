# Coaching latency and provider options

Issue #124. Measured on October 30, 2026, on a MacBook (8 GB) with the Claude CLI
signed in to a Claude subscription. Inputs were three synthetic answers to the
"project" question in `scripts/coach-latency-bench.py`: a short answer, a typical
STAR answer and a rambling one. Each answer was run twice per configuration.

## Where the wait goes

`scripts/coach-latency-bench.py --workflow` runs the whole server path in a
disposable database and times each phase. Results for the three answers, structured
coaching on the CLI default model:

| Phase | Time |
| --- | --- |
| Save the answer, queue the run (`prep_create`, `prep_save`, `agent_start`) | 31–50 ms |
| Worker claim (`agent_claim`) | 11–15 ms |
| Coach step (model call and parsing) | 8.7–11.8 s |
| Store the result (`agent_finish`) | 16 ms |
| App reads the result (`prep_get`) | 8–9 ms |

The model call is about 99% of the wait. Two delays sit outside this measurement:

- **Worker pickup**: the worker sleeps 3 s between idle polls, so up to 3 s (1.5 s on
  average).
- **App delivery**: the app polls every 0.8 s while coaching runs.

Together they add at most about 4 s. The CLI sign-in check before each request takes
0.15 s.

The 26–45 s waits in #112 were measured on a phone with a model that wrote long
prose, so they match the "main" row below, plus transcription, pickup and network
time.

## Results (model call, median of 6)

| Configuration | Median | Range | Reply length | Scores parsed |
| --- | --- | --- | --- | --- |
| main, prose, CLI default (Opus 5.5) | 19.1 s | 16.6–20.4 s | 666 words | no |
| main, prose, Haiku 5.5 | 10.3 s | 8.9–12.9 s | 461 words | no |
| #112 structured, Opus 5.5 | 10.1 s | 9.0–13.2 s | 295 words | 4 every time |
| #112 structured, Haiku 5.5 | 10.9 s | 9.3–12.7 s | 286 words | 4–5 every time |
| **#112 structured, Sonnet 5.5** | **6.6 s** | **6.2–6.8 s** | **254 words** | **4 every time** |

- **Length drives the time.** The structured reply with its word limit (#112) halves
  the time on the same model: 19.1 s to 10.1 s.
- **Sonnet 5.5 is the fastest and the most consistent** for this step. It cuts the
  wait to 6.6 s, a 65% reduction from main. Its replies were complete, specific to
  the answer, and scored all four behavioral criteria.
- **Haiku 5.5 was not faster than Opus** through the CLI for this output size. Its
  coaching was useful but longer than requested, up to 380 words.

## End to end on the server

The full server path, with the same three answers and one run each
(`--workflow`):

| Configuration | short | typical | rambling |
| --- | --- | --- | --- |
| main, prose, Opus 5.5 | 19.5 s | 22.6 s | 17.3 s |
| #112 structured, Opus 5.5 | 8.8 s | 11.9 s | 10.1 s |
| #112 structured, `coach_models` set to Sonnet 5.5 (this change) | 8.9 s | 6.5 s | 6.5 s |

The Sonnet runs overlapped an iOS build on the same machine, and the short-answer
run was the first of the series.

## Recommendation

1. Ship #112 (structured, shorter replies). It is the largest single reduction and
   needs no configuration.
2. Run the coach step on **Sonnet 5.5** while other steps keep the deployment model.
   This change adds an optional, per-provider setting in the agent config
   (`STACK_AGENT_CONFIG`, default `storage/agents/config.json`):

   ```json
   {"provider": "claude-cli", "coach_models": {"claude-cli": "claude-sonnet-5-5"}}
   ```

   The setting applies only to the coach step and only when the deployment provider
   matches the key. Without it the configuration digest is unchanged, so running
   tasks are not paused by the deploy. Restart the worker after editing the config.
3. **Target: coaching on screen within 10 s of submitting** a typed answer. That is
   about 7 s for the model, up to 3 s for worker pickup and up to 0.8 s for the poll.
   Spoken answers add transcription time, which this issue does not cover.

Streaming partial coaching would cut the perceived wait further, but every provider
path, the worker protocol and the app's polling would need to change. It is not
worth that until the target above is measured on a phone.

## Paid API options

No paid API keys were available, so the paid options below were **not measured**.
The Claude CLI rows above use the same models as the Anthropic API, but the CLI adds
its own startup and runs under subscription limits rather than per-token billing.

Estimated cost for one coaching request, at about 900 input tokens (instructions,
question and answer) and about 450 output tokens (a 250 to 300 word reply plus JSON):

| Model | Price per million tokens (input / output) | Per request | Per 1,000 requests |
| --- | --- | --- | --- |
| Claude Haiku 5.5 | $0.10 / $0.50 | $0.0003 | $0.32 |
| Claude Sonnet 5.5 | $2 / $10 | $0.006 | $6.30 |
| Claude Opus 5.5 | $4 / $20 | $0.013 | $12.60 |
| OpenAI GPT-5 mini (third-party listing) | $0.25 / $2.00 | $0.001 | $1.13 |
| OpenAI GPT-5.4 mini (third-party listing) | $0.75 / $4.50 | $0.003 | $2.70 |

- Anthropic prices are from claude.com/pricing on October 30, 2026.
- OpenAI's pricing page could not be fetched. Those figures come from third-party
  listings and must be checked before deciding.
- Stack's API path today is OpenAI's Responses API (`provider: "openai"`), configured
  with the model name, the prices and monthly limits. There is no Anthropic API
  provider yet. Using Claude models through the API would need a new provider in
  `agents/provider.jac`, about the size of the existing `meta` branch.

At these sizes, every option costs under 1.5 cents a session. Speed and coaching
quality, not price, should decide. Suggested next step: get an OpenAI key and an
Anthropic API key for one afternoon, run
`scripts/coach-latency-bench.py openai --model ...` with the same three answers,
and compare the results against the Sonnet row above.

## Reproduce

```sh
# Model call only (real requests; subscription limits or API charges apply)
./scripts/jac run --no-serve scripts/coach-latency-bench.py claude-cli --model claude-sonnet-5-5 --repeat 2
# Whole server path, disposable database
./scripts/jac run --no-serve scripts/coach-latency-bench.py claude-cli --workflow --repeat 1
```

Add `--show` to print each reply and `--json` for one JSON line per run.
