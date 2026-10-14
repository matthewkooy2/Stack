# LinkedIn review failure gates and error messages

Source baseline: PR #86 at `f81e72bb6654f0f60fd338b9cd3d064a15e60131`. This catalog follows the current path from account setup through displaying a validated `linkedin_review` artifact. It includes explicit reachable application gates, provider-specific errors, and the generic handlers for unexpected infrastructure/runtime failures. Third-party, operating-system, and framework error text can vary; those are represented by their handler and outcome rather than an invented finite list of messages.

Related docs: [scan implementation](LINKEDIN_SCAN.md), [test inventory](LINKEDIN_TESTS.md), [feature overview](LINKEDIN_PROFILE_REVIEW.md).

## How failure states differ

| Outcome | Effect on receiving a review | Recovery |
| --- | --- | --- |
| Start/API error | No new task or action succeeds. | Correct setup/input or restore account/service access. |
| `needs_input` during scan | No capture reaches the model yet. | Complete sign-in/verification in the same browser and resume. |
| `paused` browser task | Scan cannot proceed while the user controls it. | Return control to the agent. |
| `blocked` review | Returned output is not accepted as a report; any saved capture remains. | Fix the cause and choose Retry analysis at the existing review step. |
| `queued` after adapter error | Automatic retry with backoff; no accepted output yet. | Restore the service; inspect stage diagnostics. |
| `failed` after three attempts | Automatic retries stop. | Inspect the error, correct it, and explicitly retry. |
| `cancelled`/deleted | Work is stopped or its account/results removed. | Start new authorized work if appropriate. |
| Delivery/read failure | A report may already exist privately but cannot be retrieved/rendered now. | Restore authentication/connectivity and refresh the task. |

`_agent_complete` gives adapter errors a retry delay `min(300, 15 * 2^attempts)` seconds (30 seconds after the first claimed attempt). `agent_claim` refuses another claim after three attempts, setting `failed`. User-input and blocked results are not auto-retried. A browser interruption becomes `paused` or `cancelled` depending on control state. LinkedIn has no email/submission side effect, so external-action receipt gates do not normally apply.

## 1. Account access, gateway, and the setup screen

Sources: [core/automation.jac](../core/automation.jac) (`_agent_access`), [agents/gateway.jac](../agents/gateway.jac), [agents/experience.jac](../agents/experience.jac), [Swift setup](../ios/Stack/Features/Network/LinkedInSetup.swift), [Swift Network card](../ios/Stack/Features/Network/NetworkAgentSection.swift), [API client](../ios/Stack/Core/APIClient.swift), [web transport](../web/transport.js).

| Gate | Message/status | Effect and recovery |
| --- | --- | --- |
| Stack authentication missing/expired | Framework HTTP authorization response; clients surface server or transport errors. Web `errorText` can use `Request failed.` when no message is supplied. | Sign into Stack again. This is separate from LinkedIn browser login. |
| Deleted account | `This account has been deleted.` | Account access is rejected. |
| Invite-only configuration without admission | `An invitation is required for this beta.` | Accept a valid beta invitation. |
| Gateway admission rejection | HTTP 403: `Sign in and accept your beta invitation.` | Resolve Stack login/admission before feature RPCs. |
| Gateway route/body/rate checks | HTTP 404 for unsupported routes; 413 for invalid/oversized POST length; 429 after per-address/per-minute limits (normally 300 for feature calls); 503 `Stack is temporarily unavailable` for gateway exceptions. A directory listing while starting returns 503 `Stack is starting`. | Retry after startup/backoff or repair gateway/routing. These are shared service gates, not LinkedIn parsing failures. |
| Missing/expired Model permission | Setup offers `Allow model use`; readiness may say `Turn on standing permissions in Agents → Rules. They expire after 30 days.` and an Allow Model instruction. Actual authorization message is listed below. | Review Rules and enable unexpired Model permission. |
| No configured model | Setup: `A model isn’t connected yet`, with server configuration reason. Fallback: `No model provider is connected on this server.` | Switch to a configured alternative or have the operator fix setup. |
| Missing browser configuration | Setup: `The browser worker isn’t available`; readiness: `The operator must configure the isolated browser worker.` Fallback: `The browser worker is not available on this server.` | Operator configures the browser service. Presence checks do not prove reachability. |
| Setup status request fails | `Couldn’t check your setup: <underlying error>`; `Retry setup check`. | Retry status loading. Unknown readiness alone does not create a false Swift setup block; server start remains authoritative. |
| Saved profile has not loaded | `Loading your saved profile…`; on failure, `Retry loading profile`, with the underlying error. Start is disabled until loading succeeds, a URL exists, and no operation is in progress. | Reload saved profile data; avoid overwriting saved details with an unloaded form. |

Confirmed facts are optional for this feature. Missing resume facts, target role, Gmail, a LinkedIn API key, or a hosted web-workspace URL are not required LinkedIn review gates. The separate resume-based Profile suggestions feature has different requirements.

## 2. Input and start authorization

Sources: [main.jac](../main.jac) (`agent_linkedin_profile`, `agent_linkedin_start`), [agents/linkedin.jac](../agents/linkedin.jac) (`profile_url`), [agents/contracts.jac](../agents/contracts.jac) (`config`, `authorize`, `model_access`).

| Gate | Exact message | Recovery |
| --- | --- | --- |
| Invalid/missing LinkedIn profile address, including invalid decoded handle | `Enter your LinkedIn profile URL: https://www.linkedin.com/in/your-name/` | Supply HTTPS LinkedIn `/in/<handle>/`; server strips query/fragment tracking. Swift can add a missing HTTPS scheme before server validation. |
| Target role longer than 200 characters | `Keep the target role under 200 characters.` | Shorten it. The actual condition is greater than 200; 200 is allowed. |
| Disabled, expired, or absent standing Model permission | `Enable an unexpired standing permission for model.` | Enable Model with a valid expiration; checked at start and again when work is claimed. |
| Missing browser URL/token at start | `LinkedIn review needs the isolated browser worker. Configure it before starting.` | Operator sets both `STACK_BROWSER_URL` and `STACK_BROWSER_TOKEN`. |
| Invalid saved model selection | `Choose Codex CLI or Local model.` | Correct the account/config selection. |
| Unsupported configured provider | `Choose a supported model provider.` | Configure Codex CLI, Claude CLI, Ollama, LM Studio, OpenAI, or Meta as supported by the provider code. |
| CLI configured for another/no Stack account | `The operator must connect this Stack account to the local CLI subscription.` | Operator sets the correct owner ID; hyphenated/hex UUID forms are normalized. |
| Invalid CLI quota configuration | `Set a local CLI daily request limit between 1 and 100.` | Set a supported operator quota. |
| No local model name | `Choose an installed local model.` | Configure a model actually loaded/installed in the service. |
| Invalid local service origin | `Set a local model HTTP(S) origin with an explicit port on loopback or a private IP, without credentials, path, query or fragment.` | Fix the operator-owned local service URL. |
| Paid configuration missing model, positive prices, or positive monthly limits | `Paid agents are disabled. The operator must configure a model, prices, and monthly limits.` | Configure paid inference explicitly. Credentials are checked later. |

Current start checks use `config()` at the entry point; the task stores the account-selected model, which claim/dispatch check separately. A valid selected alternative does not remove the start entry point's configuration checks. Malformed operator JSON or invalid numeric values can also raise parsing/conversion exceptions before a friendly configuration error is produced; they fall under the shared runtime/API failure paths.

## 3. Worker admission, resource limits, and persistence

Sources: [core/automation.jac](../core/automation.jac) (`agent_claim`, `_agent_leased`, `agent_model_log`, `_agent_complete`), [agents/worker.jac](../agents/worker.jac), [main.jac](../main.jac) (`agent_finish`).

| Gate | Exact message or behavior | Recovery |
| --- | --- | --- |
| No running worker, unavailable API/database, invalid worker token/file | API: `Worker authorization required.` Worker loop: `Agent worker waiting for API; durable work will resume.` Missing token file can prevent worker startup. | Operator restores worker, credentials, API, and storage. A queued task alone does not mean a model request ran. |
| Waiting/paused/terminal task or still-active lease | Claim skips it or returns `idle`; no LLM request is dispatched. Lease duration is 180 seconds. | Resume/retry the correct task or wait for existing work. |
| Permissions/config no longer valid when claimed | The authorization/configuration messages above; task becomes `blocked`. | Fix the current setup and retry. |
| CLI daily quota consumed | `The local subscription daily request limit is reached.` | Wait for the next UTC day or adjust authorized operator limits. Usage is shared by provider/day; each review claim consumes a request. |
| Paid API reservation exceeds global or per-user monthly budget | `The monthly agent budget is exhausted.` | Restore authorized budget. Reservation includes the captured profile; local providers do not use API spend reservations. |
| Provider configuration changed after claim | `Model configuration changed. Resume this task to use the current provider.` (`needs_input`, no questions) | Resume under the current configuration. |
| Worker lease expired, task cancelled/deleted, or stale completion/log write | `Run lease expired or cancelled.` | Stale results cannot be committed. Restore/retry current authorized work; cancelled work is not replayed. |
| Model log write failure | `Stack could not retain the model response log. Check the API before retrying.` | Restore API/storage. Production logging must succeed before inference and before acceptance; a returned answer can still be withheld if its log cannot be saved. |
| Malformed/stale diagnostic record | `Invalid model log.`, `Invalid model attempt.`, or `Model attempt belongs to another step.` | Repair the worker record; production's recorder translates persistence rejection into the log-retention message above. |
| Unexpected adapter exception | `Adapter unavailable (<exception class>).` | Inspect the class and diagnostics; retries use backoff and eventually the three-attempt gate. Non-ValueError exception details are not shown. |
| Three failed attempts | `This step failed three times. Review the error before retrying.` | Correct the cause and use explicit retry. |
| Result finalization/database commit/API reply failure | Worker loop waits for API; result may not have become a committed artifact or its response may be lost. | Restore service and inspect saved task/lease state before assuming successful delivery. |

`generate` records attempts as `started`, `received`, `accepted`, `rejected`, or `error`. A process crash before returned output reaches Stack cannot produce a retained response. Raw rejected output is diagnostic data, not a user-approved report.

## 4. Browser startup, session, and scan

Sources: [agents/linkedin.jac](../agents/linkedin.jac), [agents/browser.jac](../agents/browser.jac), [agents/browser_service.jac](../agents/browser_service.jac), [agents/browser_control.py](../agents/browser_control.py), [agents/worker.jac](../agents/worker.jac).

| Gate | Exact message/behavior | Recovery |
| --- | --- | --- |
| Browser URL/token missing at dispatch | `Browser automation is unavailable until the browser worker is configured.` | Fix operator configuration. |
| Browser service startup token too short | Service exits: `Configure STACK_BROWSER_TOKEN (at least 32 characters).` | Set a valid service token matching the callers. |
| Private browser authentication/body/endpoint failure | Browser service returns HTTP errors (including 403/413/404); scan RPC translates failures to the sanitized browser message below. | Restore service token, request, or route. |
| Chromium/Playwright missing, launch/sandbox/container failure | Service initialization may fail without a task-specific friendly message. | Operator repairs the browser runtime/container. The preview's Docker/disk/readiness helpers can prevent startup before task execution. |
| First scan opens login | `Sign in if LinkedIn asks, confirm this is your profile, then choose “Analyze my profile”.` | Expected `needs_input` pause; sign in and resume. |
| Initial login page cannot finish opening | `LinkedIn did not finish loading. Open the browser, refresh the profile, and try again.` | Check/refresh the retained session. |
| Existing session has wrong adapter or requested URL | Internal error: `This browser session does not match the requested profile.` | Open the correct session/new task. Scan service exposes the sanitized browser error, not this raw text. |
| No nonempty `li_at` cookie | `Sign in to LinkedIn in the agent browser below, then confirm this is your profile.` | Complete LinkedIn login; public-page readability does not bypass this requirement. |
| Profile navigation lands on login/challenge/non-profile URL, or password/captcha controls remain | `Finish LinkedIn sign-in or its verification challenge in the browser, then resume.` | User handles verification in the same browser. |
| Header wait exhausts fifteen attempts | `LinkedIn has not loaded a readable profile yet. Check the browser below, open your profile, then retry analysis.` | Restore a readable profile and resume scan. Despite the wording, this is still the scan step. |
| Page changes to a different valid profile during the loop | `LinkedIn left the requested profile. Open your profile and retry analysis.` | Return to the requested profile. |
| Page URL becomes invalid/redirected during the loop | `LinkedIn redirected away from your profile. Finish any verification, then retry analysis.` | Finish verification and return to the profile. |
| Snapshot lacks nonempty Intro | `The profile header could not be read. Open your profile in the browser and resume.` | Fix unreadable page/markup and resume. Missing other sections alone does not block review. |
| Disallowed navigation/resource, private DNS/address, or WebSocket | Route abort/WebSocket close; no dedicated user message. Can lead to incomplete loading, unread sections, or the loading/browser error above. | Inspect allowed-origin/public-address policy and the actual page. Do not assume that an aborted resource means a missing profile section. |
| Scan navigation/extraction/expansion/scroll/wait/screenshot/close or RPC fails unexpectedly | `Browser operation failed. Review the session or resume the task.` | Inspect sanitized operation/stage/type/duration and retry. Even a successful extraction can fail before return if screenshot or context-close fails. |

The generic browser message deliberately replaces raw exception text, private URLs, cookies, and selectors. It carries only an allowlisted `browser_diagnostic`: operation `linkedin_scan`, stage, error class, duration, and code `browser_timeout` or `browser_operation_failed`. The worker preserves the sanitized result; completion records it even when content tracing is disabled.

Possible scan stages are `control_check`, `expire_session`, `validate_profile`, `create_session`, `configure_session`, `open_login`, `validate_session`, `check_login`, `check_profile_url`, `navigate_profile`, `verify_profile_page`, `prepare_capture`, `capture_frame`, `wait_profile_header`, `expand_profile`, `read_sections`, `scroll_profile`, `wait_section`, `build_capture`, `close_session`, and fallback `operation`. RPC failures use `rpc_transport`/`rpc_result`. Header-wait exceptions inside the retry loop are converted to the specific loading pause rather than all becoming generic errors.

## 5. Browser viewing, input authority, and resume

These gates can prevent the user from finishing login or returning control, so they can indirectly prevent the LLM stage. They do not all imply that a scan or model response failed.

Sources: [main.jac](../main.jac) (`agent_browser*`), [agents/browser_control.py](../agents/browser_control.py), [agents/browser.jac](../agents/browser.jac), [core/automation.jac](../core/automation.jac) (`agent_respond`, `agent_retry`).

| Gate | Exact messages/behavior |
| --- | --- |
| Wrong owner, missing task, wrong kind, ended browser step | `This task has no active browser.`, `This task has no browser.`, `This browser task has ended.`, `This browser step has ended.`, or `This task has no active browser session.` |
| Service session lost/expired/restarted | Frame can be `pending`; pool handoff: `Browser session unavailable. Resume the run to open it.` Stream/control errors below can also appear. Idle unwatched sessions expire after one hour; restart loses sessions. |
| Stream failure | `The browser stream is unavailable. Reconnect to try again.` |
| Input while task not paused for user control | `Take control before using the browser.` |
| Unknown control, missing controller, stale restart/generation | `Unknown browser control.`, `A viewer controller is required.`, `The browser restarted. Reconnect before taking control.`, `Browser control changed. Reconnect before continuing.` |
| Busy operation or premature resume | `Browser operation is still finishing.`, `Wait for browser activity to pause.`, `Wait for your browser input to finish before resuming.` |
| Old controller/instance or unordered input sequence | `This browser input belongs to an old control session.`, `Browser input is out of order. Reconnect before continuing.` |
| Control changed at the API completion boundary | `The browser step ended while control was changing.`, `Browser control changed while this request was finishing. Reconnect before continuing.`, or `This task is not paused for browser control.` |
| Input/control transport cannot be confirmed | `Control could not be confirmed. Reconnect before sending input.`, `Stack could not confirm browser input. Reconnect before continuing.` |
| Invalid browser input | `Unknown browser input.`, `Click is outside the browser viewport.`, or `This task does not support application resume upload.` |
| Stream grant unavailable/expired, too many viewers | `This browser viewer is unavailable.`, `Browser viewer authorization expired.`, `Close another browser viewer before opening this one.` Grants expire after ten seconds and are single-use; maximum two active viewers per task. |
| Scan authority interrupted by takeover/stop/revocation | Internal `Browser control changed.` becomes an `interrupted` result; task message is `Browser activity paused.` or `Browser task stopped.` Resume current control or start new work after cancellation. |
| Resume endpoint called on a task not awaiting input | `This run is not waiting for input.` |
| Nonempty task-answer facts supplied for LinkedIn | `Enter LinkedIn login details only in the browser handoff, never in task answers.` Fact validation can reject invalid payloads before this dedicated guard. Resume uses an empty values list. |
| Invalid explicit retry | `Run not found.` or `Only a failed or paused task can be retried.` The actual allowed statuses for `agent_retry` are `failed` and `blocked`; browser `paused` uses browser resume. |

Shared external-action intent guards can additionally return `An approved action is already being sent. Wait for its receipt before taking control.`, `Wait for the approved action's receipt before taking control.`, or `An action may have been dispatched. Reconcile it first.` They normally apply to other agent kinds, not LinkedIn's two read/review steps.

Client viewers also disable sending when disconnected, frames are stale (five seconds in the current shared viewers), authority is absent, or previous input is unconfirmed. Web messages include `Input was not confirmed. Take control again before continuing.`, `Take control again to confirm your input before resuming.`, `Control could not be confirmed. Reconnect before continuing.`, and `Paste up to 8,000 characters at a time.` Refresh/reconnect/take current control, preserve unsent text, and then resume. Legacy compiled UI fixture messages are not evidence that those controls exist in the current Swift viewer.

## 6. Model request and provider failures

Most `ValueError` failures raised inside review generation become a `blocked` task with their message. Errors raised before its inner try, or unexpected non-ValueError failures, pass through the outer worker adapter handler and retry instead.

Sources: [agents/provider.jac](../agents/provider.jac), [agents/local_cli.jac](../agents/local_cli.jac), [agents/local_model.jac](../agents/local_model.jac), [agents/security.jac](../agents/security.jac).

### Shared/API request gates

| Gate | Exact message |
| --- | --- |
| API key or model missing | `The model provider is not configured.` |
| Wrong step/provider | `Unsupported model operation.` / `Unsupported model provider.` (internal configuration/data faults, not normal user choices) |
| Forbidden provider destination or redirect | `Provider destination is not allowed.` / `Unexpected provider redirect.` |
| Provider body over 8 MiB | `Provider response exceeds the size limit.` |
| HTTP 401/403 | `Provider authorization failed. Reconnect or check configuration.` |
| Other unsuccessful HTTP response | `Provider request failed (HTTP <status>).` |
| OpenAI response not completed | `The model did not complete this step.` |
| Meta response not finished with `stop` | `Muse did not complete this step.` |

Network/DNS/TLS/timeouts or malformed provider envelopes can also raise exceptions. JSON parsing `ValueError`s outside final review validation can surface their parser message directly as blocked; missing/wrong envelope shapes may surface as `Adapter unavailable (<class>).` No complete friendly-message conversion is implemented for every possible malformed envelope.

### Codex CLI and Claude CLI

| Gate | Exact message |
| --- | --- |
| Executable not found | `Install and sign in to <provider> in the environment running Stack.` |
| Subprocess cannot start | `The local CLI could not start. Check its installation in the worker environment.` |
| Execution deadline exceeded | `The local CLI timed out. Check its login and subscription limits.` or `The local CLI timed out.` |
| Captured process output over 2,000,000 bytes | `The local CLI exceeded its output limit.` |
| Codex login is not ChatGPT subscription login | `Sign in in the worker environment with codex login before running this agent.` |
| Codex failed exit or missing result file | `Codex could not complete the request. Check ChatGPT sign-in and usage limits; no API fallback was attempted.` |
| Codex result file over 131,072 bytes | `The local CLI result exceeded its output limit.` |
| Claude auth not subscription OAuth/first-party | `Sign in to your Claude subscription in the worker environment with claude auth login.` |
| Claude failed exit | `Claude could not complete the request. Check subscription sign-in and usage limits; no API fallback was attempted.` |
| Claude error result or missing structured output | `Claude did not return a completed structured result.` |

CLI result JSON can fail before final review validation and produce a parser error. Some platform-level subprocess/selector failures become the generic adapter class. The structured LinkedIn path does not use the separate plain-coaching error `Claude could not complete the request.` Provider subscription limits can reject a call independently of Stack's daily request quota.

### Local inference (Ollama / LM Studio)

| Gate | Exact message |
| --- | --- |
| Input plus output allowance exceeds configured context | `This task exceeds the local model context limit. Increase the configured context and load the model with that context before retrying.` |
| Non-200 service response | `The local model service rejected the request. Check the selected model and local service authorization.` |
| Wrong response content type | `The local model service returned an unsupported response format.` |
| Short response body or premature connection close | `The local model response was truncated.` / `The local model connection closed before completion.` |
| Body over 262,144 bytes | `The local model response exceeded the output limit.` |
| Deadline expired | `Local inference timed out. Check model capacity before retrying.` |
| Transport/service/model unavailable | `The local model service or selected model is unavailable. Start the service and check the model before retrying.` |
| Invalid UTF-8 or invalid JSON (including duplicate keys/nonfinite numbers) | `The local model returned invalid UTF-8.` / `The local model returned invalid JSON.` Internal duplicate/number reasons are wrapped by the JSON decoder. |
| Service JSON is not an object or contains an error | `The local model service rejected the request. Check the selected model.` |
| Ollama incomplete response, or LM Studio wrong choices/finish reason | `The local model did not complete this step.` |
| Wrong message shape, tool call, or refusal | `The local model did not return a structured proposal.` |
| Empty/non-string content, content over 65,536 bytes, missing model metadata | `The local model returned no text, exceeded its output limit, or omitted required service metadata. Please retry.` |
| Unsupported schema definition/type | `Unsupported local model schema.` / `Unsupported local model schema type.` |
| Object/type/required-field/array/text/integer/enum mismatch | `Local model output does not match the schema.`, `Local model output has missing or unexpected fields.`, `Local model output does not match the array schema.`, `Local model output does not match the text schema.`, `Local model output does not match the score schema.`, `Local model output has an invalid choice.` The integer/score branch exists in the shared validator; LinkedIn's current schema contains no score field, so that branch is not normally reached for this review. |

Local inference rejects unsafe origins and oversized context before sending; it does not silently trim evidence to fit. Service timeouts are configured between five and ninety seconds. These transport/schema errors occur before the final LinkedIn-specific validation wrapper.

## 7. Returned review fails source checks

Sources: [agents/provider.jac](../agents/provider.jac), [agents/contracts.jac](../agents/contracts.jac) (`validate_evidence`), [agents/linkedin.jac](../agents/linkedin.jac) (`validate_review`).

These are the reasons the final parsing/validation block wraps:

| Failed check | Reason |
| --- | --- |
| Main evidence entry has no quote, unknown source ID, or quote absent from that source | `The generated claim has no matching source quotation.` |
| Findings is not a list or exceeds twelve entries | `Use at most twelve evidence-backed findings.` |
| Finding names an uncaptured section; quote missing/blank/non-string/not in that exact section; invalid priority; weakness, why-it-matters, or recommendation missing/blank/non-string | `A profile finding has no matching captured evidence.` |
| Rewrite type is not headline/About/Experience or rewrite text is empty | `Invalid profile rewrite.` |
| Rewrite lacks evidence or evidence source is not prefixed `linkedin:`/`fact:` | `A rewrite must cite the facts it uses.` |
| Rewrite evidence does not match its named source | `The generated claim has no matching source quotation.` |
| JSON parsing ValueError inside this block | Parser's reason text. |
| Missing fields or wrong structure producing KeyError/TypeError inside this block | `The structured response was incomplete.` |

The displayed wrapper is:

```text
The AI analysis did not pass source checks. <reason> Your captured profile is saved; retry analysis without signing in again.
```

Malformed data that raises other exception classes, such as calling `.get` on a non-object finding, can escape this wrapper and become the generic adapter error. The code does not guarantee a friendly validation message for every arbitrary model shape.

PR #86 reduces one source of rejected reviews by offering only captured finding section names in the schema and explicitly listing them in the prompt. It does not relax any source checks, relabel a bad finding, fix all provider errors, or guarantee valid output. Sections omitted by the capture budget remain unknown. A finding with a valid section but a quote from a different section still fails.

## 8. Output storage, retrieval, and presentation

Only a successfully finalized review artifact is displayed as an accepted report. Seeing a raw response record or `accepted` attempt log does not by itself prove the task-completion database write succeeded.

- `agent_run` and `agent_model_logs` require the authenticated owner. Missing/inaccessible tasks return `Run not found.` or `Task not found.` depending on endpoint. A log record is not included in routine task polling as a validated report.
- Account deletion removes task data; cancellation invalidates outstanding work. A browser session is unnecessary for a retry once `linkedin_scan` is saved, but Model permission/configuration/usage limits still apply.
- API/network/JSON-decoding failures, expired Stack sessions, app background/logout, stale session-generation checks, or renderer errors can prevent delivery even if the report was already stored. Clients surface server messages or transport descriptions; a background cancellation need not show a friendly error. Refresh the task under its owner rather than recapturing immediately.
- Swift's shared API client uses `Cannot reach Stack. Check your connection and retry.`, `Stack returned an invalid response. Please retry.`, and fallback `Request failed. Please try again.` A Stack login response without a token yields `Sign-in did not return a session. Please try again.` The web transport rejects changed sessions with `Session changed.` These also apply to reading an already completed review.
- Swift and web report rendering use the existing findings/rewrites/limitations/unread-section fields. No UI schema change is introduced by #86. This document inventories source paths and explicit messages, not verified live phone/LinkedIn behavior.

For redesign work, distinguish capture failure, model failure, evidence rejection, persistence failure, and display failure. They require different recovery and should not all send the user through LinkedIn sign-in again.

## Local preview startup gates

These operator-facing failures occur before a working scan service exists. Sources: [scripts/browser-preview.py](../scripts/browser-preview.py), [scripts/develop.py](../scripts/develop.py).

| Gate | Exact message |
| --- | --- |
| Docker executable absent | `Install Docker Desktop for the isolated LinkedIn browser preview.` |
| Docker daemon unavailable | `Start Docker Desktop, then switch worktrees again. The current preview is unchanged.` |
| First browser-image installation lacks free disk | `Free at least 2 GB before installing the Chromium preview. The current preview is unchanged.` Cached images do not require this download-space check. |
| Preview browser token absent/short | `The preview supervisor must provide a browser token.` |
| Browser container exits unsuccessfully | `The isolated browser stopped. Inspect .jac/logs/browser.log.` |
| Wrong preview helper arguments | `Use prepare or run.` |
| Service process dies before readiness | `A preview service failed to start. Inspect .jac/logs/browser.log or workspace.log.` |
| Service readiness timeout | `A preview service did not become ready. Inspect .jac/logs.` |
| Development server stops after launch | `A development server stopped. Inspect .jac/logs.` |

Docker build/download/launch subprocess errors and operating-system failures can additionally terminate setup with their exception text. These are deployment failures, not evidence that the LinkedIn profile lacks content.
