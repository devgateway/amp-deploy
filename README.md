# AMP + AMP Dashboard Deployment Scripts

Image-only deployment scripts for **AMP** and **amp-dashboard**. This repo does
not build or contain application source code — it pulls pre-built container
images and runs them with Docker Compose. Traefik is optional.

## Layout

```
deploy/
  .env                              # your local config (not committed)
  .env.example                      # sample/reference config
  deploy.sh                         # main orchestrator script (deploy/up/down/restore)
  backup.sh                         # backup script for AMP + Dashboard data
  reinstall.sh                      # reinstall/upgrade script (keep or wipe data)
  amp/docker-compose.yml            # AMP app + bundled AMP Postgres DB
  amp-dashboard/docker-compose.yml            # Dashboard stack
  amp-dashboard/docker-compose.traefik.yml    # optional Traefik overlay for dashboard
  traefik/docker-compose.yml        # optional shared Traefik stack
  backups/                          # local backup/restore files (not committed)
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

## Backups

`backup.sh` creates backups for **AMP and Dashboard separately** (or both at
once), in formats that plug directly into the restore variables below.

| Target | What gets backed up | Output file |
|---|---|---|
| AMP | Postgres database (`AMP_DB_NAME`) | `backups/amp-db_<timestamp>.dump` |
| Dashboard | Postgres `viz` database | `backups/dashboard-postgres_<timestamp>.dump` |
| Dashboard | MySQL `wordpress` database | `backups/dashboard-mysql_<timestamp>.sql` |
| Dashboard | `wordpress` uploads volume | `backups/dashboard-uploads_<timestamp>.tar.gz` |

```
./backup.sh                    # back up AMP + Dashboard (DBs + dashboard uploads)
./backup.sh --amp-only         # back up AMP only
./backup.sh --dashboard-only   # back up Dashboard only (DBs + uploads)
./backup.sh --db-only          # skip the dashboard uploads volume
./backup.sh --uploads-only     # only back up the dashboard uploads volume
./backup.sh --keep 14          # prune backups older than 14 days (default: 30, 0 = keep all)
./backup.sh --dest /path/to/dir
```

Each run requires the relevant containers to already be running (it uses
`docker exec`/`docker run` against the live stack, no downtime needed). At
the end it prints the exact `.env` lines to set so `deploy.sh`'s restore step
can pick up the new backup:

```
AMP_DB_BACKUP_FILE=backups/amp-db_20260729_020000.dump
DASHBOARD_POSTGRES_BACKUP_FILE=backups/dashboard-postgres_20260729_020000.dump
DASHBOARD_MYSQL_BACKUP_FILE=backups/dashboard-mysql_20260729_020000.sql
DASHBOARD_UPLOADS_SOURCE=backups/dashboard-uploads_20260729_020000.tar.gz
```

To automate, add to crontab, e.g. nightly at 2am:
```
0 2 * * * /opt/amp/deploy/backup.sh >> /var/log/amp-backup.log 2>&1
```

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

After the dashboard DB steps run (on every `deploy`/`up`, including via
`reinstall.sh`), `deploy.sh` also updates WordPress's site URL to match
`DASHBOARD_DOMAIN`, equivalent to:

```sql
UPDATE wp_options SET option_value = 'https://<DASHBOARD_DOMAIN>/wp' WHERE option_name = 'siteurl';
UPDATE wp_options SET option_value = 'https://<DASHBOARD_DOMAIN>' WHERE option_name = 'home';
```

and then prints the result of:

```sql
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');
```

This only runs when Dashboard is included (`all` or `dashboard`) and is
skipped with a warning if `DASHBOARD_DOMAIN` is unset.

## Reinstall / Upgrade

`reinstall.sh` handles both routine upgrades and full reinstalls, for AMP and
Dashboard **independently** via the same `--amp-only`/`--dashboard-only`
scoping used elsewhere. It delegates image pulling and container startup to
`deploy.sh deploy`, so restores configured in `.env` still apply afterward.

| Mode | What happens | Data impact |
|---|---|---|
| `--keep-data` (default) | Pulls latest images, recreates containers via `deploy.sh deploy` | Named volumes (DBs, uploads) untouched — safe in-place upgrade |
| `--wipe-data` | Backs up (unless `--skip-backup`), stops the stack and removes its named volumes, then pulls fresh images and redeploys from scratch | **Destructive** — databases/uploads for the selected stack are deleted before redeploying |

```
./reinstall.sh                              # upgrade in place: AMP + Dashboard (keep data)
./reinstall.sh --amp-only                   # upgrade AMP only, keep its data
./reinstall.sh --dashboard-only             # upgrade Dashboard only, keep its data

./reinstall.sh --wipe-data --amp-only       # fresh reinstall of AMP only (prompts to confirm)
./reinstall.sh --wipe-data --dashboard-only # fresh reinstall of Dashboard only
./reinstall.sh --wipe-data                  # fresh reinstall of BOTH (prompts once per stack)

./reinstall.sh --wipe-data --yes            # skip the interactive confirmation prompt
./reinstall.sh --wipe-data --skip-backup    # skip the automatic pre-wipe backup (not recommended)
```

`--wipe-data` only removes the named volumes declared in that stack's own
compose file (`amp/docker-compose.yml` for AMP, `amp-dashboard/docker-compose.yml`
for Dashboard) — wiping AMP never touches Dashboard's databases/uploads, and
vice versa. Traefik is never wiped (it holds no application data).

Because `--wipe-data` is destructive, it always requires confirmation — type
`wipe AMP` / `wipe Dashboard` when prompted, or pass `--yes` (or set
`ASSUME_YES_WIPE=true` for non-interactive/CI use, mirroring
`ASSUME_YES_RESTORE`). By default it also runs `backup.sh` (scoped to the
same target) before wiping, and aborts the wipe if that backup fails; use
`--skip-backup` to bypass this safety net.

## Notes

- This repo is consumed as a git submodule (`deploy/`) from the main `amp`
  repository.
- Restores use direct `docker exec` commands against the running DB
  containers and are non-fatal — a failed restore logs a warning and
  deployment continues.

