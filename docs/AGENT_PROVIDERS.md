# Stack model providers

Stack supports OpenAI API (`openai`), local Codex (`codex-cli`), local Claude Code
(`claude-cli`), and Meta Model API (`meta`). The Jac workflow, confirmed facts,
permissions, and external-action controls remain the authority for every provider.
Local CLIs generate structured proposals with tools disabled. They do not run the
application browser, send email, or execute practice code.

## Personal subscription on your Mac

1. Sign in through `codex login` (ChatGPT) or `claude auth login` (Claude plan).
   Stack uses the CLI's own authentication, not copied OAuth tokens. Recent CLI
   versions are required for the isolation and structured-output flags.
2. In Stack, open **Agent activity > Rules** and note your **Account ID**.
3. Select one local provider from the project directory:

   ```sh
   python3 scripts/agent-admin.py provider --provider codex-cli --owner YOUR_ACCOUNT_ID --daily-limit 10
   # Or:
   python3 scripts/agent-admin.py provider --provider claude-cli --owner YOUR_ACCOUNT_ID --daily-limit 10
   ```

   Omit `--model` to use the CLI's default; add it to choose an available model.
   This binds the Mac's subscription to that one Stack account. Other Stack
   accounts cannot consume it. This is a personal local development feature,
   not pooled subscription access for a hosted service.
4. Enable standing permissions with **Model** selected. Save them. Keep the Mac
   awake and connected to the iPhone hotspot while `scripts/dev` runs.
5. For the smallest test, open **Prep**, start a behavioral practice session,
   enter an answer, and tap **Get coaching**. Refresh Agent activity to see the
   result. This requires neither Google nor a code sandbox. For a job-fit test,
   select a saved, real application and its resume, confirm extracted resume
   facts, then tap **Explain my fit**.

No API budget or API key is required for CLI providers. The daily request limit
is reserved before each attempt and is not refunded after an uncertain result.
Provider subscription limits still apply. CLI failures pause for input; there is
no automatic paid API fallback. Requests time out before the worker lease expires.
Existing API spend remains visible separately from subscription request counts.
Changing provider configuration while a task is claimed pauses that task for retry.

Provider setup is checked separately from authentication: the activity panel's
configured state does not prove that CLI login, provider capacity, or a live
model request will succeed. Run a real task to establish that.

## Verification status (September 28, 2026)

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

## API providers

Use `--provider openai --model MODEL_ID` or `--provider meta --model MODEL_ID`.
Configure positive monthly and per-user budgets and input/output prices in cents
per million tokens in `storage/agents/config.json`. Supply `OPENAI_API_KEY` for
OpenAI or `MODEL_API_KEY` for Meta to the worker environment and restart development
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
