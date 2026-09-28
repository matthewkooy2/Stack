# Stack

An iPhone-first job-search application with real US job discovery across professions. Screens and application logic are Jac; a small JavaScript adapter provides native iOS capabilities.

Five tabs, in order: sample **Network**, real **Applications** tracking, swipeable **Jobs**, private PDF **Resume** management, and interview **Prep**. Prep includes technical and behavioral practice prompts with revealable guides. Profile settings and sign-out are available through the top-right avatar. Accounts, saved data, PDFs, and local reminders are real. Jobs come from real sources. Right swipe saves a Ready to apply record; users complete the source application and explicitly mark it submitted. Existing demo history, people, and tailoring previews remain labeled. Stack does not automatically submit applications or send messages. Muse, ChatGPT, and Claude are planned integrations.

See [job-discovery setup, source coverage, and budget controls](docs/JOB_DISCOVERY.md). Provider credentials are optional for public feeds and required for Adzuna, TheirStack, and USAJOBS.

## Run on your iPhone

From this directory:

```sh
./scripts/dev
```

Keep that terminal running. In a second terminal:

```sh
./scripts/ios
```

The build script reuses your installed Apple Development certificate and opens `.jac/mobile-rn/ios/Stack.xcworkspace`. Select your connected, unlocked iPhone in Xcode and press **Run**. Accept Trust/local-network prompts if shown. The Mac and phone must share a reachable Wi-Fi network. No Expo Go: PDF viewing requires this custom development build.

The launcher also runs the persistent discovery and agent workers. Open Stack's development launcher on your iPhone and choose **Stack** under local development servers; allow Local Network access when prompted. API and Metro URLs use your Mac's stable Bonjour name (`<Mac-name>.local`), which follows its current Wi-Fi address. When Wi-Fi changes while `scripts/dev` is running, it restarts Metro's discovery advertisement automatically. Reopen Stack to reconnect; there is no new URL to type. A previously saved numeric-IP entry may still be stale: choose the newly discovered Stack entry once.

Both devices must be on the same network, and that network must allow Bonjour and device-to-device connections. Guest/campus networks can block these; a personal hotspot is a straightforward fallback. `STACK_HOST=<reachable-hostname-or-IP> ./scripts/dev` remains available as an explicit override. Use `STACK_TEAM=YOURTEAM ./scripts/ios` to choose a different installed signing team. Optional `STACK_DEVICE=<device-identifier> ./scripts/ios` installs and launches directly using `devicectl`.

Jac screen saves recompile and trigger Metro refresh; backend saves restart the API. Logs are in `.jac/logs/`. The development server must be running for accounts, data, and PDFs. Already scheduled local notifications can fire while the Mac is asleep.

## Recreate the development build

The existing workspace is already provisioned. For a fresh checkout, install/use Jac **0.37.21**, Node **22.22.0**, CocoaPods **1.17.0**, and Xcode with an Apple Development identity, then run:

```sh
./scripts/setup
./scripts/dev
# In a second terminal:
./scripts/ios
```

`STACK_JAC_BIN` can point to a Jac 0.37.21 executable; otherwise `scripts/jac` uses `$HOME/.local/bin/jac`. The wrapper extracts its runtime inside `.jac/tool-cache`, fixing the broken system temporary-cache launcher encountered on this Mac. Keep that cache under `.jac`: placing the extracted runtime at the project root causes Jac to compile its own framework as application code.

JavaScript dependencies are pinned in `native/package.json` and `native/package-lock.json`; native pods are locked in `native/Podfile.lock`. Expo **57.0.25**, React Native **0.86.3**, and React **19.2.3** are the verified combination. Xcode **27.0** built this workspace successfully. Minimum deployment target is **iOS 16.4**, without model-specific layout assumptions. Setup uses Node for Expo prebuild because Bun produced an invalid Xcode project in this environment.

This is a local Debug project. The Expo config adds development HTTP/local-network access and removes remote push entitlements: reminders use local notifications and work with the existing personal signing team. `STACK_BUILD_MODE=release` removes transport exceptions, but distribution and production hosting are outside this version. Use a trusted Wi-Fi network for development traffic.

## Source and storage

- `main.jac`: authenticated API and per-account graph nodes.
- `core/catalog.jac`: service-owned catalog, searches, leases, quotas, and source health.
- `discovery/`: provider transport/parsers, employer directory, O*NET titles, and source configuration.
- `core/fixtures.jac`: legacy fictional jobs and sample networking contacts.
- `core/agents.jac`: deterministic demo progress based on persisted timestamps.
- `mobile/`: Jac screens, shared controls, and styles.
- `native/device.js`: SecureStore, authenticated transport, Files/PDF, gestures, notification reconciliation.
- `scripts/compile-mobile.jac`: stages Jac's native target and two runtime modules omitted by the beta scaffold. It uses compiler internals pinned to Jac 0.37.21.

Jac manages a persistent local PostgreSQL database in `.jac/tool-cache/pg/main` (the available PostgreSQL 16.14 was used on this Mac). Uploaded PDFs live in `storage/resumes/`, under account-specific directories. Both locations are ignored by Git. **Do not delete `.jac` as a routine clean:** it contains account data. To clean generated builds only, remove `.jac/mobile-rn` and `.jac/xcode-device`, then run setup again. Stop development services before backing up the database and storage together.

Every personal endpoint resolves ownership from the authenticated root, including PDF reads/deletes and reminder targets. Uploads are limited to 10 MB, must be parseable unencrypted PDFs, and are never public assets. Sessions use iOS SecureStore; sign-out clears PDF caches and scheduled/delivered notifications. The default Jac bootstrap-admin account is disabled for fresh installations.

Idempotent swipes and first-use seeding use a process lock and a refreshed database snapshot. This is deliberately a **single-process local backend**; multiworker/cloud execution would require a database-level uniqueness strategy before deployment.

## Verification

With `scripts/dev` running:

```sh
./scripts/jac check mobile main.jac
python3 tests/test_discovery.py
python3 tests/test_matching.py
PYTHONPATH=. python3 tests/test_timeline.py
JAC_TEST_JOBS=0 ./scripts/jac test tests/catalog_tests.jac
python3 tests/test_api.py
python3 tests/test_catalog_api.py
python3 tests/test_matching_api.py
node tests/native.cjs
```

The API suite creates separate test accounts and verifies authentication, ownership, simultaneous swipes, independent seeding, PDF validation, resume selection, drafts, and reminder CRUD. The native suite runs the actual compiled Jac screens and runtime with mocked iOS boundaries. It covers onboarding, tab navigation, filters, repeated apply input, swipe handling, deck exhaustion, PDF import/preview callbacks, reminders, permission denial, reconciliation, and sign-out. These tests do **not** certify native rendering or iOS notification delivery.

Jobs regression checks also cover the real swipe responder, immediate advancement while a save is pending, restoration after failed saves, direct employer links, source-text excerpts, and catalog-cache updates/expiry:

```sh
PYTHONPATH=tests:. python3 -m unittest tests/test_card.py tests/test_discovery.py tests/test_timeline.py tests/test_catalog_api.py tests/test_timeline_api.py
node tests/native.cjs
```

For a lightweight 390 × 844 visual preview of the actual compiled Jac screens, with native OS integrations stubbed:

```sh
npm install --prefix .jac/ui-preview --no-save react@19.2.3 react-dom@19.2.3 react-native-web@0.21.0 esbuild@0.25.0
node tests/preview.cjs
python3 tests/preview_server.py
# Open http://127.0.0.1:8128 and use a disposable test account.
```

The preview uses the real local backend and writes real account data. PDF, notification, and native-device behavior still require separate device checks. Preview credentials stay in memory and are cleared on reload.

Job cards show extracted employer text, not AI-written fit claims. Full descriptions load on demand. The shared catalog cache contains no account preferences; timeline matching is computed per authenticated request. Ingestion updates the cache after commit, with a five-minute fallback rebuild. Cold rebuilds may take several seconds; warm local searches measured 0.04–0.22 seconds in September 2026. Swipes advance locally while their writes are serialized; failed writes restore the card.

To verify actual server-restart persistence:

```sh
python3 tests/persistence.py prepare
# Stop scripts/dev with Ctrl-C and restart it, then:
python3 tests/persistence.py verify
```

See [the phone checklist](docs/PHONE_TESTING.md) for physical-device acceptance and [implementation notes](docs/IMPLEMENTATION.md) for beta workarounds and verification limits.
