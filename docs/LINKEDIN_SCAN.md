# How Stack scans and parses a LinkedIn profile

Source baseline: PR #86 at `f81e72bb6654f0f60fd338b9cd3d064a15e60131`. This describes current code, including the captured-section review fix, not a proposed redesign. See [test inventory](LINKEDIN_TESTS.md), [failure gates and messages](LINKEDIN_FAILURE_GATES.md), and the [user-facing overview](LINKEDIN_PROFILE_REVIEW.md).

## What "parsing" means here

Stack runs JavaScript inside a Playwright browser to find profile cards and collect their visible text. It returns a dictionary of section names to text strings. It does not parse every job into employer/title/date records, use the LinkedIn API, inspect photos, or ask an LLM to identify DOM sections. The later LLM step interprets these text strings to produce feedback.

| File | Responsibility |
| --- | --- |
| [main.jac](../main.jac), `agent_linkedin_profile`, `agent_linkedin_start` | Account-specific URL/role storage, input validation, setup checks, existing-task reuse, and starting a review. |
| [core/automation.jac](../core/automation.jac) | Private durable tasks, claiming, permissions/quotas/budgets, completion, cancellation, retry, response logs, and lease/ownership checks. |
| [agents/worker.jac](../agents/worker.jac), `dispatch`, `browser_call` | Sends the scan to the private browser service and the saved capture to the model. |
| [agents/browser_service.jac](../agents/browser_service.jac), `BrowserHost` | Serializes Playwright operations on one executor thread, controls authority/interruption, and returns sanitized diagnostics. |
| [agents/browser.jac](../agents/browser.jac), `BrowserPool`, `BrowserFrames` | Browser contexts keyed by owner/run, in-memory frames, handoff, session expiry, and close/purge. |
| [agents/linkedin.jac](../agents/linkedin.jac) | URL/network boundaries, DOM extraction/expansion scripts, scan loop, bounded snapshot, capture-specific schema, and finding validation. |
| [agents/provider.jac](../agents/provider.jac) | Builds the later review request and validates its result. |

## 1. Save the profile and create a task

The authenticated user supplies their own profile URL and optional target role. Server validation permits HTTPS `linkedin.com` or `www.linkedin.com`, no embedded credentials, default HTTPS port or 443, and one `/in/<handle>/` path. It validates the decoded handle, removes query/fragment tracking, and canonicalizes to `https://www.linkedin.com/in/<handle>/`.

`agent_linkedin_start` falls back to the account's saved URL. Role fallback is supplied role, saved LinkedIn role, then Stack profile role; the resolved role must not exceed 200 characters. The entry point checks account access, standing Model permission, operator model configuration via `config()`, and browser URL/token presence. The queued task retains the account's selected model, and claim/dispatch recheck its selected configuration. These are distinct checks in the current implementation.

An active non-completed/non-cancelled/non-failed LinkedIn task with the same URL and role is reused. A completed task does not satisfy that reuse rule: a new review starts a fresh capture. The workflow has exactly two steps, `linkedin_scan` and `linkedin_review`; a durable ticket lets the worker claim work under a lease. Confirmed candidate facts can help later rewrites but are not required for scanning.

## 2. Open login and wait for the user

On the first `scan(pool, owner, run, context)` call, the key `(owner, run)` has no session. Stack creates a context with a 430×780 viewport, downloads disabled, service workers blocked, no restored storage state, and 2-second default action/5-second navigation timeouts.

Requests are intercepted. Navigation permits HTTPS LinkedIn hosts/subdomains only. Non-navigation resources may additionally come from `licdn.com` and its subdomains. Embedded credentials and non-443 ports are rejected. The shared public-address check rejects private destinations; route exceptions abort the request. WebSockets are closed when the installed browser API supports that hook.

Stack opens `https://www.linkedin.com/login`, publishes a browser frame when opening succeeds, and returns `needs_input` with a browser request. Even an already readable public page does not bypass this first pause. The user signs in and handles verification inside the same temporary browser, then resumes the task. Login navigation failure returns a help message while retaining the session. Passwords and codes are not task-answer facts.

## 3. Verify the resumed session

The resumed session must still be a LinkedIn session for the requested canonical URL. Stack checks for a nonempty `li_at` cookie in that context. If absent, it requests sign-in again; it does not verify ownership of the LinkedIn account independently.

If the current page is not the requested profile, Stack navigates to it with `domcontentloaded` and a 5-second timeout. It then checks the resulting URL and rejects password inputs or captcha iframes as signs that sign-in/verification is unfinished. Before each extraction pass it verifies the requested profile URL again. Redirects and session mismatches produce pauses/errors rather than a fabricated profile.

Browser control guards run between operations. Taking control, stopping, account revocation, or a stale browser generation can interrupt the scan. Viewing frames does not authorize mutation. The [failure doc](LINKEDIN_FAILURE_GATES.md) explains the resulting task states.

## 4. Wait for a rendered profile header

Stack scrolls to the top and publishes a frame. It makes up to fifteen attempts to wait for `CAPTURE_JS` to return a nonempty Intro, each with a 1-second timeout. This is up to about fifteen seconds of waiting plus execution overhead, not a hard end-to-end limit. Exhaustion pauses with guidance to check the profile and retry.

## 5. Find section cards and extract text

`CAPTURE_JS` searches only the first `main` or `[role="main"]` container. Without it, extraction returns an empty dictionary.

It considers headings with nonzero layout width/height: `h1`, `h2`, and `[role="heading"]`. For Intro, it prefers `h1`/`aria-level="1"`, otherwise the first heading, and excludes a heading that exactly matches a known section label. The containing card is the closest `section`, `.artdeco-card`, or `[data-view-name="profile-top-card"]`; where absent it uses the code's parent/grandparent fallback. It will not use the entire main container as a card.

| Output key | Section marker ID | Exact English heading fallback |
| --- | --- | --- |
| `intro` | Top heading/card rule above | Profile heading, not a named section heading |
| `about` | `about` | About |
| `experience` | `experience` | Experience |
| `education` | `education` | Education |
| `skills` | `skills` | Skills |
| `projects` | `projects` | Projects |
| `certifications` | `licenses_and_certifications` | Licenses & certifications |
| `featured` | `featured` | Featured |
| `recommendations` | `recommendations` | Recommendations |

For each card a `TreeWalker` collects text nodes. It skips text inside inputs, textareas, selects, scripts, styles, navigation, asides, dialogs, messaging overlays, and `aria-hidden="true"` ancestors. It also skips parents with computed `visibility:hidden` or no client rectangles. Text is joined with spaces, repeated whitespace collapsed, edges trimmed, and the string truncated to 6,000 characters. Headings and visible control labels can remain in the card text.

"Visible" here is based on these layout/style tests, not a requirement that every node intersect the current viewport or a screenshot-based vision check. The extractor is tied to DOM structure and exact English labels. It does not follow section detail pages or translate labels.

## 6. Expand and scroll in a bounded pass

Stack performs exactly sixteen passes. Each pass:

1. Updates progress to `Reading profile · N of 16` and confirms the requested profile URL.
2. Runs `EXPAND_JS`. Inside recognized section/card containers, it clicks at most three visible-height buttons per invocation whose trimmed label matches `see more` (optionally preceded by an ellipsis) or `show more`, case-insensitively. This is not arbitrary clicking or navigating "Show all" subpages.
3. Runs `CAPTURE_JS` and keeps the longest text observed for each section. Equal-length later text does not replace earlier text; text fragments are not merged.
4. Scrolls down 650 pixels.
5. Waits three times for 250 milliseconds, checking control authority between waits, then publishes another frame.

The explicit waits sum to twelve seconds across sixteen passes, plus header waiting, browser operations, screenshots, and navigation. The private scan RPC defaults to a 100-second timeout. No completeness guarantee follows from sixteen passes: long profiles, lazy-loaded cards, localization, changed markup, or blocked resources can leave sections unread.

## 7. Build the saved snapshot

`snapshot(url, sections)` processes known keys in the table order. Each nonempty string is stripped and limited to the smaller of 6,000 characters or the remaining 24,000-character total allowance. Extra keys are ignored. Earlier sections consume the allowance first; later ones can be truncated or omitted because the allowance is exhausted. A nonempty Intro is mandatory.

The artifact contains:

```json
{
  "url": "https://www.linkedin.com/in/candidate/",
  "captured_at": 1234567890.0,
  "sections": {
    "intro": "Candidate Software engineer",
    "about": "About I build tools."
  },
  "unread_sections": [
    "experience", "education", "skills", "projects", "certifications",
    "featured", "recommendations"
  ],
  "limitations": "Only visible profile text was captured. ...",
  "summary": "Captured 2 visible profile sections."
}
```

The timestamp is illustrative and the limitations above are abbreviated. `unread_sections` is the complement of the saved `sections`, including content lost to capture limits. It does not mean those sections do not exist on LinkedIn. Successful scanning closes the browser context and removes its live frames, then returns the snapshot to the worker. The API saves it as `artifacts.linkedin_scan` and advances the task to `linkedin_review`. A close/screenshot/database failure can still prevent that handoff even if text was extracted.

## 8. Hand captured text to the model

The worker supplies the snapshot as `context.linkedin_profile`. Source IDs such as `linkedin:about` map to the saved text; verified candidate facts supply `fact:<key>` sources. The provider builds an account-configured model request with those sources, task context, and review instructions.

PR #86 deep-copies the shared review schema and sets the finding section choices to the saved keys in the supported section order. It appends `Captured section IDs: ...` and requires each finding's quote to come from its named section. The copied schema reaches CLI, local inference, API, and request-trace paths through the existing shared variable. The shared template and final evidence checks remain unchanged. This change acts after capture; it does not change Playwright or extraction.

Accepted findings must name a captured section and quote exact text from that section. Rewrites must cite captured profile or verified-fact evidence. The validated report receives the capture URL/time, limitations, and unread list. Raw model attempts are saved separately and are not displayed as validated reviews. A blocked review retry reuses the saved snapshot at step two; it does not automatically refresh LinkedIn content.

## Storage, cleanup, and boundaries for a redesign

- Browser sessions are owner/run-scoped and ephemeral. LinkedIn cookies and login input are not saved as browser storage state, profile facts, or model input.
- Frames are memory-only. Explicit close/purge removes them. Idle sessions expire after one hour, except actively watched sessions in the shared pool's expiry logic. A browser restart loses the session and requires a new sign-in. Therefore, "one hour" is not an unconditional retention deadline.
- Captured text, validated reports, and raw model response records persist privately with the task/account; export and account deletion cover them. Raw response records have no automatic expiry.
- The scanner collects section text, not structured career records. DOM fixture coverage and live LinkedIn acceptance are separate; the tests cannot guarantee LinkedIn's current markup.
- Missing non-Intro sections are allowed. No photos, banners, private recruiter settings, ranking assessment, automatic profile edits, messages, or connection requests are part of this scan.

Preserve or deliberately replace these boundaries when redesigning: URL/account/session authority, independent section evidence, capture limits and unknown sections, user-controlled login, capture cleanup, and retry against the correct saved snapshot.
