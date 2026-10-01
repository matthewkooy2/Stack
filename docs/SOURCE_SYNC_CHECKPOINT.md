# Source synchronization checkpoint

This checkpoint captures the verified Mac source based on `def5e9d34fa9d399630d088fca667ebe05711215`, plus the exact PC browser-input return patch. It is an incremental branch above `codex/integrate-agent-features`. Main has a separate merge commit and has not been changed by this checkpoint.

## Captured source

- Durable resume processing: persisted tickets, accepted-upload replay handling, independent worker processing, stage timings, retry and reopen status, stale-lease protection and source/preview replacement handling.
- iPhone upload progress and processing UI, with existing review/tailoring flows retained.
- The returned PC web browser typing/paste implementation and merged native/web UI tests.
- Mac release configuration, no-APNs defaults, bundled HTTPS launcher, pinned native dependency files, Jac 0.37.21 selection and SSD-aware cache/temp paths.
- Service/environment examples and WSL/hosting documentation that were already prepared on the Mac. These are templates, not a record of every live PC setting.

## PC source still needed

The running PC checkout is not a Git checkout. Its full `combined-pc-source.zip`, deployment plan and integration result have not been materialized on the Mac. This checkpoint must not be treated as complete PC synchronization. Before declaring both hosts captured, obtain a source-only export and reconcile:

- The separate `browser_runtime.py` implementation deployed under `/usr/local/libexec/stack-browser/`, including the PC runtime fixes. The repository browser service implementation is not a substitute for this file.
- PC-specific `jac.toml` server/web dependency configuration. The Mac mobile configuration and compiler pin must be preserved while combining those settings.
- Live deployment/startup source, service unit variants, browser image/dependency specifications, seccomp/egress policy and non-secret configuration templates that differ from the repository versions.
- The source changes and file manifests described by the PC deployment plan/integration result. Review them before copying; do not copy live operator environment values, credential stores or state.

Preserve the live PC API/gateway/worker/browser configuration and state while doing this comparison. Importing source into Git does not authorize deploying or replacing the working services.

## Validation evidence

The captured source passed focused upload/tailoring UI, native LinkedIn/browser controls, web ordered-input and release configuration checks. Earlier isolated checks passed eight durable resume lifecycle tests, six review/tailoring workflow tests, seventeen LaTeX tests and the gateway boundary test.

A resource-guarded serial Release build succeeded with one native job and one JavaScript worker, the existing signing identity/profile, the configured private HTTPS origin and APNs disabled. The updated app installed over USB and launched. The user confirmed their account data was present and continued functional testing independently. No new native build or deployment belongs to this Git checkpoint.

## Exclusions and next phase

Account/resume storage, databases/backups, credentials/session files, completed operator environment files, runtime/generated build output and signing assets are excluded. Private live endpoint values stay in operator configuration; examples use placeholder origins. Local hardware identifiers and one-off build-state notes are not published here.

After the missing PC source is reconciled, review the complete branch and decide how to incorporate it into main. CI/CD workflows, service deployments, signing automation and a main merge are separate follow-up work; none is enabled by this checkpoint.
