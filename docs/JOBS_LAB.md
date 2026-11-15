# Local jobs backend lab on a Mac

Run from this worktree:

```sh
cd /Volumes/DevSSD/Projects/Developer/Stack/worktrees/jobs-web-performance
python3 scripts/jobs-lab.py
```

Open **http://127.0.0.1:18280/**. The API listens on **127.0.0.1:18200**.
Leave the terminal running; Ctrl-C stops both services. This path needs the existing
project Jac 0.37.21 compiler, but no Xcode, simulator, iPhone, Metro, model login,
or live discovery worker. The first seed can take a few minutes. If backend
dependencies are missing, run `./scripts/jac install` in this worktree once, then
restart the launcher.

The browser is a focused test client for the actual backend. It sends the same
`bootstrap`, `save_profile`, `save_search`, and `job_feed` requests native clients
use. It is not a replacement for final iOS integration testing.

## Test a new user's first feed

1. Create a fresh local account using fictional details.
2. Enter a role, location, work arrangement, and optional level/type.
3. Select **Finish onboarding & show jobs**.
4. Read the visible-card time and feed API time. Expand **Request timings** to
   distinguish profile save, feed preparation, and network/proxy time.
5. Verify that jobs match the preferences, use **Load more jobs**, change a
   preference, and repeat.
6. Sign out and create another account to measure another first feed.

**Reload saved feed** measures the returning-account path, which can reuse
stored matches. It does not substitute for a fresh-account measurement. First
feed measurements may still benefit from the server's shared catalog cache;
restart the launcher, create another account, and repeat for a cold process.
The displayed visible time includes profile save, first-feed preparation,
transfer, and rendering. Feed time measures the `save_search` HTTP request that
returns the first page. These local times do not certify hosted performance.

Use the fictional roles represented by the seed (for example Software engineer).
These listings are clearly synthetic and must not be treated as live openings.

## Catalog size and production comparison

The default is **40,000 synthetic listings**, a configurable stress baseline.
A read-only production measurement on **November 1, 2026 at 8:27 p.m. Eastern**
found **12,840 total listings**, **9,544 fresh active listings**, **9,979 distinct
titles**, and **67,885 stored graph rows**. Descriptions averaged **6,249 characters**
with a **9,912-character 95th percentile**. The aggregate snapshot is saved in
`tests/fixtures/jobs-lab/production-baseline.json`; no private accounts or production
listing content are copied.

The version 2 synthetic fixture exceeds the measured catalog size, uses diverse
titles, longer description samples, and listing aliases to exercise the graph
shape. It is a stress fixture, not a production clone. Matching population,
active/expired ratios, indexes, hardware, cache warmth, and concurrent activity
also affect response times. Equal row counts alone do not prove equal performance.

```sh
python3 scripts/jobs-lab.py --name 50k --count 50000
```

The seeder checks its isolated catalog before proceeding. Use a different
`--name` for a different count; named datasets live under `.jac/jobs-lab-<name>`.
Larger existing datasets are preserved and rejected if a smaller count is requested;
interrupted seeding resumes using stable synthetic IDs. A fixture version update
refreshes synthetic listing data while preserving local accounts. Never point
this command at a production database. Current sizing details are recorded in the lab manifest.

## Repeatable HTTP measurements

With the lab running in another terminal:

```sh
python3 scripts/jobs-lab-benchmark.py --rounds 5 --output .jac/jobs-lab/benchmark.json
```

Each round creates a new synthetic account, saves preferences, requests the first
page, reloads it, and checks pagination has no duplicates. It reports each request
and the first-feed median/maximum. It measures HTTP only; the web page measures
visible cards separately. Restart the lab and rerun to distinguish the first
request in a cold process from later requests against a warm shared catalog.

## Isolation and edits

Backend source is copied into ignored `.jac/jobs-lab/app` at startup. That distinct
project base selects a distinct embedded PostgreSQL database in Jac 0.37.21.
`JAC_DATA_PATH` alone would not provide this guarantee in this runtime. Accounts,
catalog data, and storage remain separate from the normal development app.
Production database URLs, provider credentials, local override files, and existing
account storage are not copied. No collector or agent worker is started.

**Restart the launcher after editing backend code** to refresh its staged source.
The browser lab HTML is read directly from `web/jobs-lab.html`, so a page reload
picks up its edits. Reloading signs out because the test page keeps its session
token in memory. Its account and preferences persist across restarts.

Logs: `.jac/jobs-lab/api.log`. Dataset manifest: `.jac/jobs-lab/manifest.json`.
These files and the staged app are ignored, private local artifacts.

If the default ports are occupied, leave the other service running and use:

```sh
python3 scripts/jobs-lab.py --api-port 18300 --web-port 18380
```

Then open **http://127.0.0.1:18380/**. Both listeners bind only to loopback.
The launcher refuses occupied ports and never takes over another service.

## Measured local result — November 1, 2026

The 40,000-job fixture has 24,000 distinct titles and descriptions averaging
6,359 characters (p95 10,405), exceeding the measured production catalog and
physical database size. It is a synthetic stress fixture, not an exact clone.

Five fresh-account HTTP runs measured first-feed median **1.99 seconds**,
first cold-process feed **2.34 seconds**, and maximum **5.39 seconds**. Saved-feed
reads usually took about **0.4 seconds**. A single full-record baseline took
**40.6 seconds**. These are local observations with a warm PostgreSQL cache,
not hosted latency guarantees.

The actual browser signup/onboarding flow displayed 25 cards in **2.22 seconds**
(2.02-second feed API request), then loaded 50 cards through pagination.
Matching, source updates/purge, description exclusions, pagination and account
isolation passed the focused API regressions; staging has three passing checks.
Raw measurements are in `.jac/jobs-lab/benchmark-indexed.json` and
`.jac/jobs-lab/verification.json`. A final optional new-dataset/restart smoke was
deferred for immediate user handover.

Before a later production deployment, rebuild the public matching projection
from the existing catalog and verify a fresh account against the hosted backend.
This local task does not certify production rollout or native iOS integration.
