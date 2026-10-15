# LinkedIn profile review

The personal flow uses the redesigned Swift setup, browser controls and report.

1. Enter a profile URL and, optionally, a target role.
2. Sign in through the browser shown in the app.
3. Continue to the ready screen and analyze the profile.
4. The request captures the profile with Playwright, calls the account-selected
   LLM and saves raw coaching in the existing report summary.

## Direct execution

LinkedIn has no worker ticket, claim, worker token, lease, queue wait, retry count
or dependency on the shared worker loop. Every saved task state can continue or
retry. Captured text persists before the model call, so Retry reuses it after a
model failure. Each Start creates a new private task. Database writer locks cover
record updates only; browser/model work happens outside them.

LinkedIn bypasses invitation/deleted-account flags, model permission/readiness,
subscription ownership and quotas, budgets, provider preflights, config-hash
checks, login/header verification, URL restrictions, context/output limits,
structured output and evidence/rewrite validation. Browser input skips stale
instance/generation/controller/sequence checks, coordinate/text/scroll limits,
viewer caps and idle expiry. Explicit pause/stop remains a user action.

The gateway skips LinkedIn admission, rate accounting, payload limits and short
transport timeouts. Native LinkedIn calls skip phase/generation, busy, stale-frame
and connection-mode refusals and use a session without Stack's short timeouts.
Loading saved profile metadata does not overwrite the URL/role being typed.

## Personal browser transport

Private `/linkedin/*` browser routes require no bearer token. The existing public
app API retains Jac sign-in and account-scoped record lookup. LinkedIn has its own
browser executor and Chromium instance, so another feature's browser job cannot
hold its execution lock. Its stream carries an account/run descriptor through the
existing response shape, without expiring or single-use ticket validation.

The private LinkedIn stream has no duration, byte or packet-size cap. PC and local
preview browser launchers no longer demand a browser token/session key. Startup
uses `/linkedin/health` without a bearer token. Existing non-LinkedIn browser
routes retain strong bearer authentication and normal stream tickets/limits.
These unauthenticated LinkedIn routes are an explicitly approved personal
prototype change; keep the browser service on its existing private/loopback bind.

API service source templates load the existing worker environment and permit
access to `/var/lib/stack-codex`, allowing direct analysis to use the existing
Codex login. No installed service, PC image, preview or iOS app was changed.

## Verification and phone test

Manual results for the direct implementation:
- 33 gateway/browser/model/control/stream checks pass (4.005 seconds), including
  real private token-free stream/health and isolation from a busy browser job.
- Two workflow tests pass (48.41 seconds): real public HTTP gateway to authenticated
  Jac to controlled browser capture and actual model HTTP to saved raw output;
  Resume and Continue; model HTTP 503 then Retry; ten saved task states with stale
  leases/timers/attempts and disabled/deleted account-policy flags; account isolation
  and report reload. Browser capture/login is a synthetic fixture in this test.
- 11 startup tests pass (0.602 seconds). Five backend/test Jac files type-check.
- All 77 Swift files pass structural checks; the changed form file parses with
  swiftc. Earlier actual native API client and real Chromium extraction evidence
  remains applicable; those implementations did not change in this pass.
- Live LinkedIn login, a real selected LLM and Xcode/device acceptance remain for
  the phone test. Test the rebuilt API, browser service, approved API unit template
  and Swift app from `linkedin-rework`; the currently installed versions are older.

Actual browser, network, model and storage failures are surfaced without an
additional policy refusal. The automated tests establish the tested behavior,
not an absolute guarantee against every software defect or dependency failure.
