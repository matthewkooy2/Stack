# LinkedIn profile review

Start in **Network → Strengthen your LinkedIn profile** on the phone or **Network**
in the web workspace. Enter your own `https://www.linkedin.com/in/.../` URL and,
optionally, a target role. An omitted role uses your Stack profile's role.
The URL is saved on your authenticated Stack account when you save it or start a
review, and is filled in on later visits. Existing users can reuse the URL from
their latest LinkedIn task. You can edit it in Network; it is never shared between
accounts.

The task opens LinkedIn's sign-in page in a temporary remote browser and pauses.
On the phone, the task embeds that exact browser; no external workspace link is
needed. Tap a field in the browser image, type in **Private browser input**, and
choose **Type in browser**. The **Enter** button submits the selected page control.
Complete sign-in and verification yourself, then choose **I’m signed in · Analyze
my profile**. **Open my profile** returns to the requested profile, and **Open
LinkedIn sign-in** returns to login. Full screen gives a larger view.

If the browser service restarts or the session expires, the task shows **Open
browser again**. This opens a fresh sign-in session for the same task. Connection
errors replace the loading message and can be retried with **Refresh browser**.

The same session is used for capture. Frames refresh while the agent reads, with
controls disabled until it needs your input. Login input is cleared after sending,
when the app backgrounds, and when control returns to the agent. Frames are kept
only in memory and removed when the session closes, expires, or is purged. The web
workspace's existing same-session browser handoff remains available.

The review includes strengths, prioritized weaknesses with exact profile quotations,
why each matters to recruiters, concrete fixes, suggested headline/About/experience
rewrites, and questions for missing evidence. You copy and apply edits yourself.
The existing resume-based Profile suggestions and contact outreach remain available.

## Implementation

- `agent_linkedin_start` validates an explicit profile URL, model access and browser
  configuration. Repeated requests reuse an active task for the same URL and role;
  a new review after completion captures fresh content.
- `linkedin` tasks have two steps: `linkedin_scan` and `linkedin_review`. They use
  the existing private runs, claims, status/notification flow, model permissions,
  request quotas or API budgets, and owner-checked browser handoff.
- `agents/linkedin.py` captures only visible profile cards inside `main`, in a
  bounded scroll/expand pass. Capture waits for a rendered profile header, supports
  both h1/section and h2/card layouts, and publishes progress during sixteen scroll passes. It reads intro, About, experience, education, skills,
  projects, certifications, Featured and recommendations when present. Captures
  are bounded to 24,000 characters overall and 6,000 per section.
- Only HTTPS LinkedIn destinations and LinkedIn/CDN resources are allowed.
  Existing public-address checks apply; outside navigation and WebSockets are
  blocked. There is no automated login, challenge bypass, bulk scanning, messaging,
  connection request, profile edit, or file upload in this workflow.
- LinkedIn contexts have no saved storage state. Browser cookies and login input
  values are not checkpointed, stored in facts, or included in model input. The
  context closes after successful capture or cancellation, and expires after one
  idle hour. If the browser service is unreachable during cancellation, idle expiry
  is the fallback. A worker restart requires signing in again.
- The snapshot and report persist in the user's private run and are included in
  the existing account export/deletion paths. Only captured profile text and the
  user's task context/facts are sent to the configured model. Page content is
  untrusted evidence. Profile weaknesses must quote a captured section; rewrites
  must provide source quotations. The API reserves budget including the snapshot.

## Deployment and limits

For the local phone preview, `./dev network-agent` now prepares the browser image
and web bundle before stopping the current preview. The launcher starts the installed
Docker Desktop when needed and requires at least 2 GB free for a first build. The image installs only the pinned
Playwright Chromium headless browser. `scripts/develop.py`
starts a private browser container on loopback port 8011 and the sign-in workspace
on local-network port 8080, then checks browser readiness before starting the API.
The workspace URL is regenerated after account refresh, retaining the copied CLI
owner and limits. The web gateway permits the LinkedIn start and feature endpoints.
The local HTTP workspace is for the same development network as the phone preview;
production still uses the HTTPS deployment below.

Only the source files explicitly listed in `scripts/browser-preview.py` enter the
browser image. It receives no checkout mount, database, Mac home directory, model
credentials, or CLI login. It runs as the image's non-root user with Chromium's
sandbox enabled, a read-only filesystem, and ephemeral temporary storage. Stopping
the preview stops its browser container and discards browser sessions.
`deploy/browser-seccomp.json` is the unmodified
[Playwright v1.58.0 profile](https://github.com/microsoft/playwright/blob/v1.58.0/utils/docker/seccomp_profile.json),
used according to [Playwright's container guidance](https://playwright.dev/python/docs/docker).
The real container has passed authenticated health checks on this Mac with Chromium
sandboxing enabled; unauthenticated browser requests are rejected. Unit tests cover
startup configuration, low-disk gating, and gateway routes. Real LinkedIn sign-in
and profile analysis still require the user's acceptance run.

Use the existing isolated Playwright browser service, `STACK_BROWSER_URL`,
`STACK_BROWSER_TOKEN`, and an enabled model provider/permission. A hosted `web_url`
is optional for this phone workflow.
No LinkedIn API key is used. The browser service must be reachable from the worker
and API; users sign in through the authenticated Stack app or web workspace.
Locally the browser container runs inside Docker Desktop’s Linux VM; the API and
model orchestration run on the Mac. This is not yet an always-on cloud deployment.
Playwright operations share one worker thread; a thread-safe, owner/run-scoped
frame cache allows viewing during capture without concurrent browser mutations.

This is a bounded text review, not a completeness or recruiter-ranking score.
Unread sections are shown as unknown rather than assumed absent. It does not assess
photos, banners, private recruiter settings, or search visibility. LinkedIn can
change page structure or block the browser; login/challenge/unreadable pages pause
for user input rather than produce a fabricated assessment. Additional subpages
and non-English expansion controls are not crawled.

Automated checks use controlled profile/browser/model fixtures. A real LinkedIn
sign-in and live model analysis still require an acceptance run with the user's
account on the deployed browser service.

## Automated verification

- Python LinkedIn tests: destination validation, bounded capture, login/challenge
  pauses, account isolation, temporary session lifecycle, upload rejection, evidence
  checks and worker routing.
- 45 existing Python agent/provider/experience checks.
- 4 Jac workflow tests covering LinkedIn ownership, sign-in/resume, fresh reviews,
  cancellation, existing outbound approvals, resume review and provider workflows.
- Compiled mobile and web component tests: URL/role submission, setup failures,
  browser handoff, masked login input, resume, readable findings and copyable rewrites.
  The existing tailoring screen test also passes.
- Jac type checks and the production web bundle build pass.

Run the focused UI checks after compiling mobile and building the workspace client:

```sh
STACK_TEST_LINKEDIN_UI=1 node tests/native.cjs
STACK_TEST_LINKEDIN_WEB=1 node tests/native.cjs
```

The API statically imports the browser transport so it remains available inside
Jac’s prepared application namespace. Browser workflow tests exercise that real
transport and mock only the HTTP boundary; cold-import and phone recovery checks
cover unavailable and expired sessions.

Analysis failures (including source-quotation validation failures) pause as blocked,
with a Retry analysis action. The captured profile is retained and the retry resumes
step two without opening a browser or asking for another sign-in. Older tasks saved
as needs_input with no questions now show Analysis paused and the same recovery.
The model schema constrains finding section IDs and rewrite types; source checks
still reject unsupported claims. Failed model output is not presented as a report.
