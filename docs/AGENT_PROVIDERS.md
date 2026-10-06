# Stack model providers

Stack supports OpenAI API (`openai`), local Codex (`codex-cli`), local Claude Code
(`claude-cli`), Meta Model API (`meta`), Ollama (`ollama`), and LM Studio
(`lmstudio`). The Jac workflow, confirmed facts,
permissions, and external-action controls remain the authority for every provider.
Local CLIs generate structured proposals with tools disabled. They do not run the
application browser, send email, or execute practice code.

## Installed local models

The general worker can use installed local instruction models for job fit,
resume tailoring, networking drafts, profile suggestions, LinkedIn analysis,
and practice coaching. The same structured schemas, source checks, response
logs, standing Model permission, and workflow approval gates apply.

Start your installed Ollama service or LM Studio local server, then select it
from the Stack project directory. These operator commands change only the
private deployment-wide provider configuration. Restart the worker after changing
the provider; the public contributor launcher also accepts these local providers:

```sh
./scripts/jac run --no-serve scripts/agent-admin.jac provider --provider ollama --model qwen3:4b-instruct
# Or, with a model already loaded in LM Studio:
./scripts/jac run --no-serve scripts/agent-admin.jac provider --provider lmstudio --model YOUR_LOADED_MODEL_ID
```

Defaults are `http://127.0.0.1:11434` for Ollama and
`http://127.0.0.1:1234` for LM Studio. Set `--local-model-url
http://PRIVATE_IP:PORT` when the service runs on another trusted machine.
The origin is interpreted from the worker's network namespace: WSL, containers,
and a hosted worker cannot assume their loopback reaches the PC. Use a reachable
private address and your existing network controls in that case. Origins require
an explicit port and accept only loopback or private IP literals (plus
`localhost`), with HTTP or HTTPS and no credentials, paths, query or fragment.
Proxy environment variables and redirects are disabled for this transport.
If your local service requires authorization, set `STACK_LOCAL_MODEL_API_KEY`
in the worker environment; paid-provider keys are never forwarded. The public
contributor launcher removes inherited provider credentials, so authenticated
local services require the separate operator worker workflow.

No API key, monthly budget, subscription owner binding, or subscription request
cap is required. Each attempt records zero API cents and zero subscription calls.
Accounts still need admission and unexpired Model permission. Local compute,
model capacity and the existing worker lease/attempt limits remain finite.
Configuration readiness does not prove the service is running or the model fits.

Choose an instruction model that supports JSON schema output. Stack sends the
existing workflow schema through Ollama `/api/chat` (`format`) or LM Studio
`/v1/chat/completions` (`response_format`) with streaming and tools disabled.
It checks the resulting schema locally before the usual exact-source checks.
Invalid, incomplete, oversized or unavailable results pause the workflow for
retry, with no paid fallback; LinkedIn analysis retains its existing blocked state
and saved capture. Changing configuration after claim also pauses the task.

Private configuration includes `local_model_timeout` (5�90 seconds, default 90)
and `local_model_context_tokens` (1024�32768, default 8192).
`max_output_tokens` applies to local requests too. Load LM Studio's model with at
least the configured context; Ollama receives it as `num_ctx`. Stack conservatively
counts UTF-8 input bytes plus output tokens and chat overhead against that window
and refuses oversized tasks instead of truncating source evidence. For larger
resumes/listings, increase the loaded and configured context or lower the output
limit. Bodies are capped at 256 KiB and generated proposals at 64 KiB.

The existing provider selector chooses one provider for the whole deployment.
These local transports do not download models, change the service bind address,
or start a model runtime. Live Realtime voice, audio transcription, code sandbox,
and browser automation keep their separate existing integrations.

Offline acceptance tests use actual loopback HTTP servers and disposable account
stores, without model downloads or paid calls:

```sh
./scripts/jac run --no-serve tests/test_local_models.py
```

An opt-in smoke check makes two real coaching requests and reloads the saved
feedback. It uses synthetic answers and disposable accounts, ignores paid budgets,
and deliberately sets the subscription cap to one to verify local requests do not
consume it. It does not change deployment configuration:

```sh
./scripts/jac run --no-serve scripts/local-model-smoke.py lmstudio --model YOUR_LOADED_MODEL_ID
./scripts/jac run --no-serve scripts/local-model-smoke.py ollama --model qwen3:4b-instruct
# Add --url http://PRIVATE_IP:PORT or --context-tokens 16384 as needed.
```

### Local runtime verification (October 6, 2026)

Qwen3 4B Instruct Q4_K_M completed two real coaching workflows through LM Studio:
account/session creation, permission and claim, general worker dispatch, strict
schema and exact-source validation, completion, saved response logs/traces, and
feedback retrieval after reload. Each recorded zero API cents and zero subscription
calls despite a configured CLI daily cap of one. Final-candidate inference took 6.75 and 6.32
seconds; these are two synthetic examples, not a latency or coaching-quality guarantee.

The tested GGUF SHA-256 is
`85e4a5b7b8ef0e48af0e8658f5aaab9c2324c76c1641493f4d1e25fce54b18b9`.
LM Studio used an 8192-token context, one inference lane, full GPU offload, and
1536 maximum output tokens on an RTX 2070 SUPER (8 GiB, driver 581.80).
The Stack worker ran under Jac 0.37.21 in WSL. A temporary loopback test relay
connected it to the Windows model service; normal deployments require a directly
reachable configured origin. Worker RPCs used the in-process API client with a
scratch PostgreSQL database. The daemon's HTTP RPC loop and physical iPhone
journey were not exercised by this check.

The installed Ollama 0.35.0 Qwen model initially loaded on CPU (reported VRAM zero)
and reached the bounded inference timeout on cold and warm attempts. Stack returned a recoverable pause
without paid fallback. That result does not establish successful live Ollama coaching;
its real HTTP format and failure behavior are covered by the automated local server
fixtures. No production configuration was changed, and no model was downloaded.

Protocol references: [Ollama chat API](https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion)
and [LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output).

## Your local subscription on Linux, WSL2, or Mac

For Linux and Windows/WSL2, prepare the public checkout using
[local contributor development](LOCAL_DEVELOPMENT.md). Install the selected CLI
and run its authentication in the **same environment as the worker**. Windows
credentials are not automatically available inside WSL2. On Mac, use the separate
`./scripts/setup --ios` / `./scripts/dev` path when developing the native app.

1. Create your own local Stack account. In the browser, **Account** shows its
   **Account ID**; in the iPhone app, use **Agents > Rules**.
2. Authenticate the chosen CLI and explicitly bind that one account:

   ```sh
   make login PROVIDER=codex OWNER=YOUR_ACCOUNT_ID DAILY_LIMIT=10
   # Or:
   make login PROVIDER=claude OWNER=YOUR_ACCOUNT_ID DAILY_LIMIT=10
   ```

   Python equivalents are `python3 scripts/contributor.py login --provider codex
   --owner YOUR_ACCOUNT_ID --daily-limit 10` or `--provider claude`. The command
   invokes `codex login` or `claude auth login`; credentials stay in the CLI's
   private home files. Restart the development launcher after changing the provider.
   Never copy `~/.codex`, `~/.claude`, their tokens, or their
   auth output into source files. The owner binding is saved in ignored private
   local configuration. A local subscription is not pooled service access.

   For an already authenticated Mac CLI, the existing operator commands remain:

   ```sh
   python3 scripts/agent-admin.py provider --provider codex-cli --owner YOUR_ACCOUNT_ID --daily-limit 10
   # Or use --provider claude-cli.
   ```

   Omit `--model` to use the CLI's default; add it to the operator command to choose
   an available model. `make doctor` checks installed CLI versions/required flags
   without printing credentials or making a model request. For the configured CLI,
   it also checks subscription authentication status; it cannot certify capacity.
3. Explicitly enable **Model** under browser **Account** (up to 24 hours), or save
   standing permissions with **Model** selected in the iPhone's **Agents > Rules**.
   Browser permission changes preserve other actions and their existing active
   expiry; disabled, expired, or longer-lived mixed permissions must be managed
   in the iPhone app first. Login does not grant standing permissions.
4. Keep the development launcher running. Start a behavioral practice session,
   enter a synthetic answer, save it, and choose **Get coaching** (browser) or
   **Save and get coaching** (iPhone). This authorizes a real subscription request.
   Inspect **Activity**, retrieve the result, and reload the session to verify
   persistence. It requires neither Google nor a code sandbox. For a job-fit test,
   select a saved, real application and its resume, confirm extracted resume
   facts, then tap **Explain my fit**.

No API budget or API key is required for CLI providers. The daily request limit
is reserved before each attempt and is not refunded after an uncertain result.
Provider subscription limits still apply. CLI failures pause for input; there is
no automatic paid API fallback. Requests time out before the worker lease expires.
Existing API spend remains visible separately from subscription request counts.
Changing provider configuration while a task is claimed pauses that task for retry.
Stack currently selects one provider deployment-wide at a time; there is no
per-agent provider selector or automatic multi-provider fallback.

Provider setup is checked separately from authentication: the activity panel's
configured state does not prove that CLI login, provider capacity, or a live
model request will succeed. Run a real task to establish that.

## Historical Mac verification (September 28, 2026)

This historical evidence does not establish clean Linux/WSL2 onboarding or current
live provider acceptance. Record those checks separately in the implementation
issue/PR, including unavailable credentials and platforms as gaps.

- After the Jac migration, both Codex and Claude completed a real practice-coaching
  workflow using synthetic answers and isolated account stores: session creation,
  permission and quota checks, task claim, actual worker dispatch and model call,
  source validation, completion, and feedback retrieval after application reload.
  Each consumed one subscription request and zero API cents. This exercised the
  backend through an in-process API client, not the physical iPhone or HTTP worker loop.
- Repeat explicitly with `./scripts/jac run --no-serve scripts/provider-smoke.jac codex-cli`
  or replace the last argument with `claude-cli`. Each run makes one real model
  request against the signed-in subscription; it does not alter the user's account
  or deployment provider configuration. Do not include this smoke check in ordinary CI.
- Fixed the missing Meta HTTP allowlist entry. Two offline transport tests cover
  the real provider-to-HTTP path and rejection of insecure/lookalike destinations;
  this is not verification of live Muse inference.
- Codex and Claude: each returned a real structured fit report through Stack's
  adapter using its existing subscription login. Exact-source validation passed;
  no API key or API fallback was used. These were synthetic inputs, not user data.
- 34 Python unit tests passed, covering provider contracts, isolation flags,
  authentication gates, source checks, timeout/output bounds, and worker pauses.
- An isolated Jac workflow test passed account ownership, durable daily caps,
  completion, and separation from API spend using a controlled worker result.
- Native screen regression tests passed; changed Jac modules passed `jac check`
  with existing lint warnings.
- The full iPhone-to-worker-to-model journey remains unverified. User account
  binding and Model permission are still required before trying it on the phone.
- Meta live inference and the Muse connector are unverified. No connector has
  been implemented or submitted. Automatic application submission stays disabled.

## Testing traces and Agent Feedback

New worker attempts save account-owned execution traces: stage inputs, model
requests/responses, validation, duration, and returned results/errors. Full content
requires `"capture_agent_content": true` in `storage/agents/config.json` (off by
default). The provider and requested model
are recorded; an unspecified model is labeled `provider default`, not guessed.
Resolved model metadata is included when the provider reports it.

Use **Agent Feedback** under a new Prep coaching result or an output in **Agent
activity**. Choose Good / Mixed / Bad and enter a note. Feedback is saved with the
reviewed output version and a bounded snapshot, independently of later retries.
It is evaluation data, not automatic training or a change to agent behavior.

The web workspace's selected task has **Download execution trace**. Account export
also includes traces and feedback; account deletion removes them. They remain
local in the account database, without a retention timer or additional encryption.
Treat that database and exports as sensitive: prompts can contain resume details.
Known credentials and binary files are filtered; this is not a guarantee against
all secrets appearing in free text. Each trace/snapshot is capped at 256 KiB and
marked when truncated. No third-party telemetry is added.

This captures Stack's worker/model stages, not hidden model reasoning or every
internal CLI tool event. Live voice has its existing transcript/receipt storage,
not this full prompt trace. Old runs cannot be reconstructed retroactively.

## API providers

The public contributor launcher excludes inherited API/deployment credentials
and disables `.env` loading. Use the advanced worker/deployment workflow in
[remote hosting](REMOTE_HOSTING.md) in a separate installation for API-provider
configuration; exporting keys before `make dev` does not enable them.

Use `--provider openai --model MODEL_ID` or `--provider meta --model MODEL_ID`.
Configure positive monthly and per-user budgets and input/output prices in cents
per million tokens in `storage/agents/config.json`. Supply `OPENAI_API_KEY` for
OpenAI or `MODEL_API_KEY` for Meta to that worker environment and restart its
services. API keys and prices are not interchangeable with subscription login.

Meta uses its documented JSON-schema Chat Completions API at
`https://api.meta.ai/v1/chat/completions`. Its adapter has offline contract coverage;
an account, key, and live end-to-end check are required before treating it as verified.

## Muse connector application brief

Using Muse Spark inside Stack and making Stack accessible from Muse are separate
integrations. The latter is not implemented or published yet.

Proposed directory description: **Stack helps job seekers organize opportunities,
track applications, maintain confirmed resume facts, and practice interviews.
Connect Stack to Muse to retrieve your saved opportunities, inspect application
progress, and continue a saved interview-practice session.**

Initial proposed connector scope: account-owned saved jobs, application status,
and practice sessions. Add writes only as explicit authenticated actions with the
existing Stack checks. Automatic applications and outreach remain outside this
initial connector scope.

Before submission: provide a hosted HTTPS service, per-user connector authorization
and revocation, privacy/support URLs, and a test account with an end-to-end demo.
Follow the actual connector protocol and review requirements supplied by Meta;
do not assume generic model API access also grants a connector listing.

Meta's public page offers **Submit a connector**, followed by functional, security,
legal, and end-to-end review. No application has been submitted on your behalf.

## Official references (checked September 28, 2026)

- [Codex authentication](https://developers.openai.com/codex/auth)
- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [Claude subscription support for Agent SDK and claude -p](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan): the page's June 15 update pauses the previously announced billing change; do not use the superseded material below it as current policy.
- [Claude non-interactive mode](https://code.claude.com/docs/en/headless)
- [Meta Model API](https://dev.meta.ai/docs/overview)
- [Meta structured output](https://dev.meta.ai/docs/structured-output)
- [Muse Connector Platform](https://muse.ai/platform)
