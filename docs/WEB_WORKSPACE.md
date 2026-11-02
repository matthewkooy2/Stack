# Browser workspace

Login supports Stack password, Google, and [configured Apple web sign-in](APPLE_NATIVE_SIGNIN.md#browser-apple-sign-in).

Run `make dev` after setup and open http://127.0.0.1:8080. Rebuild browser assets
with `scripts/jac build --as client workspace` after source changes; ordinary
contributor setup also builds them. The browser uses the current native iOS
navigation order and the blue, warm-white visual style in `ios/UI_STYLE.md`.

- **Jobs:** saved search and profile defaults, filters, full employer text, save,
  pass, pagination, and employer links. Saving creates a Ready to apply record.
- **Applications:** status/search filters, notes, submission confirmation,
  resume selection, agent help, practice plans, calendar agenda and follow-ups.
- **Network:** real contacts and outreach controls, session-only GitHub/portfolio
  drafts, and the existing LinkedIn review/browser handoff.
- **Resume:** PDF/DOCX upload, progress/retry, default selection, rename, download,
  deletion, imported-record confirmation, job scoring/tailoring and experience bank.
- **Prep:** the existing practice library, saved attempts and mock interviews.
- **Profile:** matching/timeline preferences, agent model selection, confirmed
  facts, outbound permissions, Google capabilities, export and sign-out.
- **Agents:** existing tasks, exact-content reviews, browser handoffs and features.

All account writes use the existing authenticated endpoints. The browser requires
neither the iOS app nor an iOS session. Navigation retains new-screen drafts;
sign-out clears them. Reload requires sign-in again because tokens stay in memory.
Public-profile drafts explicitly stay in the browser session. Reminders persist
in the account; this workspace does not schedule browser notifications.

A model, discovery, transcription, or isolated-browser worker is still needed for
its corresponding backend operation. Google features require OAuth configuration.
The existing bounded document worker supports Linux/Windows, and rejects PDF and
DOCX processing on macOS; the web UI surfaces the backend failure. This UI change
does not relax that restriction.

## Manual browser acceptance

Use a disposable local installation, with the API and gateway running. Install or
reuse Playwright outside the committed runtime dependencies, then run:

```sh
STACK_WEB_URL=http://127.0.0.1:8080 \
STACK_API_URL=http://127.0.0.1:8000 \
STACK_PLAYWRIGHT_MODULE=/path/to/playwright \
node tests/web-workspace.cjs
```

`STACK_CHROME` can select an installed Chrome executable. This manual check is
not a new CI gate. It creates a synthetic account, seeds explicitly labelled
catalog fixtures through the existing worker-token boundary, purges that source
on exit, and saves screenshots under `.jac/web-acceptance`. It checks desktop and
390px navigation, search/save/pass, persistent notes, failed-save recovery,
submission, follow-ups, calendar, contact saving, rules/facts, Prep saving and
session isolation. Linux/Windows also check real file upload/rename/download;
macOS checks the documented document-processing failure instead. It makes no model
requests and sends no external messages. Native-device behavior and external
provider acceptance remain separate checks.
