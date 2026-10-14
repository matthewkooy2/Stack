# Backend browser saved-answer autofill (MAT-34)

Applications > Agent help > **Autofill saved answers** opens the saved job in
Stack's isolated backend Chromium browser. It uses confirmed account-owned facts
and, when explicitly saved, the Profile's full name. A saved fact takes precedence
over that Profile name snapshot. First/last names, cities and countries are never
inferred from a full name or general location. No model is called.

Starting autofill shares matched values with the employer form, which may autosave
before submission. The user reviews every field and submits inside the browser.
The retired `application` assistant and automatic submission stay disabled. The
new task kind is `autofill`, with one repeatable `browser_autofill` step.

## Use and recovery

1. Save confirmed values in Agents > Facts (for example `first_name`, `last_name`,
   `email`, `phone`, `linkedin`, `work_authorization`, `sponsorship`). Name and
   location fields do not imply other facts. Save a real job with a hosted ATS URL.
2. Choose a PDF or DOCX resume for the application before starting autofill.
3. Open its task's browser and take control. Handle sign-in, MFA, CAPTCHA, unknown
   controls and page navigation yourself. The remote session is separate from
   Safari/Chrome cookies. Closing the viewer leaves a user-controlled task paused.
4. Resume autofill after reaching the form or another step. It fills this page
   only and pauses again. It never clicks Apply, Next, Save, consent or Submit.
5. Unknown text/native-select questions can be answered in the task and explicitly
   saved for that exact normalized question. Use the displayed option wording.
   Existing form values are preserved; edit them in the browser yourself.
6. When a visible resume file input is recognized, take control and explicitly
   choose **Attach selected resume**. The API supplies only the owning account's
   resume selected when this task started (PDF/DOCX, up to 8 MB). Client-supplied
   bytes and alternate IDs are ignored. The input's selected file is verified;
   this does not prove the employer accepted an upload. Other attachments and
   hidden/custom upload widgets currently require completing the application
   outside this viewer. Clicking a file input alone cannot open the phone picker.
7. Review and submit yourself. Stop the task afterward. Stopping never marks the
   application submitted; use **I submitted this application** separately.

Taking control fences the worker's generation and lease before allowing user
input. Resuming requeues autofill even if unknown questions remain; facts are
refreshed from the owning account. Commands use the existing viewer controller,
instance, generation and sequence. Pauses occur between fields; an already-sent
browser event cannot be undone. Existing user values and attached files are never
replaced. A browser restart or idle expiry loses the ephemeral browser context:
sign in again rather than claiming the session was restored. Unwatched sessions
expire after one hour.

## Coverage and limits

The automated evidence is synthetic; it is not a live-employer compatibility
certification. `tests/test_autofill.py` uses intercepted fixture URLs only.

| ATS family | Hosted URL scope | Tested controls / identifiers | Manual variants |
| --- | --- | --- | --- |
| Greenhouse | `boards.greenhouse.io`, `job-boards.greenhouse.io`, `boards.eu.greenhouse.io` | Labelled form text/email; `first_name`, `last_name`, `email`, `phone` identifiers; wrapped-label native dropdown; visible resume file input | Custom React selects, hidden uploads, employer embeds/custom domains |
| Ashby | `jobs.ashbyhq.com` | Labelled form name/email/phone; `_systemfield_name`, `_systemfield_email`, `_systemfield_phone` identifier fallback | Custom widgets, hidden uploads, custom employer domains |
| Lever | `jobs.lever.co`, `jobs.eu.lever.co` | Labelled form name/email/LinkedIn; `name`, `email`, `phone`, URL identifiers | Employer-specific widgets, hidden uploads |
| Workday | Exact `tenant.wdN.myworkdayjobs.com` job host | Labelled controls under `formField`; `legalNameSection_firstName`, `legalNameSection_lastName`, `email`, `phone-number`; synthetic user-led page changes | Custom dropdowns, repeated work/education records, tenant-specific SSO redirects, hidden uploads |

Text, textarea, email, telephone, URL, number, date and native selects use common
filling/validation. Checkboxes, radios, custom comboboxes, consent and signature
controls stay manual. Passwords and one-time codes never become saved answers.
Repeated canonical fields are ambiguous and stay manual. Unsupported controls,
invalid/changed values and missing answers appear in the task report. The report
contains labels/status/source keys, not saved values. Each ATS frame is bounded
to 150 controls, with truncation disclosed. This milestone does not navigate
multi-page flows automatically or claim complete Workday tenant coverage.

Navigation is restricted to the chosen ATS family, or exact Workday tenant.
Resource hosts are bounded by family; known CAPTCHA embeds are allowed separately
and are never scanned for candidate fields. Unknown redirects require manual
external completion. The browser service still needs its existing isolation and
egress firewall; application URL validation does not replace that deployment
boundary. No firewall or credential changes are part of this patch.

## Matching and optional Choice evaluation

Exact saved-question answers precede canonical label aliases. Unlabelled controls
can use the ATS adapter's stable identifiers or standard autocomplete tokens.
Meaningful unknown labels never fall back to a misleading ID. Work authorization
and sponsorship remain separate keys. Dropdown options must match the saved
display text uniquely; their current meaning and validity are checked before and
after filling. Later changes to earlier fields are checked again at the end.

Jev/Choice could be an optional classifier after deterministic matching: pass
synthetic question text and allowed canonical field IDs, include none-of-above,
and return the unchanged saved value only after selecting a permitted ID. Its
confidence is not proof of correctness. Benchmark with paraphrases, negations,
country differences, sponsorship/authorization distinctions and malicious page
instructions before considering integration. This patch adds no provider,
dependency, credential or external model transmission.

## Verification and delivery boundary

Local candidate verification on 2026-10-11: 19 synthetic DOM/contract tests and
the authenticated lifecycle/upload fixture pass. Browser-service tests pass
(12), as do control (6), stream (3), preview (9), Swift static unit checks (9),
53-file Swift source checks and the published live-call contract. The source-only
release validates, includes identical backend/browser autofill modules, and its
packaged Python module imports and executes contract checks. Independent review
findings were corrected; no remaining concrete defect was found in reassessment.
This evidence does not establish live ATS or iOS device compatibility.
An additional existing retirement/viewer regression rerun is unconfirmed because
WSL stopped accepting connections (`WSAETIMEDOUT`). Its isolated test process
could not be inspected afterward; the shared distro was not restarted. Recheck
that task-owned process and rerun those regressions when the runtime responds.

Tracking: [MAT-34](https://linear.app/matt-kooy/issue/MAT-34/add-backend-browser-saved-answer-autofill-for-four-ats-families).

Use the pinned Jac compiler (`jac check` for changed modules, `jac test
tests/autofill_workflow_tests.jac tests/application_retirement_tests.jac
tests/browser_viewer_tests.jac`) and existing browser service/control/stream tests.
Run `python -m unittest discover -s tests -p test_autofill.py` with Playwright
1.58.0 and its matching Chromium. Use `scripts/ci/ios-swift.sh static`, then
`scripts/ci/ios-swift.sh test` on macOS for compilation/simulator coverage.

Physical iPhone interaction, real hosted ATS rendering/resource coverage,
employer upload acceptance, tenant login and CAPTCHA completion remain separate
release checks. No real application, push, merge, deployment, credential change
or model download is authorized by this milestone. Browser packaging includes
`agents/autofill.py`; the deployment receiver's independently installed source
allowlist will need ordinary reviewed synchronization before a future release.

The candidate changes shared backend contracts and Swift ApplicationAgentSection,
TaskDetailView and BrowserViewer. Reconcile those files with held UI PR70 before
publication. Speech restoration paths are untouched.
