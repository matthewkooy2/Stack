# Stack VM deployment

Run the same Stack runtime image on the staging and production Ubuntu VMs.
It carries the pinned Jac and Python dependencies, compiled web assets, and
Compose definition. PostgreSQL runs in a separate local container. Take a
PostgreSQL backup and an upload backup before database changes.

## Host layout

- Install Docker Engine with the system-wide Compose plugin and enable Docker at boot.
- Install `deploy/apply-image` as root-owned `/usr/local/sbin/stack-apply-image`.
  Set up a separate restricted SSH key for each VM. The forced receiver accepts
  only `stack-image-release sha256:<digest>` and calls the root-owned script with
  that digest as one argument. It passes the registry credentials on standard
  input as two lines, the workflow's GitHub username and temporary token.
- Write `/etc/stack/compose.env` with a distinct, URI-safe `STACK_DB_PASSWORD`
  for each VM. Use `openssl rand -hex 32` for a fresh database. The PostgreSQL
  volume is named `stack_postgres`; changes to the env file alone do not reset an
  existing database password.
- Write private `/etc/stack/{api,gateway,worker,discovery}.env` files. Use
  `deploy/{api,worker,discovery}.env.example` for the applicable values.
  Compose supplies `JAC_DB_URL`, `STACK_WORKER_API` and the listener addresses.
  Put `STACK_SSO_HOST` and `STACK_SSO_CALLBACK_URL` in both API and gateway
  settings when configuring Google sign-in. Put Apple settings in API settings.
- Create `/var/lib/stack/storage` with mode 0700 owned by UID/GID 10001. It
  contains uploads and private configuration. Use
  `deploy/agent-config.example.json` for `agents/config.json` and create
  private `agents/worker-token` and `discovery/worker-token` files. Match the
  agent worker token in API/worker settings if populated in the environment.
  Keep the original auth and encryption keys with any restored staging accounts.
- Point each VM's own Cloudflare Tunnel to `http://127.0.0.1:8080`. The API
  and PostgreSQL ports stay inside the Compose network.

## Release

The previous source deployment uses `STACK_RELEASE_FORMAT=3`. Set the repository
variable to `4` after the VM receivers, private settings, and registry access are
ready.

A successful CI push to `main` builds and publishes a runtime image to
`ghcr.io/matthewkooy2/stack-runtime`, then deploys by digest to staging. The
existing Tailscale federation is scoped to the `stack-production` GitHub
environment. Both VM deploy jobs use that transport environment with different
SSH keys and forced relay accounts. Store the new keys there as
`STACK_STAGING_VM_SSH_KEY` and `STACK_PRODUCTION_VM_SSH_KEY`.

Open the successful staging run and copy its run ID. After testing staging, the
repo owner can dispatch **Release Stack VM image** on `main` with `production`
and that run ID. The job retrieves the recorded staging digest and promotes that
same image. For a rerun of current `main`, the manual `staging` dispatch uses a
successful CI result for that exact commit.

The receiver waits for the database, API and web gateway before recording the
active release under `/opt/stack-deploy/current`. If an update fails its
readiness checks, it applies the last successful release. Database restores
and major-version upgrades are separate operations.

## Operations

Run these from a root shell on the selected VM to inspect the active deployment.

```sh
export STACK_IMAGE=$(cat /opt/stack-deploy/current/image)
docker compose --env-file /etc/stack/compose.env -f /opt/stack-deploy/current/compose.yaml ps
docker compose --env-file /etc/stack/compose.env -f /opt/stack-deploy/current/compose.yaml logs --tail 100
```

Run `docker compose` with the same arguments and `--profile jobs run --rm jobs`
for an attended catalog sweep. Configure a timer on the designated collection
host if scheduled collection is needed.

Copy logical PostgreSQL backups and durable uploads to the chosen off-host
destination. A restore drill needs a separate environment and the relevant
runtime configuration, credentials, and encryption keys.


## Initial data transfer

Use `deploy/remap-stack-namespace.sql` only on a restored database while the
application is stopped. Jac derives its typed graph namespace from the
absolute `main.jac` path. Supply the source and destination application
namespaces as `source_namespace` and `destination_namespace`.

For a fresh production database, use `deploy/export-shared-catalog.sql` to
export the shared catalog and `deploy/import-shared-catalog.sql` after the
target API has initialized its guest root. Run the import with `psql -f` and
pass the CSV on standard input. Set `catalog_module` to the destination
application namespace followed by `.core.catalog`. This transfers the shared
listings and catalog metadata without transferring user accounts or uploads.
