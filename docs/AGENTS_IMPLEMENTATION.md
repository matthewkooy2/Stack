# Stack agents: implementation and rollout

This implementation adds durable agent workflows to the existing Jac application. It is **not a certified unattended-application release**. Paid execution and automatic submission are disabled by default. Existing saved jobs are never enrolled automatically.

Provider setup now includes personal Codex/Claude CLI subscriptions and Meta Model
API alongside OpenAI API. See [provider setup and Muse connector status](AGENT_PROVIDERS.md).
CLI subscription requests use an account-bound daily cap rather than API budgets.

## Implemented

| Area | Working code and behavior |
| --- | --- |
| Shared workflows | Account-owned facts, expiring standing rules, task queue, step leases, bounded retries, cancellation, bundled questions, explicit reconciliation, activity artifacts, operator reservations and action counters |
| Jobs | Source-backed fit reports for selected real applications; the existing deterministic matcher remains authoritative; run keys include the current job/profile/fact context |
| Resume | Local OpenResume parsing and grouped editable review; explicit confirmation; selected-resume provenance; source-preserving ordering; generated PDF with embedded font, text-recovery checks, full original/tailored text and diff; requested cover-letter PDFs use verified text |
| Applications | Greenhouse/Lever/Ashby host recognition and semantic form pipeline; required-answer collection; PDF upload; form checks; one submit attempt; confirmation evidence; same-session browser takeover with encrypted checkpoints |
| Google | Account-bound OAuth state and PKCE, encrypted refresh tokens, incremental scope requests, Gmail history synchronization and bounded recovery search, daily watch renewal, conservative message association, UTC calendar invitation extraction and idempotent event IDs |
| Network | Real contact entry and CSV import; selected-recipient outreach and bounded follow-ups; user-requested LinkedIn profile capture with sign-in handoff, recruiter-focused analysis and suggested rewrites |
| Prep | Persistent typed sessions for algorithms, debugging, review, SQL, fundamentals, system design and behavioral practice; Python/C++/SQL harnesses; separate deterministic results and model coaching; optimistic revisions across devices |
| Interfaces | Native agent inbox/rules/facts/contacts, per-application launch, native practice sessions; focused web editor, timer, hints, canvas, results, transcript review, task inbox and browser takeover |
| Operations | Invited-beta gateway, one-writer systemd units, disabled budget configuration, private sandbox service, release HTTPS enforcement, Expo push registration/delivery plumbing, account export/deletion, backup/restore utility |

`core/automation.jac` owns state transitions. Models only return structured proposals through `agents/provider.jac`; they do not call tools or expand permissions. `agents/worker.jac` performs external work through authenticated Jac endpoints. Browser and code services never access the graph directly. See [Jac migration status and verification](JAC_MIGRATION.md) for the current implementation-language boundaries.

See [LinkedIn profile review](LINKEDIN_PROFILE_REVIEW.md) for the login flow, configuration, capture limits, and validation status.

### Reliability and costs

Only an explicit request starts an agent. A right swipe only saves; `swipe` still accepts `start_agent` from older clients and ignores it. Saving or selecting a contact never starts outreach. Every `fill`, `submit`, `send`, and `calendar` step pauses in `review` until the user approves that exact payload; `agent_authorize` rejects a dispatch whose payload hash differs from the approval (see [agent experience](AGENT_EXPERIENCE.md)). Application and initial outreach runs use stable idempotency keys.

The API persists an intent before fill, submission, send, or calendar writes. A missing receipt, expired lease after dispatch, cancellation during dispatch, or ambiguous error moves the run into reconciliation. There is no blind retry of those actions. A user can attest completion or provide evidence that nothing was sent. Completed run projections are replayable; confirmed application status and contact follow-up state are recorded by the same writer.

Counters are service-owned. Counter reservations are committed while the writer is in the service context, then run state is committed in the owning account context. A crash between those commits can consume an unused reservation, but cannot release a dispatched action or overspend its cap. One writer and its process lock are mandatory. Do not scale the API above one process/replica.

The budget uses conservative reservations based on payload bytes, maximum output tokens and configured token prices. UI spend is labeled **reserved spend**. Uncertain model calls retain their reservations; there is no automatic refund for a lost response. Set a provider-side spending limit as well. Price changes require updating deployment configuration. Discovery providers retain their existing separate limits.

External content is data, not authority. Unsupported resume claims cannot enter generated PDFs: the model may reorder verified text, and suggested rewrites remain separate. Networking's automatically sent copy is assembled from verified facts; free-form model prose is retained only as a suggestion. Employer assessments are applicant tasks, separate from practice fixtures.

### Data and privacy

Facts record confirmation and source. Resume extraction does not verify facts. OAuth credentials remain encrypted server-side; workers receive only the short-lived access token. Browser storage uses a separate encryption key on its isolated host. Checkpoints omit password controls, expire after one day, and are never returned to the model.

Tailoring opens its task immediately. Missing confirmed resume details pause before reserving a model request; the task embeds resume review and explicit confirmation before continuing. Completed tasks offer a PDF preview and full text comparison. The generated PDF reorders verified entries in a single-column layout; suggested rewrites are displayed separately and are **not applied**. The uploaded original is unchanged. See [OpenResume setup and license](RESUME_PARSER.md).

The Gmail permission is mailbox-wide. Application/contact filters narrow processing, not OAuth access. Only relevant excerpts are persisted. Push messages contain no employer, email or resume contents. Export includes personal application data, agent artifacts and PDFs, but excludes connection secrets. Deletion requires the account password, disables new actions, cancels leases, erases private graph data/PDFs, attempts provider revocation/browser purge, and removes the login identity. Minimal non-content quota records remain for deployment accounting. Previously dispatched external actions cannot be recalled. Backups need a documented retention/deletion period before launch.

## Set up the hosted beta

1. Provision a private PostgreSQL database and an always-on Linux host. Install **Jac 0.37.21** using the [official versioned installer](https://www.jac-lang.org/quick-guide/install/). Put the executable at `/usr/local/bin/jac`; place this checkout at `/opt/stack`, owned by the `stack` service user. Run `scripts/jac install --no-npm`, then `scripts/jac build --as client workspace` before making the deployment directory read-only.
2. Run `python3 scripts/agent-admin.py init`. Copy `deploy/agent-config.example.json` to the private configuration path if needed. Keep its zero budgets and empty adapter certification list during initial setup. Configure the real HTTPS `web_url`.
3. Fill separate private files `/etc/stack/api.env` and `/etc/stack/worker.env` from the examples. Generate unrelated random signing, worker, browser and sandbox secrets; generate Fernet keys for account connections and browser sessions. Never reuse the browser key as the API connection key. The API does not need the model key, and the worker does not need database credentials or the connection encryption key.
4. Install the three `deploy/stack-*.service` units. Use the API unit's single process. Put Caddy in front using `deploy/Caddyfile` and your DNS name. Only HTTPS should be publicly reachable; ports 8000, 8011, 8012 and 8080 must be private/firewalled. The gateway blocks graph/admin/worker routes and checks invitation admission before forwarding personal calls. Do not expose Jac directly.
5. Run the existing discovery worker with its existing source configuration on the private API. Run `scripts/agent-admin.py invite` locally with operator credentials to create single-use, seven-day invitations. Users can redeem them during phone/web sign-in.
6. Configure a model, current input/output prices in **cents per million tokens**, shared/user monthly limits, and deployment daily limits before enabling paid/outbound work. Users still need unexpired standing permissions for each action and exact destination domain.

These files are deployment templates, not evidence of a deployed service. Provisioning, DNS, provider accounts, secrets and production database choice have not been supplied in this workspace.

### Browser and code isolation

Run the browser service on a separate hardened Linux host/container, with no database/model/Google credentials. Build `deploy/browser.Dockerfile` using the explicit file list in `scripts/browser-preview.py`; it installs Jac 0.37.21, pinned Playwright and cryptography, and matching Chromium. Its Jac entrypoint runs as a non-root user with Chromium sandboxing enabled. Configure `STACK_BROWSER_TOKEN`, `STACK_BROWSER_SESSION_KEY`, `STACK_BROWSER_STORAGE` on a persistent private volume, and only the explicitly required `STACK_BROWSER_RESOURCE_HOSTS`. Use a private authenticated tunnel/TLS between hosts. Browser traffic also needs an egress firewall blocking private/link-local addresses to supplement URL checks. Follow [Playwright's browser isolation guidance](https://playwright.dev/python/docs/docker).

Run `python3 -m agents.sandbox_service` on a **different** Linux execution host with Docker and `runsc`. Build `deploy/sandbox.Dockerfile`, publish it to your private registry, and set `STACK_SANDBOX_IMAGE` to its immutable `repository@sha256:...` digest. Set a distinct `STACK_SANDBOX_TOKEN`; expose the service only through the private tunnel configured in the worker. Never mount the Docker socket into the application or model worker. Each exercise uses a read-only, non-root, networkless disposable container with resource/output/time limits. Follow [gVisor production guidance](https://gvisor.dev/docs/user_guide/production/).

No host-process fallback executes candidate code. A missing execution service produces a resumable input state. CPU exhaustion, compiler failures, hostile code, SQL restrictions and real container isolation must be exercised on this host before beta admission.

### Google and iPhone

Create the OAuth client with the exact HTTPS `/oauth/google` redirect. The authenticated initiating account must complete the callback. Start with Gmail tracking, then request send/calendar capabilities as needed. Configure a Pub/Sub topic to renew Gmail watches; **delivery subscription consumption is still pending**, so the current worker relies on five-minute history polling and recovery. Scope testing-mode refresh-token expiry and verification requirements using [Google's guidance](https://developers.google.com/identity/protocols/oauth2#expiration).

For TestFlight, use a paid Apple Developer team, configure APNs through your Expo project, supply `STACK_EAS_PROJECT_ID` and `EXPO_ACCESS_TOKEN`, and build with `STACK_BUILD_MODE=release STACK_API_URL=https://your-host`. Release configuration sets the production push entitlement and rejects HTTP. Existing local reminders remain enabled. Push acceptance receipts are recorded; delivery-receipt polling/device-token retirement still require rollout work. Physical iPhone delivery, background behavior and microphone checks have not been performed here.

### Migration and recovery

Node changes are additive and give existing records defaults; uploaded PDFs retain their paths. Do not delete `.jac`, which contains the local database. Before cutover, stop every writer, configure libpq's `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, private `PGPASSFILE`, and run:

```sh
python3 scripts/backup-agents.py backup /private/backups/stack-before-agents --writers-stopped
python3 scripts/backup-agents.py verify /private/backups/stack-before-agents
# Point libpq at a NEW EMPTY database, and restore to a NEW storage directory:
python3 scripts/backup-agents.py restore /private/backups/stack-before-agents --writers-stopped --storage /private/restored-stack/storage
```

Encrypt the archive before off-host storage. Run account/PDF/restart checks against the restored copy before cutover. The utility rejects a nonempty database and an existing storage target. An operator restore drill against the production migration target remains a release gate.

## Verification and remaining release gates

The tailoring regression uploads a fixture PDF, pauses without consuming a request, explicitly confirms parsed details, renders a real PDF with a stubbed model response, and reloads its saved artifact. Parser tests cover ownership, stale revisions and confirmation. `STACK_TEST_TAILOR_UI=1 node tests/native.cjs` checks task navigation, confirmation failure/retry, full text comparison and the native PDF boundary against mocked RPCs. These checks do not certify model output quality or physical iPhone layout.

The automated suites cover account isolation, ownership, duplicate starts/callbacks, revisions, cancellation, unset budgets, concurrent shared-cap reservations, deletion of an account with leased work, source quotation validation, PDF generation/extraction, conservative Gmail association and calendar parsing, output caps and sandbox launch restrictions. Browser verification exercised web sign-in, practice creation, editing, save and reload. Existing discovery/matching/account/native regressions are retained.

The following are **not finished or certified**:

- Live conversational interviews and bounded live-audio metering. Browser speech recognition supports reviewed transcripts, but there is no native recorded-audio pipeline or live interviewer yet.
- Per-ATS end-to-end certification, multistep/custom-widget forms, receipt-email reconciliation, signatures and employer-specific challenge handling. The three hosts share a conservative semantic implementation; this is not proof that every form on those platforms works. Unsupported sites currently require manual application; universal prefill is not implemented.
- Full Google push consumption; non-UTC calendar parsing and event-conflict resolution; calendar prep-block generation and scheduling suggestions UI. Ambiguous emails are stored for review, but automatic association must remain conservative.
- Deep analysis of a bounded top-match set, full fit-report cache invalidation across prompt versions, broader reviewed problem banks, interview-triggered curricula, coaching calibration, selected-contact research and profile-edit workflows.
- Browser restart tests across real authentication challenges, sandbox escape/limit tests on Linux, deployed backup restore, push delivery receipts, physical-iPhone continuity, TestFlight release and operational retention policy.

Keep `certified_adapters` empty until controlled forms and designated test accounts pass the selected-job → tailored PDF → completed form → single submission → receipt journey, including crash/retry/revocation cases. Enable adapters individually. No real job application, email, paid model call or calendar event was executed while implementing this change.
