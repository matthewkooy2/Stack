# Job discovery

Stack keeps real shared listings in its Jac/Postgres database, separate from each user's account graph. Right swipe saves a **Ready to apply** record and offers optional agent help; it never starts an agent. The source application page opens on the phone; submission is recorded only when the user explicitly marks it submitted.

## How jobs arrive

Listings are collected **once a day**. `stack-jobs-sweep.timer` starts `scripts/jobs-sweep.jac` at 10:00 America/New_York (a missed run happens at the next boot). The sweep:

1. Collects every source in `discovery/sources.json`: public Greenhouse, Ashby, Lever and SmartRecruiters boards, plus curated GitHub lists. The GitHub lists contribute the public job boards they link to, which are collected in the same run (up to 300 boards in total). Other linked pages and newly discovered repositories are not collected.
2. Adds or updates each listing. A listing that a **cleanly collected** source no longer lists is closed. A source that fails, has unreadable listings, or suddenly lists nothing keeps its previous listings; they drop out of matching once unconfirmed for seven days.
3. Ranks every account's matches for its saved search and stores them.

Then it exits. Nothing collects between sweeps, and no request from the app ever triggers collection.

**In the app**, opening Jobs shows the phone's cached cards immediately and reads the stored matches (`job_feed`), 25 at a time. Coming back to the app reloads only if a newer sweep could have run. Changing filters or a profile input saves the search and ranks that one account again from the existing catalog (`save_search` returns the first page). The account refresh (`bootstrap`) no longer carries jobs, and the app has no timed refresh; it rechecks the account only while an agent task is running.

Importing a job link is not available yet. `import_job_url` answers with that message.

## Running a sweep

```sh
./scripts/jac run --no-serve scripts/jobs-sweep.jac   # or: python3 scripts/catalog.py sweep
```

The local API must be running. The worker token is generated into private `storage/discovery/worker-token`; it never enters the app build. `./scripts/dev` no longer runs a collector.

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

The sweep analyzes description, qualifications, and eligibility text as it stores each listing, keeping the extracted graduation windows, start/end dates, student/degree requirements, and verbatim evidence with the shared listing. Personalized assessments are calculated from private preferences, never written into the shared listing. Timeline changes invalidate old pagination cursors.

Jobs default to **Hide timeline mismatches**. **Confirmed timeline matches only** keeps explicit graduation-window matches; **All timelines** includes mismatches for inspection. Cards and details explain the result; details show the supporting text. This checks timeline compatibility only, not degree subject, experience, work authorization, or overall eligibility.

This version uses deterministic text rules, **not an AI model**. Missing windows, snippets, alternatives, negations, conflicting windows, seasonal dates, day-level boundaries, and unsupported wording stay unclear. A generic degree requirement or a year in the job title is not evidence that an applicant must already have graduated. Returning-to-school requirements remain unclear unless an explicit internship end date establishes a mismatch. No descriptions or personal data are sent to a model provider and there are no model charges.

## Sources

- `discovery/sources.json` is the reviewed list. To add a source, add its exact configuration (`id`, `adapter`, `name`, `board` or `repo`, `sector`, `approved:true`) after checking the site's permitted access and testing the extraction. The next sweep adopts changes to configured sources.
- The reviewed San Francisco municipal SmartRecruiters source uses a public ID manifest, a 1,000-posting ceiling and ten-detail batches; see [municipal discovery evidence](MAT19_DISCOVERY.md).
- `discovery/employers.json` (200 employer candidates) is kept for future expansion and is not collected.
- Paid providers (Adzuna, TheirStack, USAJOBS) and the browser-rendered fallback were removed. An optional `GITHUB_TOKEN` raises GitHub rate limits.
- O*NET 31.0 occupation titles and aliases are bundled under CC BY 4.0; see `discovery/NOTICE.md`.

## Source administration and measurement

```sh
python3 scripts/catalog.py report
python3 scripts/catalog.py audit
python3 scripts/catalog.py sweep
python3 scripts/catalog.py disable SOURCE_ID
python3 scripts/catalog.py enable SOURCE_ID
python3 scripts/catalog.py purge SOURCE_ID
```

`disable` stops collecting a source. `purge` also removes the content it supplied; use it when rights to display a source end. Tracked application notes and decisions remain, with an unavailable-listing placeholder. Reports are written to `artifacts/discovery-coverage.json`. The audit refetches official active-job IDs for up to 120 sampled listings. It measures activity and duplicates among collected jobs, **not nationwide recall**.

Listing and source lookups use the indexes declared in `[database]` in `jac.toml`. Restart the backend after changing index declarations so migrations occur before reads.

## Verification

```sh
python3 tests/test_discovery.py
python3 tests/test_sweep_runner.py
python3 tests/test_matching.py
PYTHONPATH=. python3 tests/test_timeline.py
./scripts/jac test tests/catalog_tests.jac
./scripts/jac run --no-serve tests/test_jobs_sweep_api.py
./scripts/jac run --no-serve tests/test_jobs_feed_api.py
# Against a running local API:
python3 tests/test_catalog_api.py
python3 tests/test_matching_api.py
python3 tests/test_timeline_api.py
```

On the host, see [the PC host README](../deploy/pc-host/README.md) to replace the retired always-on collector with the timer.
