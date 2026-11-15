# Job discovery

Stack keeps real shared listings in its Jac/Postgres database, separate from each user's account graph. Right swipe saves a **Ready to apply** record and offers optional agent help; it never starts an agent. The source application page opens on the phone; submission is recorded only when the user explicitly marks it submitted.

## How jobs arrive

Listings are collected **once a day**. `stack-jobs-sweep.timer` starts `scripts/jobs-sweep.jac` at 10:00 America/New_York (a missed run happens at the next boot). The sweep:

1. Collects every source in `discovery/sources.json`: public Greenhouse, Ashby, Lever and SmartRecruiters boards, plus curated GitHub lists. The GitHub lists contribute the public job boards they link to, which are collected in the same run (up to 300 boards in total). Other linked pages and newly discovered repositories are not collected.
2. Adds or updates each listing. A listing that a **cleanly collected** source no longer lists is closed. A source that fails, has unreadable listings, or suddenly lists nothing keeps its previous listings; they drop out of matching once unconfirmed for seven days.
3. Ranks every account's matches for its saved search and stores them.

For the configured Stripe board, the collector also reads the employer page linked by Greenhouse, in batches of ten openings. It uses structured fields only when the title and posting ID agree, and records the employer page URL in the attribution. If that page is unavailable the collector uses the board record. Other boards use their public provider payloads.

Cards also show locations explicitly assigned to the role in the stored posting text. For example, a Greenhouse headline may say only “Hybrid” while an “Available Locations” section lists multiple offices. Remote options and regional scope are preserved.

Card excerpts are computed when a feed page is read, so existing descriptions can supply pay and qualifications after a backend update. Fields previously discarded by a source adapter, including Greenhouse publication dates and Lever's additional text, require the updated collector to finish a sweep. The sweep rebuilds the search index and account matches. Allow cached phone feeds to reload after the sweep. A board that no longer publishes an opening cannot supply its missing fields.

Nothing collects between sweeps, and no request from the app ever triggers collection.

**In the app**, opening Jobs shows the phone's cached cards immediately and reads the stored matches (`job_feed`), 25 at a time. Coming back to the app reloads only if a newer sweep could have run. Changing filters or a profile input saves the search and ranks that one account again from the existing catalog (`save_search` returns the first page). The account refresh (`bootstrap`) no longer carries jobs, and the app has no timed refresh; it rechecks the account only while an agent task is running.

A new account can rank the existing shared catalog immediately; it never waits for the next sweep. Role searches first apply the exact title/related-occupation matcher to a shared title list, then rank compact shared listing facts grouped by occupation. Full records are loaded only for the displayed page; description-text exclusions use the indexed `match_title` path so their original-text checks stay exact. Other preferences, ranking, totals, and pagination retain the same rules. The sweep builds this projection before account matching and maintains new titles during collection. Existing databases use the full-catalog path until their first sweep rebuilds the projection.

For an isolated Mac browser workflow and measured production sizing, see [the jobs lab](JOBS_LAB.md).

Importing a job link is not available yet. `import_job_url` answers with that message.

## Employer logos on job cards

The Jobs feed resolves each page against two shared Postgres tables. `stack_employer_brand` holds one reviewed PNG, display name, and artwork source per employer. `stack_employer_brand_key` connects exact domains and hiring-board identifiers to that employer. A board can identify a posting with a blank domain. An unrecognized explicit domain or a conflict between two identified employers leaves the card unbranded. The iPhone then shows the company initial. Logos travel with the feed once per employer per page and the iPhone can restore them with its cached cards.

From a checkout of the matching revision, install the directory into each catalog database using its database owner's connection. For example, with the catalog connection configured in `PGHOST`, `PGDATABASE`, and `PGUSER`, run:

```sh
set -o pipefail
python3 scripts/sync-employer-brands.py | psql -X
```

To add or change a logo, review the employer's own artwork at 40 pixels. Save a crisp 120 x 120 PNG smaller than 32 KiB in `discovery/brand_logos` and record the source URL and verified domain or board identifiers in `discovery/employer_brands.json`. Run the same sync after editing. The manifest is authoritative for these two tables, including removals. The sync is atomic and safe to repeat. Current and future postings pick up changes on the next feed request. This works without rewriting postings or running a collector sweep.

## Card media

Reserve a square for the employer mark (all reviewed PNGs are 120 x 120) and a 5:2 rectangle for the posting photograph (all JPEGs are 1050 x 420). The feed returns a `photo_id` on each job. On iOS it identifies the bundled resource `job-photo-<photo_id>.jpg`; the Jobs lab serves the same bytes at `/job-photos/<photo_id>.jpg`. Old cached cards without a photo ID can use `job-photo-forest.jpg`. Neither the size nor the aspect ratio depends on the posting.

The photo directory in `discovery/job_photos.json` records the original Pexels page and reviewed location names. Matching uses the posting's location labels or explicit role-location statement. Ambiguous bare names need supporting geography or a reviewed employer-board alias. A multi-location card can use its matching search city. Otherwise ambiguous, remote-only and unmapped locations use a nature photo chosen from the posting ID. Assignment happens at feed read time, including for older database rows. To extend the directory, add an identically cropped JPEG to `ios/Stack/Resources/JobPhotos` and its source and geographic identity to the manifest.

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
- **Pay** compares hourly and yearly pay at 2,080 hours/year. Provider estimates and non-USD pay count as unknown. Pay text such as "the annual salary range is:" followed by "$150,000—$200,000" is read; funding amounts and 401(k) mentions are not.

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
