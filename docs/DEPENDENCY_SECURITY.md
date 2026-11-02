# Dependency triage

Reviewed 2026-10-05 for publication, using the cleaned Git history. This is a
point-in-time review of the repository's declared dependencies and resolved
Python, web and native JavaScript environments. It does not scan a live host,
container base image, Chromium binary or installed iPhone, or deploy updates.

## Patched dependencies

| Dependency | Previous | Selected | Disposition |
| --- | --- | --- | --- |
| cryptography | 46.0.5 | 50.0.2 | Clears the six advisory groups affecting the old pin, including bundled OpenSSL. All API/browser/example manifests agree. |
| requests | 2.32.5 | 2.33.1 | Clears [GHSA-gc5v-m9x4-r6x2](https://github.com/advisories/GHSA-gc5v-m9x4-r6x2). |
| uuid | 7.0.3 | 11.1.1 | Native npm override clears [GHSA-w5hq-g745-h8pq](https://github.com/advisories/GHSA-w5hq-g745-h8pq) while retaining CommonJS support for Expo's `xcode` consumer. |
| react-router-dom / react-router | ^6.22.0 / resolved 6.x | 7.18.4 | Clears [GHSA-wrjc-x8rr-h8h6](https://github.com/advisories/GHSA-wrjc-x8rr-h8h6) and [GHSA-337j-9hxr-rhxg](https://github.com/advisories/GHSA-337j-9hxr-rhxg) in the web dependency declaration. |

Stack's account and browser encryption use Fernet with contiguous byte strings;
the reviewed application code does not invoke the affected certificate/PKCS#7
APIs. The Requests path is Google auth's HTTP transport; Stack does not call
`extract_zipped_paths()`. Updating removes the affected versions regardless of
those narrower application exposures. No encryption keys or stored data need
changing. See the [cryptography changelog](https://cryptography.io/en/latest/changelog/).

## Remaining native build-tool exceptions

`npm audit` changes from 27 affected package nodes (20 high, 7 moderate) to
20 high nodes, zero moderate/critical. The remaining nodes propagate from
**two underlying advisories**, not 20 independent vulnerabilities. Both upstream
advisories list no patched version as of the review date. These findings remain
visible in audit output; they have not been globally suppressed.

Owner: Stack maintainers. Recheck by **2026-11-04**, or immediately if upstream
publishes a patch or Stack changes these usage boundaries. Structured entries
are in [dependency-exceptions.json](dependency-exceptions.json).

| Advisory | Installed dependency and path | Application exposure and disposition |
| --- | --- | --- |
| [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm) | `braces@3.0.3`, through `expo → @expo/cli → @expo/metro-file-map → micromatch` and generated web React Native peers' Metro tooling | Deep attacker-controlled glob patterns can exhaust the build process stack. Reviewed Metro patterns come from project/build configuration, not uploaded resumes or API requests. Restrict build patterns/configuration to reviewed source; keep development Metro local. The checked iOS and web exports exclude this package. |
| [GHSA-86w9-cpqp-85rv](https://github.com/advisories/GHSA-86w9-cpqp-85rv) | `node-forge@1.4.0`, through Expo CLI and `@expo/code-signing-certificates` | RSA signature verification can accept crafted signatures. Reviewed consumers parse local Apple keychain certificates and sign/check locally generated development manifests. Stack does not use forge to verify account tokens, TLS or downloaded application updates; `expo-updates` and OTA code-signing configuration are absent. Use trusted local certificates, keep development signing local, and do not adopt forge for untrusted signature verification. The checked iOS export excludes this package. |

These are accepted, bounded tooling risks for publication, not claims that the
libraries are safe for arbitrary input. An untrusted PR can supply malicious
build configuration; run such builds without production signing credentials or
secrets. Reassess before enabling OTA updates, exposing Metro, or accepting
user-provided patterns/certificates. Upgrade the affected toolchain when a
compatible upstream patch becomes available. Do not use `npm audit fix --force`:
its offered Expo/React Native downgrades would replace the verified runtime.

## Validation and reproduction

- OSV: no advisories for the ten exact package/version combinations in the
  manifests, the 22 project-venv packages, or the 25 distributions resolved by
  the actual Jac API runtime.
- Web: the declared web-only manifest audit reports zero findings. Jac's full
  generated manifest also installs React Native peers; its audit reports nine
  high affected nodes from the same unpatched `braces` advisory. The actual web
  bundle excludes `braces` and `node-forge`, and uses the patched router. Bun's
  audit of the actual generated lockfile confirms only the same `braces` advisory.
- Native: clean `npm ci` with Node 22.22.0, Expo 57.0.25 and React Native 0.86.3;
  Expo iOS prebuild and Metro iOS export; UUID consumer and source-map checks.
- 99 focused offline Python tests in Jac 0.37.21 cover old encrypted data,
  browser checkpoints/expiry, Google auth transport, agents/browser behavior,
  release launchers, PDF limits and synthetic fixtures. The web bundle builds.
- Native Apple compilation/signing/install requires macOS/Xcode and was not
  performed on this Windows/Linux review host. Native library versions and the
  CocoaPods lockfile are unchanged.

Run the upgrade-specific checks from the repository root:

```sh
jac check tests/dependency_compatibility_tests.jac
jac test tests/dependency_compatibility_tests.jac -v
(cd native && npm ci --no-audit --no-fund && npm audit)
node tests/dependency-native.cjs
jac build --as client workspace
node tests/dependency-web.cjs
node tests/dependency-native.cjs .jac/client/workspace/dist
```

After generating the mobile workspace through the existing setup/compile
scripts, a release-configuration check can export its JavaScript without
connecting to a backend or signing/installing an app:

```sh
cd .jac/mobile-rn
STACK_BUILD_MODE=release STACK_API_URL=https://stack.example.com \
  node node_modules/expo/bin/cli prebuild --platform ios --no-install
STACK_BUILD_MODE=release STACK_API_URL=https://stack.example.com \
  node node_modules/expo/bin/cli export --platform ios --source-maps --no-bytecode \
  --output-dir /tmp/stack-dependency-export
cd ../..
node tests/dependency-native.cjs /tmp/stack-dependency-export
```

`--no-bytecode` makes this inspection export readable; it does not change the
production release launcher. `npm audit` still exits nonzero for the two scoped
exceptions. Continuous vulnerability CI and exception-expiry enforcement follow the work
tracked in [notes #11](https://github.com/matthewkooy2/notes/issues/11).

Continuous checks are now defined in [Security CI](SECURITY_CI.md), including
PR audits, daily scans, bounded exception enforcement and a deployment gate.
They become active when the workflow change reaches the default branch.

The first continuous scan on 2026-10-06 detected
[GHSA-68fv-2mgg-jv7q](https://github.com/advisories/GHSA-68fv-2mgg-jv7q)
in the native lockfile. Updating only `source-map-js` from 1.2.1 to 1.2.2
clears this new high-severity finding without adding an exception.
