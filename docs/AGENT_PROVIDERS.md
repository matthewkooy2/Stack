# Stack model providers

Stack supports OpenAI API (`openai`), local Codex (`codex-cli`), local Claude Code
(`claude-cli`), and Meta Model API (`meta`). The Jac workflow, confirmed facts,
permissions, and external-action controls remain the authority for every provider.
Local CLIs generate structured proposals with tools disabled. They do not run the
application browser, send email, or execute practice code.

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
