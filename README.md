# amp-deploy

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

`.env` and `backups/` are git-ignored on purpose — they contain real
credentials and real database/upload data and must never be pushed to this
repository.

## Setup

1. Copy the sample env and fill in real values:
   ```
   cp .env.example .env
   ```
2. Edit `.env` with your image tags, domains, DB credentials, and (optionally)
   restore file paths.

## Usage

```
./deploy.sh deploy [--with-traefik|--without-traefik]   # pull images, start/update stacks
./deploy.sh up      [--with-traefik|--without-traefik]  # start/update stacks (no pull)
./deploy.sh down    [--with-traefik|--without-traefik]  # stop stacks (volumes kept)
./deploy.sh restart [--with-traefik|--without-traefik]  # down + up
./deploy.sh pull    [--with-traefik|--without-traefik]  # pull images only
./deploy.sh status  [--with-traefik|--without-traefik]  # show running containers
./deploy.sh logs <traefik|amp|dashboard|container> [service]
```

Traefik is optional and can be toggled via `--with-traefik` /
`--without-traefik`, or the `USE_TRAEFIK=true|false` env var. If neither is
set, Traefik is enabled automatically only when `traefik/docker-compose.yml`
exists.

## Restores

Restores (AMP Postgres, dashboard Postgres, dashboard MySQL, dashboard
uploads) are opt-in and require explicit backup file paths in `.env`:

- `AMP_DB_BACKUP_FILE`
- `DASHBOARD_POSTGRES_BACKUP_FILE`
- `DASHBOARD_MYSQL_BACKUP_FILE`
- `DASHBOARD_UPLOADS_SOURCE`

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
