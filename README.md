# AMP + AMP Dashboard Deployment Scripts

Deploy **AMP** and **amp-dashboard** using pre-built container images and
Docker Compose. Traefik is optional.

## Layout

```
deploy/
  .env                              # your local config
  .env.example                      # sample/reference config
  deploy.sh                         # main orchestrator script (deploy/up/down/restore)
  install-windows.sh                # Windows/WSL setup and deployment helper
  backup.sh                         # backup script for AMP + Dashboard data
  reinstall.sh                      # reinstall/upgrade script (keep or wipe data)
  amp/docker-compose.yml            # AMP app + bundled AMP Postgres DB
  amp-dashboard/docker-compose.yml            # Dashboard stack
  amp-dashboard/docker-compose.traefik.yml    # optional Traefik overlay for dashboard
  traefik/docker-compose.yml        # optional shared Traefik stack
  backups/                          # local backup/restore files
```

Backups contain database and upload data; store them securely.

## Stacks at a glance

The deployment uses three independent Docker Compose projects. `deploy.sh`
can target all of them together, or just one of the two application stacks.

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

## System Requirements

### Platform and Software

- A 64-bit Linux host or VM with an architecture supported by all selected
  container images. Verify image availability before using ARM hosts.
- Docker Engine with Linux containers, the Docker Compose plugin, and Bash.
  The setup example below uses Ubuntu 22.04 or 24.04.
- `curl` and `unzip` for the default AMP ECR image's AWS CLI setup. The
  deployment user needs access to Docker and write access to the deployment,
  log, and backup directories.
- On Windows 10/11, use WSL 2 and Docker Desktop. For Windows Server, use a
  Linux VM for production as described below. WSL 2 and VMs require
  virtualization support; WSL 2 inside a VM requires nested virtualization.

### Capacity

The application handover guides provide the following **separate** host sizing
guidance. These figures have not been verified for this deployment:

| Application | Minimum | Recommended for production |
|---|---|---|
| AMP | 4 CPU cores, 8 GB RAM, 50 GB disk | 8 CPU cores, 16 GB RAM, 100 GB SSD |
| Dashboard | 4 CPU cores, 8 GB RAM, 40 GB disk | 8 CPU cores, 16 GB RAM, 100 GB SSD |

For both stacks on one host, start planning with **8 vCPUs, 32 GB RAM, and
200 GB SSD**, plus space for databases, uploads, and backups. This is an
untested estimate, not a verified minimum or production guarantee. Actual
needs depend on data size, traffic, images, and retention; monitor usage and
adjust after testing.

The Compose file passes `AMP_JVM_HEAP=4g` by default, but the available AMP
image source hard-codes an 8 GB maximum JVM heap and does not read that
variable. The deployed image may differ: verify its effective `-Xmx` setting
with `docker top amp` after startup, and do not assume changing
`AMP_JVM_HEAP` changes the heap unless the image supports it. Allow additional
memory for the databases, other services, and operating system.

### Network and Data

- Outbound HTTPS access to the configured image registries, including Docker
  Hub and, for the default AMP image, AWS ECR. Registry credentials must permit
  pulling the selected images. SMTP access is needed if outbound mail is used.
- Available host ports: `8080` for AMP and `8081` for Dashboard by default;
  Traefik also uses port `80` when enabled. Permit access through the firewall
  only as needed and configure DNS and HTTPS for the intended deployment.
- Existing database backups for the selected stacks when deploying to empty
  volumes, as described in the setup and restore instructions below. Keep
  credentials and backups secure.

## Setup

### Linux Host (Ubuntu)

Run the following commands in an Ubuntu terminal, or connect to the host using
SSH. This example assumes a fresh Ubuntu 22.04 or 24.04 host with `sudo`
access. For other Linux distributions, follow the
[Docker Engine installation guide](https://docs.docker.com/engine/install/)
for your distribution, install `curl`, `unzip`, and a text editor, then
continue at step 2. Allow enough memory and disk for the selected stacks; see
[Capacity](#capacity).

#### 1. Install Docker

Install Docker Engine, Docker Compose, and the other required tools:
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip nano
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```
If Docker is already installed, verify that it includes the Compose plugin
instead of reinstalling it.

#### 2. Verify Docker Access

Ensure your user can run Docker without `sudo`. If needed, add your user to
the Docker group and then sign out and reconnect before continuing:
```bash
sudo usermod -aG docker "$USER"
```
Membership in the Docker group grants root-equivalent privileges. Verify
Docker access and the Compose plugin after reconnecting:
```bash
docker info
docker compose version
```

#### 3. Prepare the Deployment Files

Copy the deployment files to the host, including `.env.example`, the shell
scripts, and the `amp`, `amp-dashboard`, and `traefik` directories. Ensure
the deployment user can write to the directory. For example, if the files
are in `~/amp/deploy`:
```bash
cd "$HOME/amp/deploy"
chmod u+x deploy.sh backup.sh reinstall.sh
if [ ! -e .env ]; then (umask 077; cp .env.example .env); fi
chmod 600 .env
nano .env
```
Use the actual directory if it is different. The copy command preserves an
existing `.env`; edit it instead of replacing it.

#### 4. Configure the Deployment

In `.env`, set the image tags and registry credentials, replace the sample
database passwords, and set the URLs users will access. For the default ECR
AMP image, provide `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_DEFAULT_REGION`. Set `DASHBOARD_REGISTRY_USER` and
`DASHBOARD_REGISTRY_PASSWORD` if the dashboard registry requires them.
The deploy script installs the AWS CLI if needed.

For direct access without Traefik, set `USE_TRAEFIK=false`,
`AMP_SITE_DOMAIN` to the actual host and port (for example,
`amp.example.com:8080`), and `DASHBOARD_SITE_URL` to the full WordPress URL
(for example, `http://dashboard.example.com:8081/wp`). Configure DNS and
firewall access for the selected ports. Use HTTPS through a suitably
configured reverse proxy for public access.

On empty volumes, configure `AMP_DB_BACKUP_FILE` with a populated PostgreSQL
custom-format dump and `DASHBOARD_MYSQL_BACKUP_FILE` with a populated
WordPress SQL dump for the selected stacks. Paths can be absolute Linux
paths or relative to the deployment directory. Confirm the restore prompts
when asked. See [Restores](#restores) for additional restore options.

The `.env` file is sourced by Bash, so quote values when necessary and use
LF line endings. Protect credentials and backups.

#### 5. Deploy

Pull the images and start both stacks without Traefik:
```bash
./deploy.sh deploy --without-traefik
```
Add `--amp-only` or `--dashboard-only` to deploy one stack. If Traefik is
configured for the host, use `--with-traefik` instead of
`--without-traefik`.

#### 6. Check the Deployment

Check the containers and follow logs if needed:
```bash
./deploy.sh status --without-traefik
./deploy.sh logs amp
./deploy.sh logs dashboard
```
Use the same stack and Traefik flags with `status` as with `deploy`. With
Traefik disabled and the default ports, open the configured host on ports
`8080` for AMP and `8081` for Dashboard. Wait for services to finish
starting; press `Ctrl+C` to stop following logs.

### Windows Server

Docker Desktop is [not supported on Windows Server](https://docs.docker.com/desktop/setup/install/windows-install/).
For production, run a Linux VM on the server, install Docker Engine and the
Docker Compose plugin in the VM, and follow [Linux Host (Ubuntu)](#linux-host-ubuntu).
Configure the VM and Docker to start automatically,
and allow access to the required ports through the VM and server firewalls.

Windows Server 2022 and 2025 also support [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/install-on-server),
with Docker Engine installed inside the Linux distribution. This alternative
has not been tested here and requires separate startup and networking setup.

### Windows 10/11 (WSL 2)

The stacks run as Linux containers. On Windows 10/11, use WSL 2 and Docker Desktop;
the scripts are run in the Linux distribution, not in PowerShell or Git Bash.

1. In an administrator PowerShell, install WSL and Ubuntu, then restart if
  prompted. Complete the Ubuntu user setup when it opens:
  ```powershell
  wsl --install -d Ubuntu
  ```
  Check `wsl -l -v` in PowerShell and make sure Ubuntu is running WSL version 2.
  For an existing WSL 1 distribution, use `wsl --set-version Ubuntu 2`.
2. Install and start [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/).
  Enable the WSL 2 engine and Ubuntu under **Settings > Resources > WSL
  Integration**, and use Linux containers. Allocate sufficient memory and
  disk for the selected stacks; see [Capacity](#capacity).
3. Open Ubuntu and install the command-line prerequisites:
  ```bash
  sudo apt update
  sudo apt install -y curl unzip
  ```
  Copy the deployment files into the Linux filesystem (for example, under `~`)
  and change into the directory containing `deploy.sh`. Keeping the files in
  WSL avoids Windows filesystem permission and performance issues.
4. Run the installer once to check Docker and create `.env`:
  ```bash
  bash install-windows.sh
  nano .env
  ```
  The installer does not overwrite an existing `.env` and does not deploy on
  the run that creates it. Set the image tags and registry credentials, replace
  the sample passwords, and configure the required database backup paths.
  The default AMP image requires AWS ECR credentials; dashboard images may
  require registry credentials. Backup paths must be Linux paths accessible
  from WSL, either absolute or relative to this directory.

  On empty volumes, the deploy script updates AMP's `DG_SITE_DOMAIN` table and
  Dashboard's WordPress `wp_options` table before starting the apps. Configure
  `AMP_DB_BACKUP_FILE` with a populated PostgreSQL custom-format dump and
  `DASHBOARD_MYSQL_BACKUP_FILE` with a populated WordPress SQL dump for the
  stacks being installed. Confirm the restore prompts when asked. See
  [Restores](#restores) for additional restore options.

  For local access without Traefik, set these values in `.env`:
  ```dotenv
  USE_TRAEFIK=false
  AMP_SITE_DOMAIN=localhost:8080
  DASHBOARD_SITE_URL=http://localhost:8081/wp
  ```
  Adjust the URLs if you change the ports or use public hostnames. The `.env`
  file is also sourced by Bash, so quote values when necessary and use LF line
  endings. Store credentials and backups securely.
5. Run the installer again to pull images and start both stacks:
  ```bash
  bash install-windows.sh
  ```
  Use `--amp-only` or `--dashboard-only` to install one stack, and
  `--with-traefik` or `--without-traefik` to override the Traefik setting.
  Docker Desktop must be running. With the default ports and Traefik disabled,
  the services are available from the Windows browser at
  `http://localhost:8080` and `http://localhost:8081`. Ensure those ports (and
  port 80 if using Traefik) are free.

Run the commands below, including backup and reinstall commands, from the same
WSL distribution. Docker Desktop's WSL integration must remain enabled.

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

## Logs on the host

AMP and most dashboard services write logs to a host directory instead of
only being available via `docker compose logs`:

- AMP (Tomcat/`catalina.out`): `${AMP_LOGS_DIR:-./logs}` under `deploy/amp/`
- Dashboard nginx, wordpress (apache), and every Spring Boot service (eureka,
  gateway, superset-proxy, stats, starter, amp-funding,
  amp-indicator-dashboard, amp-ndc-financing, amp-ndc-scenario,
  amp-ndc-emissions, map-service, amp-indicator-progress, amp-wocat): each
  gets its own subdirectory under `${DASHBOARD_LOGS_DIR:-./logs}` in
  `deploy/amp-dashboard/` (e.g. `logs/eureka/eureka.log`, `logs/nginx/`)

MySQL, Postgres, Redis, and Superset still only log to stdout — use
`./deploy.sh logs dashboard <service>` for those.

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

Database restore commands that finish with errors log a warning and allow
deployment to continue. Check the output to confirm that the restore succeeded.

After the dashboard DB steps run (on every `deploy`/`up`, including via
`reinstall.sh`), `deploy.sh` also updates WordPress's site URL to
`DASHBOARD_SITE_URL`, equivalent to:

```sql
UPDATE wp_options SET option_value = '<DASHBOARD_SITE_URL>' WHERE option_name = 'siteurl';
UPDATE wp_options SET option_value = '<DASHBOARD_SITE_URL>' WHERE option_name = 'home';
```

and then prints the result of:

```sql
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');
```

`DASHBOARD_SITE_URL` must include the scheme and any path (e.g.
`https://dashboard.ggw.ampsite.net/wp`). This only runs when Dashboard is
included (`all` or `dashboard`) and is skipped with a warning if
`DASHBOARD_SITE_URL` is unset.

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
