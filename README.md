# AMP + AMP Dashboard Deployment Scripts

Image-only deployment scripts for **AMP** and **amp-dashboard**. This repo does
not build or contain application source code — it pulls pre-built container
images and runs them with Docker Compose. Traefik is optional.

## Layout

```
deploy/
  .env                              # your local config (not committed)
  .env.example                      # sample/reference config
  deploy.sh                         # main orchestrator script
  amp/docker-compose.yml            # AMP app + bundled AMP Postgres DB
  amp-dashboard/docker-compose.yml            # Dashboard stack
  amp-dashboard/docker-compose.traefik.yml    # optional Traefik overlay for dashboard
  traefik/docker-compose.yml        # optional shared Traefik stack
  backups/                          # local restore files (not committed)
```

`backups/` are git-ignored on purpose — they contain real database/upload data and must never be pushed to this
repository.

## Stacks at a glance

This repo manages three independent Docker Compose projects. `deploy.sh` can
target all of them together, or just one of the two application stacks.

| Stack | Compose file | Project name | Services | Included by default |
|---|---|---|---|---|
| **AMP** | `amp/docker-compose.yml` | `amp` | `amp-db` (Postgres), `amp` (app) | yes |
| **Dashboard** | `amp-dashboard/docker-compose.yml` (+ `docker-compose.traefik.yml` when Traefik is on) | `amp-dashboard` | `postgres`, `mysql`, dashboard app service(s) | yes |
| **Traefik** | `traefik/docker-compose.yml` | `traefik` | reverse proxy, fronts whichever of AMP/Dashboard is running | only if enabled (see below) |

AMP and Dashboard are fully independent: each has its own compose file, its
own database containers, and its own restore workflow. Traefik is a separate
concern from stack selection — it's a shared reverse proxy that can front
either or both stacks and is toggled independently (`--with-traefik` /
`--without-traefik`).

## Setup

1. Copy the sample env and fill in real values:
   ```
   cp .env.example .env
   ```
2. Edit `.env` with your image tags, domains, DB credentials, and (optionally)
   restore file paths.

## Usage

```
./deploy.sh deploy [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]   # pull images, start/update stacks
./deploy.sh up      [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]  # start/update stacks (no pull)
./deploy.sh down    [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]  # stop stacks (volumes kept)
./deploy.sh restart [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]  # down + up
./deploy.sh pull    [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]  # pull images only
./deploy.sh status  [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]  # show running containers
./deploy.sh logs <traefik|amp|dashboard|container> [service]
```

Traefik is optional and can be toggled via `--with-traefik` /
`--without-traefik`, or the `USE_TRAEFIK=true|false` env var. If neither is
set, Traefik is enabled automatically only when `traefik/docker-compose.yml`
exists.

### Deploying both stacks (default)

With no scope flag, every command acts on **AMP and Dashboard together**:

```
./deploy.sh deploy
```

This pulls both sets of images, brings up `amp-db` then `amp`, waits for and
initializes the AMP DB (restore + site domain update), then brings up
`mysql`/`postgres` then the dashboard app, waits for and initializes the
dashboard DBs (restores + uploads).

### Deploying only AMP

Use `--amp-only` (or `DEPLOY_TARGET=amp` in `.env`) to skip the dashboard
stack entirely — the dashboard compose file isn't required to exist, no
dashboard images are pulled, no dashboard containers are started/stopped, and
no dashboard restores run:

```
./deploy.sh deploy --amp-only
# or persist it:
echo 'DEPLOY_TARGET=amp' >> .env
./deploy.sh up
```

### Deploying only the Dashboard

Use `--dashboard-only` (or `DEPLOY_TARGET=dashboard` in `.env`) to skip AMP
entirely — the AMP compose file isn't required to exist, no AMP images are
pulled, `amp-db`/`amp` are never started or stopped, and the AMP DB
restore/site-domain update never runs:

```
./deploy.sh deploy --dashboard-only
# or persist it:
echo 'DEPLOY_TARGET=dashboard' >> .env
./deploy.sh up
```

### Precedence

A CLI flag always overrides `.env`. If neither is set, both stacks are
deployed (`DEPLOY_TARGET=all`):

```
CLI flag (--amp-only / --dashboard-only)  >  DEPLOY_TARGET in .env  >  default "all"
```

Note: `down`, `restart`, `pull`, and `status` respect the same scope — e.g.
`./deploy.sh down --amp-only` stops only the AMP stack and leaves the
dashboard (and Traefik) running untouched. `./deploy.sh logs` is always
stack-scoped by its own `<amp|dashboard|traefik|container>` argument,
regardless of `DEPLOY_TARGET`.

## Restores

Restores (AMP Postgres, dashboard Postgres, dashboard MySQL, dashboard
uploads) are opt-in and require explicit backup file paths in `.env`:

- `AMP_DB_BACKUP_FILE` — only applies when AMP is included (`all` or `amp`)
- `DASHBOARD_POSTGRES_BACKUP_FILE` — only applies when Dashboard is included (`all` or `dashboard`)
- `DASHBOARD_MYSQL_BACKUP_FILE` — only applies when Dashboard is included (`all` or `dashboard`)
- `DASHBOARD_UPLOADS_SOURCE` — only applies when Dashboard is included (`all` or `dashboard`)

If a path is left unset, that restore step is skipped. When running from an
interactive terminal, the script asks for confirmation before each configured
restore. For non-interactive runs (CI/cron), set `ASSUME_YES_RESTORE=true` to
auto-approve.

## Notes

- This repo is consumed as a git submodule (`deploy/`) from the main `amp`
  repository.
- Restores use direct `docker exec` commands against the running DB
  containers and are non-fatal — a failed restore logs a warning and
  deployment continues.

