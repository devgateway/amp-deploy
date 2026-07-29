#!/usr/bin/env bash
# =============================================================================
# backup.sh — Backup AMP and/or amp-dashboard data
#
# Creates timestamped backups suitable for direct use with deploy.sh's restore
# flow (AMP_DB_BACKUP_FILE, DASHBOARD_POSTGRES_BACKUP_FILE,
# DASHBOARD_MYSQL_BACKUP_FILE, DASHBOARD_UPLOADS_SOURCE):
#
#   AMP:
#     - PostgreSQL database (pg_dump custom format, uncompressed so it can be
#       fed directly to pg_restore, matching deploy.sh's restore step)
#
#   Dashboard:
#     - PostgreSQL "viz" database (pg_dump custom format)
#     - MySQL "wordpress" database (plain SQL dump)
#     - wordpress uploads volume (tar.gz archive)
#
# Usage:
#   ./backup.sh [--amp-only|--dashboard-only] [--db-only|--uploads-only] \
#               [--keep <days>] [--dest <dir>] [--help]
#
# Flags:
#   --amp-only        Only back up AMP
#   --dashboard-only   Only back up amp-dashboard
#   --db-only          Only back up databases (skip dashboard uploads)
#   --uploads-only     Only back up the dashboard uploads volume (skip all DBs)
#   --keep <days>      Delete backups older than N days (default: 30, 0 = keep all)
#   --dest <dir>       Directory to write backups to (default: <deploy>/backups)
#   --help             Show this message
#
# To run automatically, add to crontab:
#   0 2 * * * /opt/amp/deploy/backup.sh >> /var/log/amp-backup.log 2>&1
# =============================================================================

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$BASE/.env}"

AMP_PROJECT="${AMP_PROJECT:-amp}"
DASH_PROJECT="${DASH_PROJECT:-amp-dashboard}"

AMP_DB_CONTAINER="${AMP_DB_CONTAINER:-amp-db}"
DASHBOARD_POSTGRES_CONTAINER="${DASHBOARD_POSTGRES_CONTAINER:-${DASH_PROJECT}-postgres-1}"
DASHBOARD_MYSQL_CONTAINER="${DASHBOARD_MYSQL_CONTAINER:-${DASH_PROJECT}-mysql-1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
info() { echo -e "${CYAN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%Y-%m-%d %T')] ERROR:${NC} $*" >&2; exit 1; }

BACKUP_TARGET="all"
DO_DB=true
DO_UPLOADS=true
KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
BACKUP_DEST="${BACKUP_DEST:-$BASE/backups}"

usage() {
  sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amp-only)
      BACKUP_TARGET="amp"
      shift
      ;;
    --dashboard-only)
      BACKUP_TARGET="dashboard"
      shift
      ;;
    --db-only)
      DO_UPLOADS=false
      shift
      ;;
    --uploads-only)
      DO_DB=false
      shift
      ;;
    --keep)
      KEEP_DAYS="$2"
      shift 2
      ;;
    --dest)
      BACKUP_DEST="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

target_includes_amp() {
  [[ "$BACKUP_TARGET" == "all" || "$BACKUP_TARGET" == "amp" ]]
}

target_includes_dashboard() {
  [[ "$BACKUP_TARGET" == "all" || "$BACKUP_TARGET" == "dashboard" ]]
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
  else
    warn ".env not found at $ENV_FILE; relying on already-exported environment variables"
  fi
}

require_running_container() {
  local container="$1"
  docker ps --format '{{.Names}}' | grep -qx "$container" \
    || die "Container '$container' is not running. Is the stack up?"
}

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

backup_amp_db() {
  local db_name db_user db_password backup_file size

  db_name="${AMP_DB_NAME:-amp}"
  db_user="${AMP_DB_USER:-amp}"
  db_password="${AMP_DB_PASSWORD:-}"
  backup_file="${BACKUP_DEST}/amp-db_${TIMESTAMP}.dump"

  log "Backing up AMP database '${db_name}' from container '${AMP_DB_CONTAINER}'..."
  require_running_container "$AMP_DB_CONTAINER"

  docker exec -i -e PGPASSWORD="${db_password}" "$AMP_DB_CONTAINER" \
    pg_dump -U "$db_user" -d "$db_name" -Fc --no-password > "$backup_file"

  size="$(du -sh "$backup_file" | cut -f1)"
  log "AMP database backup complete: $(basename "$backup_file") (${size})"
}

backup_dashboard_postgres() {
  local db_password backup_file size

  db_password="${DASHBOARD_DB_PASSWORD:-}"
  backup_file="${BACKUP_DEST}/dashboard-postgres_${TIMESTAMP}.dump"

  log "Backing up dashboard database 'viz' from container '${DASHBOARD_POSTGRES_CONTAINER}'..."
  require_running_container "$DASHBOARD_POSTGRES_CONTAINER"

  docker exec -i -e PGPASSWORD="${db_password}" "$DASHBOARD_POSTGRES_CONTAINER" \
    pg_dump -U postgres -d viz -Fc --no-password > "$backup_file"

  size="$(du -sh "$backup_file" | cut -f1)"
  log "Dashboard postgres backup complete: $(basename "$backup_file") (${size})"
}

backup_dashboard_mysql() {
  local db_name db_user db_password backup_file size mysql_auth

  db_name="${DASHBOARD_MYSQL_DB_NAME:-wordpress}"
  db_user="${DASHBOARD_MYSQL_WP_USER:-wordpress}"
  db_password="${DASHBOARD_MYSQL_WP_PASSWORD:-}"
  backup_file="${BACKUP_DEST}/dashboard-mysql_${TIMESTAMP}.sql"

  log "Backing up dashboard database '${db_name}' from container '${DASHBOARD_MYSQL_CONTAINER}'..."
  require_running_container "$DASHBOARD_MYSQL_CONTAINER"

  if [[ -n "$db_password" ]]; then
    mysql_auth="-u${db_user} -p${db_password}"
  else
    mysql_auth="-u${db_user}"
  fi

  docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc "mysqldump ${mysql_auth} ${db_name}" > "$backup_file"

  size="$(du -sh "$backup_file" | cut -f1)"
  log "Dashboard mysql backup complete: $(basename "$backup_file") (${size})"
}

backup_dashboard_uploads() {
  local volume_name backup_file size

  volume_name="${DASH_PROJECT}_wordpress"
  backup_file="${BACKUP_DEST}/dashboard-uploads_${TIMESTAMP}.tar.gz"

  log "Backing up dashboard uploads volume '${volume_name}'..."

  if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
    warn "Volume '${volume_name}' not found; skipping dashboard uploads backup"
    return 0
  fi

  docker run --rm \
    -v "${volume_name}:/var/www/html:ro" \
    -v "${BACKUP_DEST}:/backup" \
    busybox tar czf "/backup/$(basename "$backup_file")" -C /var/www/html .

  size="$(du -sh "$backup_file" | cut -f1)"
  log "Dashboard uploads backup complete: $(basename "$backup_file") (${size})"
}

prune_old_backups() {
  if [[ "$KEEP_DAYS" -le 0 ]]; then
    info "KEEP_DAYS=$KEEP_DAYS; skipping pruning of old backups"
    return 0
  fi

  log "Removing backups older than ${KEEP_DAYS} days from ${BACKUP_DEST}..."
  find "$BACKUP_DEST" -maxdepth 1 \
    \( -name "amp-db_*.dump" \
       -o -name "dashboard-postgres_*.dump" \
       -o -name "dashboard-mysql_*.sql" \
       -o -name "dashboard-uploads_*.tar.gz" \) \
    -mtime "+${KEEP_DAYS}" -print -delete
}

print_summary() {
  echo ""
  echo -e "  Backup directory: ${CYAN}${BACKUP_DEST}${NC}"
  echo "  Contents from this run (timestamp ${TIMESTAMP}):"
  # shellcheck disable=SC2012
  ls -lh "$BACKUP_DEST" 2>/dev/null | grep "$TIMESTAMP" | awk '{print "    " $NF " (" $5 ")"}'
  echo ""
  echo "To use these with deploy.sh's restore flow, set in .env:"
  if target_includes_amp && [[ "$DO_DB" == true ]]; then
    echo "  AMP_DB_BACKUP_FILE=backups/amp-db_${TIMESTAMP}.dump"
  fi
  if target_includes_dashboard; then
    if [[ "$DO_DB" == true ]]; then
      echo "  DASHBOARD_POSTGRES_BACKUP_FILE=backups/dashboard-postgres_${TIMESTAMP}.dump"
      echo "  DASHBOARD_MYSQL_BACKUP_FILE=backups/dashboard-mysql_${TIMESTAMP}.sql"
    fi
    if [[ "$DO_UPLOADS" == true ]]; then
      echo "  DASHBOARD_UPLOADS_SOURCE=backups/dashboard-uploads_${TIMESTAMP}.tar.gz"
    fi
  fi
  echo ""
}

load_env
mkdir -p "$BACKUP_DEST"

log "Starting backup (timestamp: ${TIMESTAMP}, target: ${BACKUP_TARGET})"
log "Destination: ${BACKUP_DEST}"

if target_includes_amp; then
  if [[ "$DO_DB" == true ]]; then
    backup_amp_db
  else
    info "AMP: --uploads-only requested, but AMP has no uploads volume to back up; skipping"
  fi
else
  info "AMP is excluded from this run (--dashboard-only); skipping AMP backup"
fi

if target_includes_dashboard; then
  if [[ "$DO_DB" == true ]]; then
    backup_dashboard_postgres
    backup_dashboard_mysql
  fi
  if [[ "$DO_UPLOADS" == true ]]; then
    backup_dashboard_uploads
  fi
else
  info "Dashboard is excluded from this run (--amp-only); skipping dashboard backup"
fi

prune_old_backups
log "Backup finished."
print_summary
