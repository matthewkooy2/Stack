# Job discovery

Stack now keeps real shared listings in its existing Jac/Postgres database, separate from each user's account graph. Right swipe saves a **Ready to apply** record and offers optional agent help; it never starts an agent. The source application page opens on the phone; submission is recorded only when the user explicitly marks it submitted. Existing demo applications remain labeled. New accounts start without fictional applications.

## Start

```sh
./scripts/dev
```

This starts the API, Metro, and a resumable Jac collection worker. Leave the Mac awake and on the phone's Wi-Fi. Logs: `.jac/logs/api.log`, `metro.log`, `discovery.log`. The worker token is generated into private `storage/discovery/worker-token`. It never enters the mobile build. Stop all three with Ctrl-C. A startup after sleep/restart resumes stored checkpoints; an interrupted lease can take up to ten minutes to expire.

In Jobs, open filters to change role, occupation, city/state, work arrangement, level, employment type, advertised pay and posting age. **Best match** is the default: title fit and confirmed requirements first, then nice-to-haves, then posting date. **Newest first** orders dated jobs by posting date, with unknown dates last. **Has posting date** excludes undated jobs. Sorting applies across the matching catalog before pagination, and changing either control does not itself create a distinct paid search. Search results are cached and refresh in the background. **Refresh jobs** requests a refresh subject to the six-hour cache; it does not bypass budgets. Ordinary four-second account polling does not call external providers. The Jobs screen checks cached results every twenty seconds while mounted. **Live sources** shows pending, collecting, partial, unavailable, quota, error, and review states.

## Matching

`discovery/matching.py` turns each listing into facts (work arrangement, remote region, places, employment type, level, required years, degree, pay, and licenses to confirm), each with the text it came from. It then checks them against the user's inputs. Every check is **match**, **partial** (fits with a caveat), **unknown** (the listing does not say), or **conflict**.

- **Inputs.** Profile: target roles (comma-separated), location, work arrangements, career stage, years of experience in the field, education, graduation/availability months, employment types, minimum pay, hidden employers/terms, and which inputs are only nice to have. A search can override role, location, arrangement, level, type, pay and exclusions.
- **Requirements vs. preferences.** A required conflict hides the job. Nice-to-have conflicts, stretches (at most one year short of stated experience) and over-qualification only lower the ranking and are listed as caveats.
- **Missing information.** Unknown facts never hide a job by default. The card says "Some requirements unconfirmed" and lists them. **Confirmed matches only** hides these jobs.
- **Related titles.** A title matches when it contains the role's words, or shares an O*NET occupation with the role (e.g. Charge Nurse for Registered Nurse). Ambiguous single words such as "nurse" never drive expansion, and "Teacher Recruitment Specialist" does not match "Teacher". Every other input still applies to expanded titles.
- **Precedence.** Saved searches store only the values that differ from the profile, and the Jobs screen names them ("This search changes your profile's location"). **Use profile** clears them. Editing a profile field removes any older search override of that field.
- **Pay** compares hourly and yearly pay at 2,080 hours/year. Provider estimates and non-USD pay count as unknown. Pay text such as "the salary range is:" followed by "$150,000—$200,000" is read; funding amounts and 401(k) mentions are not.

Check matching behavior against independently labeled synthetic examples:

```sh
python3 tests/matching_eval.py            # 58 written listings x 10 personas
python3 tests/matching_eval.py heldout    # 68 original synthetic listings x 7 personas
```

It reports unsuitable jobs admitted, suitable jobs excluded, incomplete listings hidden, and incomplete listings claimed as confirmed, for both the pre-fix matcher and the current one. Labels must not be edited to fit matcher output. The `heldout` name is retained for CLI compatibility; these fixtures are regression cases, not a real-world accuracy benchmark. See `tests/fixtures/README.md` for provenance.

## Graduation timeline

Set optional **Expected graduation (YYYY-MM)** and **Available full-time from (YYYY-MM)** in Profile or the Jobs timeline panel. These belong to the signed-in account; new accounts have no assumed graduation date. Availability is not applied to internships.

The local collector analyzes description, qualifications, and eligibility text once per content/rules version and stores the extracted graduation windows, start/end dates, student/degree requirements, and verbatim evidence with the shared listing. A resumable worker migration processes existing listings in batches of 50. Personalized assessments are calculated from private preferences, never written into the shared listing. Timeline changes invalidate old pagination cursors.

Jobs default to **Hide timeline mismatches**. **Confirmed timeline matches only** keeps explicit graduation-window matches; **All timelines** includes mismatches for inspection. Cards and details explain the result; details show the supporting text. This checks timeline compatibility only, not degree subject, experience, work authorization, or overall eligibility.

This version uses deterministic text rules, **not an AI model**. Missing windows, snippets, alternatives, negations, conflicting windows, seasonal dates, day-level boundaries, and unsupported wording stay unclear. A generic degree requirement or a year in the job title is not evidence that an applicant must already have graduated. Returning-to-school requirements remain unclear unless an explicit internship end date establishes a mismatch. No descriptions or personal data are sent to a model provider and there are no model charges.

## Provider configuration

Copy `discovery/credentials.example.json` to `storage/discovery/credentials.json`, fill in credentials locally, then restart `scripts/dev`. Do not put keys in chat, source files, or mobile environment variables. The storage directory is ignored by source control; restrict the credentials file to your user (`chmod 600`). Environment variables with the same names also work.

| Provider | Required values | Development limits |
|---|---|---|
| Adzuna | `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, `STACK_ADZUNA_APPROVED=yes` after approved access | 25/minute, 250/day, 1,000/week, 2,500/month; three 50-result pages per search |
| TheirStack | `THEIRSTACK_API_KEY`, `STACK_THEIRSTACK_TERMS_ACCEPTED=yes` after terms review | $49 subscription chosen manually; reserve at most 1,500 returned jobs/month and 50/day; 25 per dispatch |
| USAJOBS | `USAJOBS_API_KEY`, `USAJOBS_EMAIL` | Three 50-result pages per search; provider backoff on errors |
| GitHub | Optional `GITHUB_TOKEN` | Conditional requests for curated lists; weekly repository discovery; rate-limit failures back off |
| Brave | Disabled | No requests or charges; storage rights must be established before implementation/enabling |

No paid accounts were purchased or connected during implementation. TheirStack is a gap-filler: when the catalog already has 25 matching listings, its search is skipped to preserve credits. Returned provider IDs are excluded on subsequent searches. Reservations are committed before requests; uncertain failures consume the reservation conservatively. No automatic upgrades or purchases exist. $20 of the $100 total development ceiling remains reserved for possible future search discovery, with the rest uncommitted.

Adzuna uses its required redirect links and bundled official logo. Its snippets are labeled; predicted salaries are omitted to avoid presenting them as employer pay. TheirStack redistribution and retention conditions must be covered by the deployment's terms before setting its acceptance flag. Full provider terms: [Adzuna](https://developer.adzuna.com/docs/terms_of_service), [TheirStack](https://theirstack.com/en/docs/legal/terms-and-conditions). Disabling a subscription is not an automatic notification to Stack: use the purge command below when rights to display a source end.

## Sources and expansion

- `discovery/employers.json`: 200 employer discovery candidates across twelve sectors. Registration does **not** mean verified job coverage.
- `discovery/sources.json`: public Greenhouse, Ashby, Lever, SmartRecruiters feeds and GitHub list/directory configurations, plus weekly repository discovery.
- Curated GitHub sources produce destination links, not jobs. Newly discovered repositories enter review; Stack never executes repository code.
- Company pages use robots-checked HTML/JSON-LD. Same-host career links inherit the approved employer policy, with bounded link counts and depth. Known public ATS links become feed candidates. Other external hosts require review.
- Workday, Taleo, iCIMS, and similar sites are not treated as universal open APIs. Unsupported sites remain visibly in review; they are expected coverage gaps until a provider or tested adapter covers them.
- O*NET 31.0 occupation titles and aliases are bundled under CC BY 4.0; see `discovery/NOTICE.md`. Classification is conservative; unknown titles remain searchable.

To approve a source requiring review, add its exact configuration to `discovery/sources.json`, including its `id`, `adapter`, `name`, public `url`, `domain`, `sector`, and `approved:true`, after checking the site's permitted access and testing the extraction. Existing source configuration changes require the `configure` command below. Never set a whole browser/URL namespace to unrestricted access.

Optional HTML fallbacks take a `selectors` object with exact tag, `#id`, or `.class` selectors for `title`, `company`, `description`, and `location`, plus explicit `country`. They must be tested against a fixture. No generic header is guessed to be a job.

An optional browser fallback supports `renderer:"playwright"` and an explicit `browser_hosts` list. Install `discovery/browser-requirements.txt` and Chromium in the interpreter used by Jac before enabling it. This runtime is not installed/enabled by default. Every browser HTTP request goes through the DNS-pinned public transport; unapproved hosts, non-GET requests, service workers, and WebSockets are blocked. No browser-based site was certified during this implementation.

## Source administration and measurement

```sh
python3 scripts/catalog.py report
python3 scripts/catalog.py audit
python3 scripts/catalog.py refresh greenhouse:stripe
python3 scripts/catalog.py retry greenhouse:stripe
python3 scripts/catalog.py disable SOURCE_ID
python3 scripts/catalog.py purge SOURCE_ID
python3 scripts/catalog.py configure SOURCE_ID
```

`refresh` starts a fresh collection; `retry` preserves the page checkpoint. `disable` stops collection. `purge` stops collection and removes supplied catalog content, including mixed records whose selected detail came from that source; independent copies can be recollected. Tracked application notes and decisions remain, with an unavailable-listing placeholder instead of revoked source details.

Reports are written to `artifacts/discovery-coverage.json`. They include per-sector coverage, incomplete employers, occupation counts, source health, and reserved usage. The audit independently refetches official active-job IDs and samples up to 120 US jobs across connected employer feeds. It measures activity and duplicates among imported jobs, **not nationwide recall**. Sectors with zero jobs must be reported as gaps, not silently omitted. New adapters should be prioritized by unique active jobs added to those gaps.

Catalog pages use stable key cursors and bounded database queries. SQL indexes are declared in `[database]` for this pinned runtime; its bundled guide incorrectly places that option under `[scale.database]`. Restart the backend after changing index declarations so migrations occur before reads. Do not reset `.jac` or the database.

## Verification

```sh
python3 tests/test_discovery.py
python3 tests/test_matching.py
PYTHONPATH=. python3 tests/test_timeline.py
JAC_TEST_JOBS=0 ./scripts/jac test tests/catalog_tests.jac
python3 tests/test_api.py
python3 tests/test_catalog_api.py
python3 tests/test_matching_api.py
./scripts/jac run --no-serve scripts/compile-mobile.jac
node tests/native.cjs
python3 tests/persistence.py prepare
# Restart the backend, then:
python3 tests/persistence.py verify
```

Fixtures used by catalog and native integration tests are removed afterward. Tests require local API access; native tests mock iPhone OS behavior and do not certify layout or actual notification delivery.

On the phone: change professions → inspect real job/source → right swipe → open Applications → open source page → mark submitted → relaunch and verify persistence. Repeat with a non-SWE search; verify unknown pay and unavailable sources are honest. Check compact/large text layouts, import a public job link, and verify an inaccessible page produces review/error feedback. Existing resume/reminder checks remain in `docs/PHONE_TESTING.md`.
