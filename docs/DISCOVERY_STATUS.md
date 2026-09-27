# Discovery status

Measured 2026-09-27T19:55:52.225347+00:00. Counts are a snapshot; the local worker continues collecting.

- Catalog: **1296** records; **401** active US listings.
- Live audit: **120/120** sampled listings remained in the official employer feeds; duplicate fraction **0.0%**.
- This is a quality audit of collected listings, not a claim of nationwide or all-profession coverage.
- Adzuna, TheirStack, and USAJOBS are implemented but unavailable until credentials and applicable access flags are configured.
- Brave is disabled. The optional browser renderer has not been installed or certified against a live site.
- The 200-employer directory contains discovery candidates; unsupported/blocked pages remain explicit coverage gaps.

| Employer sector | Active US listings | Incomplete sources |
|---|---:|---:|
| Construction | 16 | 27 |
| Education | 10 | 18 |
| Finance | 0 | 32 |
| Government | 0 | 20 |
| Healthcare | 0 | 35 |
| Hospitality | 10 | 18 |
| Manufacturing | 9 | 52 |
| Nonprofits | 0 | 14 |
| Professional services | 0 | 94 |
| Retail | 20 | 18 |
| Technology | 336 | 118 |
| Transportation | 0 | 23 |

## Verification

- 19 provider/parser/security tests passed.
- Jac quota-boundary test passed.
- 8 account/PDF/reminder API tests passed.
- 6 catalog integration tests passed, including service authorization, cursor pagination, concurrent swipes, and two-user isolation.
- Compiled Jac screen and native-boundary tests passed.
- Real application, saved search, catalog identity, and worker checkpoint survived a server restart. Existing PDF, reminders, contacts, and demo history also survived.
- Jac checks passed for the mobile app, backend, and worker.
- The physical iPhone is unavailable; actual phone rendering, application-page opening, and reminder delivery remain unverified for this release.

Detailed measured results: [coverage JSON](../artifacts/discovery-coverage.json). Setup and source controls: [job discovery](JOB_DISCOVERY.md).
