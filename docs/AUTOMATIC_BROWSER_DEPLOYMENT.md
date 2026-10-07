# Automatic isolated-browser deployment

The prepared [MAT-30 health and rollback protocol](DEPLOYMENT_HEALTH_ROLLBACK.md)
adds browser smoke and recovery gates after attended bootstrap; the historical
activation details below do not establish those gates on the current host.

The existing main-only GitHub workflow packages matching backend and browser
source from one exact commit. The PC builds a browser image only when its
curated browser application files change. Ordinary backend changes retain the
current browser container and its in-memory sessions. This extension adds no CI
test suite, application health gate, automatic rollback, registry credential,
Docker socket access for the deploy account, or GitHub token permission.

## Source-only builds and retained security

The artifact remains bounded to 64 MiB compressed and expanded. Format 2 adds a
separate browser context containing six existing application files plus optional
`agents/browser_control.py` and `agents/browser_stream.py`. Shared modules must
be byte-identical in backend and browser payloads. Format 1 remains readable for
review/preparation; a browser-enabled host rejects format 1 deployment.

The browser image derives from the immutable, already installed and reviewed
Linux image. A fixed trusted Dockerfile adds only `COPY` layers and retains user
`pwuser`; it has no `RUN`, downloads, secrets, mounts or release-defined hooks.
Builds use a root-only context, a separate empty Docker client configuration,
`--pull=false`, and `--network=none`. The base must have no `ONBUILD` hooks or
embedded service/session keys. Image layer ancestry and source labels are checked
before cutover. Docker documents the distinction between [COPY and RUN](https://docs.docker.com/reference/dockerfile/)
and [build networking](https://docs.docker.com/reference/cli/docker/buildx/build/#network).

An attended baseline pins the base image, currently selected image, six build/
dependency/security source hashes, curated application hashes and protected host
file hashes. Changes to the Dockerfile, browser Jac manifest, entrypoint,
installation script, requirements or seccomp source stop before any service is
stopped and require a separate review of the runtime base. Deleting browser source
also requires review. Unexpected host controller, policy, unit, network, private
environment or image-pointer changes stop promotion; independent work is retained.

The installed custom controller is never replaced. It continues to enforce
nonroot/read-only operation, no private mounts, container-only egress filtering,
seccomp, quotas, IPv6 restrictions, authentication/session keys, and its existing
security launch gate. Those startup security checks are retained behavior, not
new CI tests or post-deployment application health gates.

## Promotion and failure handling

Under the existing host deployment lock, prepare parser dependencies and build a
candidate browser image before stopping services. Stop gateway/worker/API; if
browser source changed, stop the browser through its existing systemd controller.
Install matching backend source and dependencies, update its source baseline,
then atomically set the reviewed image pointer and browser baseline. Start browser
when changed, then API/worker/gateway. Record commit, artifact digest, browser
image and source fingerprint in root-owned `last-release.json`.

No application readiness is inferred from start-command success. A command failure
fails the workflow and may need an attended correction; there is no automatic
rollback. Old source, parser dependencies, image identity and browser baseline are
retained in the private source backup. Docker images are retained without pruning.
No database/storage snapshot is restored. Browser restarts lose in-memory browser/
login contexts; users must recover control after the process instance changes.

## Exact approval and one-time bootstrap

As of the 2026-10-02 preparation, live source has 68 tracked files, all matching
its deployed baseline. API/worker/gateway/browser are running. The browser image is
`sha256:799e4c02800469a3469c55f128b5b694796748af48d0cdfa8b12810ba2131522`;
its six application files match current main. Its controller/policy/seccomp/unit
match the preserved public checkpoint. No browser deployment baseline or new
permission has been activated by this preparation.

Review and approve this narrowly scoped extension before publishing/merging or
changing host authority:

1. Update the fixed root-owned deployment modules: `backend_release.py`,
   `promote_backend.py`, and new `browser_package.py` / `browser_release.py` under
   `/usr/local/libexec/stack-release`. Retain the forced SSH command, existing
   launcher, narrow no-argument sudoers entry, private keys and route grants.
   Existing `receive_backend.py` needs no behavioral change.
2. Expand **only that fixed helper's behavior** to inspect/tag/build local
   source-only Docker images, atomically write `/etc/stack/browser-image-id`
   and `/var/lib/stack-release/browser-state.json`, and stop/start only the existing
   `stack-browser.service` during matching source promotion. This is new persistent
   deployment authority even though the sudoers command spelling is unchanged.
   Do not add either `stack` or `stack-deploy` to the Docker group or grant arbitrary
   Docker/shell/sudo commands.
3. Prepare an exact format-2 release from this extension branch's committed tree,
   with its parser built from that checkout. Run `prepare_browser_state.py` as an
   attended read-only inspection with explicit artifact/commit/digest/output.
   It compares application/config source inside the existing read-only container
   and emits a new review file. It never installs, builds, restarts or enables.
4. Review and install that baseline as root-owned mode 0600 at
   `/var/lib/stack-release/browser-state.json`. Back up the prior trusted helpers
   and access file locally. Add `automatic_browser_deploy: true` to the existing
   `/etc/stack-release/access.json`, preserving `automatic_main_deploy` and any
   other keys. Existing GitHub variables/secrets/Tailscale access stay unchanged.
5. Publish/merge the extension branch. Its main push runs the existing workflow
   once. Because main's browser source is unchanged, this initial extension release
   must report `browser_rebuilt: false` and retain the original browser image/start
   timestamp. Verify exact installed commit/source and ordinary command outcomes.
   Keep the user's $0/Stop usage cap; do not enable paid minutes if blocked.

These are preparation instructions, not an unattended bootstrap installer. An
operator supplies any required sudo/password locally; warn before opening a prompt.
Do not rerun historical browser installation scripts or copy old runtime bundles.

## Preparation validation

Local package validation built the parser with pinned Node 22.22.0 from the exact
extension and Mac feature checkouts, produced deterministic format-2 archives,
verified 68/70 backend and six/eight browser files, rejected forbidden context
paths and mismatched commits, and confirmed the viewer runtime contract is unchanged.
Seven offline transaction scenarios mocked Docker/npm/Jac/service commands: unchanged
browser source skipped build/restart; viewer source promoted both components in
order; source/runtime/image/contract conflicts and a candidate build failure stopped
before service changes; current data stayed intact. Actual image building and Linux
browser behavior remain to be verified during the approved rollout, not inferred
from these mocked checks. The read-only baseline tool also compares the live image
source and pinned runtime inputs; it handles Docker's `CAP_` capability spelling.

## Coordinated viewer rollout

PR12 `codex/shared-browser-viewer`, feature commit
`b0231c522d7aa68207c771c2f8053a497d04c553`, remains separate and unmerged during
preparation. It adds two backend/browser Python modules and v2 browser authority.
Backend source grows from 68 to 70 files; browser application context grows from
six to eight. Runtime dependencies and security source are unchanged.

Before merging PR12, reconnect/authorize the Mac and ensure the already signed
feature app and physical iPhone are ready for installation in the same interruption
window. Old apps cannot issue v2 browser writes. Do not deploy this feature while
the new client is unavailable, and do not add a legacy authority bypass.

Once authorized and ready, merge PR12 onto the deployment extension's main. The
single resulting workflow builds its matching source-only browser image before
stopping services and promotes both components together. Verify `last-release.json`,
70 backend hashes, image labels/pointer and service restart timestamps. Then install
the reviewed signed feature app from the Mac. Physical iPhone streaming, keyboard,
gesture and control checks remain separate authorized acceptance work. Web asset
publishing is also a separate step if the web viewer is required.
