# TruBudget Enabled AMP Remote Linux Deployment Guide

This guide explains how to deploy AMP and TruBudget on a remote Linux server from start to finish.

## Deployment Models

### Primary model
- Single server for AMP + TruBudget

### Alternative model
- Separate servers for AMP and TruBudget

## Client OS Support and Command Conventions

Supported client operating systems:
- Windows (PowerShell)
- macOS (Terminal)
- Linux (Terminal)

Command conventions:
- Commands executed after SSH login run on the remote Linux server and are the same regardless of client OS.
- Commands executed on your local machine are shown with OS-specific examples when needed.
- Replace sample placeholders with real values in your environment.

Sample placeholders used in this guide:
- Sample server IP: `10.22.33.197`
- Sample username: `trubudget`

These are examples only.

---

## 1. Target Architecture (Single Server)

- One Linux VM
- AMP exposed on port `80` via Apache
- TruBudget UI exposed on port `3001` via Apache
- AMP container listens internally on `8080`
- TruBudget frontend container listens internally on `3000`
- TruBudget API listens internally on `8081`
- PostgreSQL + PostGIS runs in Docker for AMP

---

## 2. Prerequisites

### 2.1 Local workstation requirements
- SSH client
- Git
- Access to AMP repository or DG-provided deployment files
- DG-provided PostgreSQL dump file (for example `.pgsql` / `.sql`) for initial data restore
- AWS credentials that can pull AMP image from ECR

### 2.2 Server requirements
- Ubuntu 22.04 LTS (recommended)
- 4 vCPU and 8 GB RAM minimum for small environments
- 50 GB free disk minimum
- Sudo privileges
- OpenSSH server installed and running
- Outbound internet access for package install, Docker pulls, and git clone

### 2.3 Network requirements
Open inbound:
- `22` (SSH)
- `80` (AMP)
- `3001` (TruBudget UI)

Optional/debug ports (normally not public):
- `8080` (AMP backend direct)
- `8081` (TruBudget API direct)

---

## 3. Initial Access with Username and Password

This guide uses password-based SSH login (no SSH keys required).

### 3.1 Install OpenSSH server on Linux VM

If this is a fresh VM (VMware/VirtualBox/Proxmox/cloud), open the VM console and run:

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

If UFW (Ubuntu Firewall) is enabled:

```bash
sudo ufw allow OpenSSH
```

### 3.2 Verify SSH service and server IP

```bash
sudo systemctl status ssh --no-pager
hostname -I
```

### 3.3 SSH from local machine

Windows PowerShell:

```powershell
ssh trubudget@10.22.33.197
```

macOS/Linux:

```bash
ssh trubudget@10.22.33.197
```

Generic:

```bash
ssh YOUR_USERNAME@YOUR_SERVER_IP
```

### 3.4 Password prompts you should expect

First connection host verification prompt:

```text
The authenticity of host '10.22.33.197 (10.22.33.197)' can't be established.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type:

```text
yes
```

Then SSH asks for password:

```text
trubudget@10.22.33.197's password:
```

Notes:
- While typing password, no characters appear. This is normal.
- Wrong password repeatedly will return `Permission denied`.

### 3.5 Create deploy user (recommended)

```bash
sudo adduser ampdeploy
sudo usermod -aG sudo ampdeploy
```

During `adduser`, Linux prompts:
- `New password:`
- `Retype new password:`

That password is used for:

```bash
ssh ampdeploy@YOUR_SERVER_IP
```

Set/reset later if needed:

```bash
sudo passwd ampdeploy
```

---

## 4. Install Base Packages

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release git unzip jq apache2
sudo systemctl enable apache2
sudo systemctl start apache2
```

---

## 5. Install Docker Engine and Compose Plugin

### 5.1 Add Docker repository

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 5.2 Install Docker packages

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 5.3 Allow non-root Docker usage

```bash
sudo usermod -aG docker ampdeploy
```

Then logout/login as `ampdeploy`.

### 5.4 Validate installation

```bash
docker --version
docker compose version
```

---

## 6. Get Deployment Files on Server

### 6.1 Files provided by DG

Expected files:
- `backup.sh`
- `setup.sh`
- `env.example`
- `docker-compose.yml`
- AMP database dump file (for example `camerooon-4.0.pgsql.latest`)

Place them in `/opt/amp`.

Verify:

```bash
cd /opt/amp
ls -lah
```

### 6.2 Copy files with SCP (local machine to server)

Prepare destination once:

```bash
ssh ampdeploy@10.22.33.197
sudo mkdir -p /opt/amp
sudo chown -R ampdeploy:ampdeploy /opt/amp
exit
```

Linux/macOS client:

```bash
cd /path/to/dg-delivered-files
scp backup.sh setup.sh env.example docker-compose.yml ampdeploy@10.22.33.197:/opt/amp/
```

If DG also provided the database dump file, copy it too:

```bash
scp camerooon-4.0.pgsql.latest ampdeploy@10.22.33.197:/opt/amp/
```

Windows PowerShell client:

```powershell
cd "C:\path\to\dg-delivered-files"
scp .\backup.sh .\setup.sh .\env.example .\docker-compose.yml ampdeploy@10.22.33.197:/opt/amp/
```

If DG also provided the database dump file, copy it too:

```powershell
scp .\camerooon-4.0.pgsql.latest ampdeploy@10.22.33.197:/opt/amp/
```

Verify on server:

```bash
ssh ampdeploy@10.22.33.197
ls -lah /opt/amp
```

---

## 7. Prepare Environment File

```bash
cd /opt/amp
if [ -f amp/.env.example ]; then cp amp/.env.example .env; else cp env.example .env; fi
nano .env
```

Minimum values:
- `SERVER_IP`
- `AMP_IMAGE`
- `AMP_TAG`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_DEFAULT_REGION`
- `AMP_DB_NAME`
- `AMP_DB_USER`
- `AMP_DB_PASSWORD`
- `TRUBUDGET_ROOT_SECRET`
- `TRUBUDGET_VAULT_SECRET`
- `TRUBUDGET_RPC_PASSWORD`

Important:
- `TRUBUDGET_RPC_PASSWORD` must be at least 32 characters.
- Use strong non-default secrets.
- Do not commit `.env`.

---

## 8. Validate Deployment Scripts

```bash
chmod +x /opt/amp/setup.sh
chmod +x /opt/amp/backup.sh
/opt/amp/setup.sh --help
```

---

## 9. Deploy AMP and TruBudget

### 9.1 Foreground deploy

```bash
cd /opt/amp
./setup.sh
```

### 9.2 Background deploy

```bash
cd /opt/amp
./setup.sh --background
```

Follow setup log:

```bash
tail -f /opt/amp/setup-YYYYMMDD-HHMMSS.log
```

### 9.3 Optional setup flags

```bash
./setup.sh --no-trubudget
./setup.sh --full-trubudget
./setup.sh --skip-build
./setup.sh --lang=fr
```

---

## 10. Configure Apache Reverse Proxy

Goal:
- AMP on port `80`
- TruBudget UI on port `3001`

### 10.1 AMP vhost (port 80)

```bash
sudo tee /etc/apache2/sites-available/000-default.conf > /dev/null <<'EOF'
<VirtualHost *:80>
    ServerName 10.22.33.197

    ProxyRequests Off
    ProxyPreserveHost Off

    RequestHeader set X-Real-IP %{REMOTE_ADDR}s
    RequestHeader set X-Forwarded-For %{REMOTE_ADDR}s
    RequestHeader set X-Forwarded-Proto "http"

    ProxyPass        / http://10.22.33.197:8080/
    ProxyPassReverse / http://10.22.33.197:8080/

    ErrorLog ${APACHE_LOG_DIR}/reverse-proxy-error.log
    CustomLog ${APACHE_LOG_DIR}/reverse-proxy-access.log combined
</VirtualHost>
EOF
```

### 10.2 TruBudget vhost (port 3001)

```bash
sudo tee /etc/apache2/sites-available/trubudget.conf > /dev/null <<'EOF'
Listen 3001

<VirtualHost *:3001>
    ServerName 10.22.33.197

    ProxyRequests Off
    ProxyPreserveHost Off

    ProxyPass        / http://10.22.33.197:3000/
    ProxyPassReverse / http://10.22.33.197:3000/

    ErrorLog ${APACHE_LOG_DIR}/trubudget-error.log
    CustomLog ${APACHE_LOG_DIR}/trubudget-access.log combined
</VirtualHost>
EOF
```

### 10.3 Enable modules and site

```bash
sudo a2enmod proxy proxy_http headers
sudo a2ensite trubudget.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

---

## 11. Smoke Tests and Initial Data

### 11.1 Verify containers

```bash
docker ps
```

Expected containers include:
- `amp-app`
- `amp-db`
- `trubudget-operation-frontend-1`
- `trubudget-operation-alpha-api-1`
- `trubudget-operation-alpha-node-1`

### 11.2 Initial DB restore (DG provides dump)

This dump file is provided by DG. Copy it from your local machine to the server first (see section 6.2), then restore it.

```bash
docker exec -i amp-db pg_restore -U amp -d amp --clean < /opt/amp/camerooon-4.0.pgsql.latest
```

Then restart AMP app:

```bash
docker restart amp-app
```

### 11.3 Required post-deployment DB update

Run this SQL:

```sql
UPDATE DG_SITE_DOMAIN SET SITE_DOMAIN='IP_ADDRESS';
```

Command form:

```bash
docker exec -i amp-db env PGPASSWORD=YOUR_DB_PASSWORD psql -U YOUR_DB_USER -d YOUR_DB_NAME -c "UPDATE DG_SITE_DOMAIN SET SITE_DOMAIN='IP_ADDRESS';"
```

Sample:

```bash
docker exec -i amp-db env PGPASSWORD=Minepat123 psql -U amp -d amp -c "UPDATE DG_SITE_DOMAIN SET SITE_DOMAIN='10.22.33.197';"
```

Verify:

```bash
docker exec -i amp-db env PGPASSWORD=YOUR_DB_PASSWORD psql -U YOUR_DB_USER -d YOUR_DB_NAME -c "SELECT SITE_DOMAIN FROM DG_SITE_DOMAIN;"
```

After this SQL update, restart AMP app so the change is applied:

```bash
docker restart amp-app
```

### 11.4 HTTP checks

```bash
curl -I http://127.0.0.1:8080/
curl -I http://127.0.0.1:3000/
curl -I http://10.22.33.197/
curl -I http://10.22.33.197:3001/
```

### 11.5 Browser checks

Open in any browser:
- AMP: `http://10.22.33.197/`
- TruBudget UI: `http://10.22.33.197:3001/`

Quick launch examples:

Windows PowerShell:

```powershell
start chrome "http://10.22.33.197/"
start chrome "http://10.22.33.197:3001/"
```

macOS:

```bash
open -a "Google Chrome" "http://10.22.33.197/"
open -a "Google Chrome" "http://10.22.33.197:3001/"
```

Linux:

```bash
google-chrome "http://10.22.33.197/"
google-chrome "http://10.22.33.197:3001/"
```

If `google-chrome` is unavailable:

```bash
chromium-browser "http://10.22.33.197/"
chromium-browser "http://10.22.33.197:3001/"
```

---

## 12. AMP Admin Global Settings for TruBudget

In AMP admin:
- Admin
- Global Settings
- trubudget

### 12.1 Required setting

`baseUrl`

Single-server recommended value with docker deployments:

```text
http://host.docker.internal:8081/
```

If `host.docker.internal` is unavailable, use a reachable host/IP.

### 12.2 Recommended settings to verify

- `isEnabled = true`
- `baseUrl = API endpoint`
- `apiVersion = expected by AMP and TruBudget deployment`
- `defaultSubProjectCurrency = e.g. USD`
- `workFlowItemDueDays = e.g. 30`

### 12.3 Validation after save

- Save/update an AMP activity that triggers TruBudget sync.
- Confirm no API errors in AMP logs.
- Confirm project/update appears in TruBudget.

---

## 13. Logs and Monitoring

This section explains how to view logs during deployment and troubleshooting.

### 13.1 Docker logs for AMP container

```bash
docker logs amp-app --tail 200
docker logs amp-app -f
```

### 13.2 Docker logs for AMP database container

```bash
docker logs amp-db --tail 200
docker logs amp-db -f
```

### 13.3 Docker Compose logs for AMP stack

```bash
docker compose -f /opt/amp/docker-compose.yml --env-file /opt/amp/.env logs -f
```

Only AMP app service:

```bash
docker compose -f /opt/amp/docker-compose.yml --env-file /opt/amp/.env logs -f amp
```

### 13.4 Docker Compose logs for TruBudget stack

```bash
docker compose -f /opt/amp/trubudget/scripts/operation/docker-compose.yml -p trubudget-operation logs -f
```

---

## 14. Backup and Restore

### 14.1 Manual backup run

```bash
cd /opt/amp
./backup.sh
```

Default backup location:

```text
/opt/amp/backups
```

### 14.2 What cron is and how it works

cron is a Linux scheduler that runs commands automatically at specific times.  
`crontab -e` opens your user’s schedule.  
Each line defines when and what to run.  
Standard schedule format has 5 time fields:

```text
minute hour day_of_month month day_of_week
```

Example line:

```cron
0 2 * * * /opt/amp/backup.sh >> /var/log/amp-backup.log 2>&1
```

Meaning:
- `0 2 * * *` = every day at 02:00
- Run `/opt/amp/backup.sh`
- Append output to `/var/log/amp-backup.log`
- `2>&1` merges error output into same log file

Set it:

```bash
crontab -e
```

Paste:

```cron
0 2 * * * /opt/amp/backup.sh >> /var/log/amp-backup.log 2>&1
```

List scheduled jobs:

```bash
crontab -l
```

### 14.3 Restore database

```bash
gunzip -c /opt/amp/backups/amp-db_YYYYMMDD_HHMMSS.sql.gz | \
docker exec -i amp-db env PGPASSWORD=YOUR_DB_PASSWORD psql -U YOUR_DB_USER -d YOUR_DB_NAME
```

---

## 15. Operations Commands

### 15.1 Stop stack

```bash
cd /opt/amp
./setup.sh --down
```

### 15.2 Stop and remove volumes (destructive)

```bash
./setup.sh --down-all
```

Warning:
- This removes persisted data.
- Run backup first.

---

## 16. Upgrade Process

### 16.1 AMP image upgrade

1. Update `AMP_TAG` in `/opt/amp/.env`.
2. Run:

```bash
cd /opt/amp
./setup.sh
```

### 16.2 TruBudget upgrade

3. Set `TRUBUDGET_VERSION` in `.env`.
4. Run:

```bash
./setup.sh
```

The setup script upgrades while preserving volumes where supported.

---

## 17. Troubleshooting and Common Issues

### 17.1 ECR pull auth errors

Symptoms:
- `pull access denied`
- `no basic auth credentials`

Fix:
- Check AWS keys and region in `.env`
- Re-run `./setup.sh`

### 17.2 TruBudget login/cookie issues

If using plain HTTP and login loops occur, ensure frontend cookie flags are correctly set by setup.

### 17.3 AMP startup NPE or DB issues

```bash
docker logs amp-app --tail 200
docker ps
docker exec amp-db psql -U AMP_DB_USER -d AMP_DB_NAME -c "select 1"
```

### 17.4 Apache issues

```bash
sudo apache2ctl configtest
sudo systemctl status apache2
sudo tail -n 200 /var/log/apache2/error.log
```

### 17.5 AMP app not connecting to database

Symptoms:
- AMP page fails to load or shows backend errors

`docker logs amp-app --tail 200` shows errors like:
- `FATAL: password authentication failed for user ...`
- `Failed to obtain JDBC Connection`
- `Connection refused to PostgreSQL host/port`

Step 1: check logs and current DB access

```bash
docker logs amp-app --tail 200
docker logs amp-db --tail 200
docker exec -i amp-db env PGPASSWORD=YOUR_DB_PASSWORD psql -U YOUR_DB_USER -d YOUR_DB_NAME -c "select 1"
```

Step 2: reset DB user password in `amp-db`

```bash
docker exec -i amp-db psql -U postgres -d postgres -c "ALTER USER YOUR_DB_USER WITH PASSWORD 'YOUR_NEW_DB_PASSWORD';"
```

Optional quick validation with new password:

```bash
docker exec -i amp-db env PGPASSWORD=YOUR_NEW_DB_PASSWORD psql -U YOUR_DB_USER -d YOUR_DB_NAME -c "select current_user, current_database();"
```

Step 3: update JDBC password in AMP `context.xml` inside `amp-app`

```bash
docker exec -it amp-app sh
sed -i 's|password="[^"]*"|password="YOUR_NEW_DB_PASSWORD"|g' /usr/local/tomcat/webapps/ROOT/META-INF/context.xml
grep -n 'username=\|password=\|jdbc:postgresql://' /usr/local/tomcat/webapps/ROOT/META-INF/context.xml
exit
```

Step 4: restart AMP app

```bash
docker restart amp-app
docker logs amp-app --tail 200
```

Important persistence note:
- On container start, the AMP entrypoint rewrites `context.xml` from `JDBC_*` environment variables.
- To keep this fix persistent, also update DB credentials in `/opt/amp/.env` (or your compose env source) and rerun:

```bash
cd /opt/amp
./setup.sh
```

---

## 18. Security Recommendations

- Use least-privilege IAM credentials for ECR pull.
- Restrict SSH source IPs.
- Restrict exposed ports with UFW/security groups.
- Rotate secrets in `.env` regularly.
- Enable HTTPS in production.

---

## 19. Quick Command Checklist

```bash
# sample only
ssh trubudget@10.22.33.197

ssh ampdeploy@10.22.33.197
cd /opt/amp
if [ -f amp/.env.example ]; then cp amp/.env.example .env; else cp env.example .env; fi
nano .env
chmod +x setup.sh backup.sh
./setup.sh

sudo a2enmod proxy proxy_http headers
sudo a2ensite trubudget.conf
sudo apache2ctl configtest && sudo systemctl reload apache2

curl -I http://10.22.33.197/
curl -I http://10.22.33.197:3001/
```

Deployment is complete when AMP and TruBudget are reachable and login works.

---

## 20. Alternative Topology: Separate Servers

Use this only when AMP and TruBudget are on different hosts.

### Example topology
- Server A (AMP): AMP app + AMP DB + Apache
- Server B (TruBudget): TruBudget stack + Apache

Sample IPs:
- AMP server: `10.22.33.197`
- TruBudget server: `10.22.33.198`

### 20.1 Minimum connectivity

From AMP server to TruBudget server:
- Port `8081` (direct API)
- Or `80/443` (API via reverse proxy)

From users to AMP server:
- `80/443`

From users to TruBudget server (if UI exposed):
- `80` and/or `3001`

### 20.2 AMP setting for remote TruBudget

Set in AMP `.env` and AMP admin global settings:

```text
TRUBUDGET_BASE_URL=http://10.22.33.198:8081/
```

Or proxy/DNS form:

```text
TRUBUDGET_BASE_URL=http://trubudget.example.org/api/
```

### 20.3 Apache examples for separate servers

AMP server Apache example:

```apache
<VirtualHost *:80>
    ServerName amp.example.org
    ProxyRequests Off
    ProxyPreserveHost Off
    ProxyPass        / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/
</VirtualHost>
```

TruBudget server Apache example:

```apache
<VirtualHost *:80>
    ServerName trubudget.example.org
    ProxyRequests Off
    ProxyPreserveHost Off
    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/
</VirtualHost>
```

### 20.4 Verify server-to-server reachability

Run from AMP server:

```bash
curl -I http://TRUBUDGET_HOST_OR_IP:TRUBUDGET_API_PORT/
```
