# PC host source checkpoint

This directory captures the PC code that complements the Mac source checkpoint on
`codex/mac-pc-source-checkpoint-20261001`. It records source for review and recovery;
it does not install, update, or operate a host automatically. No CI or deployment
automation was created.

The root `jac.toml` retains the Mac mobile app, iOS configuration, and resume-ticket
indexes, with the PC Python/server-web dependencies added using the existing
dependency tables. `server-web.jac.toml.example` records the deployed PC's
server-only variant. Do not replace the Mac's root configuration with that example.
`jac-server` records the PC's launcher; retain the SSD-aware root `scripts/jac` on
the Mac. Runtime secrets and dependency environments must be supplied separately.

## Captured source

- `stack-browser-prepared/browser_runtime.py` and `browser_policy.py` match the
  installed controller/policy. The captured seccomp profile matches the installed
  profile. The controller retains the launch gate, container-only egress filtering,
  non-root browser, read-only root, and browser session/authentication boundaries.
- The reviewed installer, preflight/permission guards, network/package preparation
  source, attended wrappers, and offline tests preserve the PC implementation and
  installer fixes. The official Docker public repository key and public package
  version/checksum metadata are included; no private key is included.
- The current installed API, gateway, worker, and browser units are captured under
  `installed-unit-templates/`. Their environment-file references are paths only;
  actual environment/configuration files are excluded. `browser.env.example`
  contains placeholders, not the active browser credentials.
- The image/application context already exists in the repository under `agents/`,
  `deploy/`, and `discovery/`; its relevant source was checked against the PC
  prepared context. No duplicate context or image layers are included.
- `deploy_reviewed_backend.py` captures the reviewed seven-file backup/deploy/
  rollback transaction used for the resume update. Its two source-hash input
  snapshots are included for provenance. It is checkpoint-specific: it references
  the original local handoff/candidate paths and output files. Do not execute it
  from this checkout or treat its original pre-deployment baseline as a current
  host baseline.

`SOURCE_CAPTURE.json` lists exact captured source hashes. Source files remain
unchanged apart from this packaging/documentation and the combined root dependency
declarations. Historical installer checkpoint gates and attended wrapper paths are
retained as evidence, not silently generalized into an unattended installer.

## Focused offline validation

Use a disposable copy of this directory on Linux. From its
`stack-browser-prepared` subdirectory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_browser_install_offline
PYTHONDONTWRITEBYTECODE=1 python3 test_attended_wrapper_offline.py
```

These suites mock container/service/privileged operations, exercise egress and
startup/rollback guards, and replace sudo with a fixture. They do not establish
fresh-host installation or real phone/browser/account acceptance. The separate
Postgres preflight tests require an unprivileged Linux user and a private throwaway
Postgres 16 instance; never point them at the live database.

## Recovery and reproduction limits

Do not rerun these historical installers on the working PC. The attended wrapper
contains its original task path; the preparation tool contains its original source
snapshot path. Installer, context, package, network, and approval manifests must be
freshly generated and reviewed against the intended source/host before any new
installation. Current route selections, browser image ID/layers, container state,
source/database/storage backups, private operator configuration, credentials,
browser sessions, signing assets, and generated mobile/web output are intentionally
not committed. This source checkpoint cannot restore those assets by itself.

The deployed PC backend has the durable resume-processing lane. Its previous
seven-file source plus verified database/storage backups remain locally on the PC.
Source rollback after new uploads must preserve accepted files and tickets; do not
restore an older database/storage snapshot blindly. Mac signing and physical
iPhone acceptance require the separate authorized Mac build workflow.
