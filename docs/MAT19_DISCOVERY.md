# MAT-19: municipal government discovery

Selection recorded before implementation on 2026-10-06, base `9d6a973`.

The last measured catalog (`artifacts/discovery-coverage.json`, 2026-09-27) has
401 active US listings, 336 in Technology, and zero in Government, Healthcare,
Finance, Nonprofits, Professional services and Transportation. These are historical
catalog measurements, not current nationwide coverage. The 200-employer directory
is a candidate directory, not working coverage.

This slice completes the public SmartRecruiters municipal-government collection
path for one explicitly selected employer: City and County of San Francisco,
board `CityAndCountyOfSanFrancisco1`, official employer domain `sf.gov`.
The unauthenticated public Posting API returned 159 US postings in the initial
2026-10-06 probe. The target is at least 25 newly collected, active US government
listings in a disposable catalog, with ten exact listing samples independently
refetched and compared. No production catalog measurement or deployment is implied.

Public access evidence: [official employer career board](https://careers.smartrecruiters.com/CityAndCountyOfSanFrancisco1),
[San Francisco application guide](https://media.api.sf.gov/documents/SmartRecruiters_Guide_final_V2.pdf),
[public Posting API documentation](https://developers.smartrecruiters.com/docs/posting-api),
[active postings and detail endpoints](https://developers.smartrecruiters.com/docs/endpoints).
Only public, unauthenticated GET endpoints are used. No internal postings or application
automation is in scope.

Implementation must preserve title, employer/application URL, required text,
location, employment type, advertised posting dates and pay. This employer's
explicit Close Date field can establish expiry; ambiguous prose deadlines remain
in the description. Persist a bounded ID manifest before fetching details so a
restart does not resume against shifted listing offsets. Cap the manifest at
1,000 postings, list pages at 100 and detail batches at ten. Malformed or changing
manifests must fail without triggering absence-based removal.

Verification includes deterministic adapter-to-worker-to-catalog-to-account-search
fixtures, restart, cross-source identity, expiry/removal, withdrawal, malformed
data and budget boundaries, plus a bounded live collection and ten-listing audit.
Exact commands and resulting measurements will be added after execution.

## Evidence recorded 2026-10-06

The Windows live adapter run collected 159 distinct public listings in 18 batches
(two 100-ID list pages, sixteen batches of at most ten details). 158 were active
when explicit employer expiry was applied; one supplied Close Date had passed.
Ten separately fetched official detail responses and public posting pages matched
the collected title, employer, application URL, full required text, qualifications,
location, employment type, posting date and supplied expiry. Structured pay was
absent on these ten samples; employer pay prose is preserved in the full text and
is assessed by the existing matching rules. The generic structured-pay contract
is covered deterministically.

| Posting ID | Verified title |
|---|---|
| 3743990001841276 | Administrative Analyst (1822) - Multiple Departments Citywide (C00186) |
| 3743990001939637 | Human Resources Analyst (1241) - Multiple Departments Citywide (C00183) |
| 3743990002541616 | Senior Stationary Engineer (7335) at the Academy of Sciences |
| 3743990004051136 | Management Assistant (1842) - Multiple Departments Citywide (C00195) |
| 3743990004283316 | SENIOR MANAGEMENT ASSISTANT (1844) - Multiple Departments Citywide (C00196) |
| 3743990004931536 | Librarian I  - San Francisco Public Library (3630, TEX As-needed) |
| 3743990005669176 | Junior Management Assistant (1840) - Multiple Departments Citywide (C00194) |
| 3743990006092966 | Senior Administrative Analyst (1823) - Multiple Departments Citywide (C00187) |
| 3743990006093006 | Principal Administrative Analyst (1824) - Multiple Departments Citywide (C00188) |
| 3743990008082106 | Electrical Line Worker (7338, Specialty B) - Dept of Technology |

Raw local evidence: `artifacts/municipal-adapter-live.json`,
`artifacts/municipal-adapter-audit.json`, and `artifacts/municipal-live-audit.json`
(ignored runtime artifacts). The final audit ran the actual Jac worker in a fresh
process for every batch, against an isolated Jac/Postgres backend. Its tracked
source files matched the candidate exactly. Ten independent official detail
refetches matched the stored fields and each listing was returned by authenticated
account detail and title-search requests.

| Measurement | Before | After |
|---|---:|---:|
| Active US listings in disposable catalog | 0 | 158 |
| Active Government listings in disposable catalog | 0 | 158 |

The official public feed contained 159 IDs; one had a supplied Close Date that had
already passed, so the catalog correctly excluded it. All 159 collected records
had distinct listing identities. The ten exact sampled IDs appear above. These
are measured additions in a disposable environment, not production growth or
nationwide recall; do not add them to the historical production total.

Executed checks: python tests/test_discovery.py (21 passed),
python tests/test_municipal_discovery.py (7 passed), and
python tests/test_matching.py (16 passed plus both synthetic evaluations).
jac check scripts/discovery-worker.jac passed. The Linux contributor suite passed
all 12 tests, and `JAC_TEST_JOBS=0 jac test tests/catalog_tests.jac` passed all three
tests, including two clean missing cycles, the 24-hour removal boundary, invalid
cycles preserving listings and independent observations preserving activity.

`tests/test_municipal_runtime.py prepare`, an actual backend stop/restart with the
same storage, and `fixtures` passed: persisted manifest, adapter/worker/catalog/
account search, duplicate identity across sources, malformed refresh, immediate
expiry with warm search cache, disable, purge and retained application decisions.
The final `live` run passed in 18 batches with ten audited listings and account
search checks. No required test skipped.

Initial WSL memory pressure caused execution timeouts; execution recovered before
the required checks completed. The copied Python audit runtime needed
`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` to use the system trust bundle;
certificate verification remained enabled. The first audit failed at its TLS
handshake; a fresh empty-catalog collection and audit then passed with that setting.
Earlier Windows contributor errors were POSIX permission/platform differences;
the intended Linux suite passed without skips. No operator database or credentials
were used, and no deployment was performed.

## Repeat runtime verification

Use an isolated Linux copy with its own .jac, storage, worker token, auth secret
and database; do not point these tests at an operator or production API. Set
STACK_WORKER_API and STACK_API_URL to that disposable backend. Run:

```sh
JAC_TEST_JOBS=0 jac test tests/catalog_tests.jac
python tests/test_municipal_runtime.py prepare
# Restart the same disposable backend without resetting storage.
python tests/test_municipal_runtime.py fixtures
python tests/test_municipal_runtime.py live --jac /absolute/path/to/jac
```

The live mode launches the real Jac worker with --once --source for every batch.
It enforces a bounded manifest and separately audits ten exact listings through
account search. The audit is saved to `artifacts/municipal-live-audit.json`.
Existing installations that already discovered this board must run
python scripts/catalog.py configure smartrecruiters:CityAndCountyOfSanFrancisco1
to apply the reviewed manifest/deadline configuration.
