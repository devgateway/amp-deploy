#!/usr/bin/env bash
# =============================================================================
# AMP + amp-dashboard deployment script (image-only)
#
# This script deploys services from container images only.
# It does NOT clone or pull application source code.
#
# Expected layout (defaults, all overridable in .env):
#   /opt/amp/deploy/
#     .env
#     deploy.sh
#     amp/docker-compose.yml
#     amp-dashboard/docker-compose.yml
#     amp-dashboard/docker-compose.traefik.yml   (optional)
#     traefik/docker-compose.yml                 (optional)
#
# Usage:
#   ./deploy.sh deploy [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh up [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh down [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh restart [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh pull [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh status [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]
#   ./deploy.sh logs <traefik|amp|dashboard|container> [service]
#
# By default both AMP and amp-dashboard stacks are deployed. Use --amp-only or
# --dashboard-only (or DEPLOY_TARGET=amp|dashboard in .env) to limit actions to
# a single stack.
# =============================================================================

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$BASE/.env}"

AMP_COMPOSE="${AMP_COMPOSE:-$BASE/amp/docker-compose.yml}"
DASH_COMPOSE="${DASH_COMPOSE:-$BASE/amp-dashboard/docker-compose.yml}"
DASH_TRAEFIK_OVERRIDE="${DASH_TRAEFIK_OVERRIDE:-$BASE/amp-dashboard/docker-compose.traefik.yml}"
TRAEFIK_COMPOSE="${TRAEFIK_COMPOSE:-$BASE/traefik/docker-compose.yml}"

AMP_PROJECT="${AMP_PROJECT:-amp}"
DASH_PROJECT="${DASH_PROJECT:-amp-dashboard}"
TRAEFIK_PROJECT="${TRAEFIK_PROJECT:-traefik}"

AMP_DB_CONTAINER="${AMP_DB_CONTAINER:-amp-db}"
DASHBOARD_POSTGRES_CONTAINER="${DASHBOARD_POSTGRES_CONTAINER:-${DASH_PROJECT}-postgres-1}"
DASHBOARD_MYSQL_CONTAINER="${DASHBOARD_MYSQL_CONTAINER:-${DASH_PROJECT}-mysql-1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
info() { echo -e "${CYAN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%Y-%m-%d %T')] ERROR:${NC} $*" >&2; exit 1; }

USE_TRAEFIK=""
CLI_TRAEFIK_MODE=""
DEPLOY_TARGET=""
CLI_DEPLOY_TARGET=""

usage() {
  cat <<EOF

  AMP image-only deploy script

  Usage:  $0 <command> [args] [--with-traefik|--without-traefik] [--amp-only|--dashboard-only]

  Commands:
    deploy              Pull images, then start/update stacks
    up                  Start/update stacks (no image pull)
    down                Stop stacks (volumes kept)
    restart             down + up
    pull                Pull images only
    status              Show running containers
    logs <stack> [svc]  Follow logs:
                        stack: traefik | amp | dashboard | <container-name>
    help                Show this message

  Traefik toggle:
    --with-traefik      Force include Traefik and dashboard Traefik override
    --without-traefik   Force skip Traefik and dashboard Traefik override

  Stack scope toggle:
    --amp-only          Only act on the AMP stack (skip amp-dashboard)
    --dashboard-only    Only act on the amp-dashboard stack (skip AMP)

  Env toggles:
    USE_TRAEFIK=true|false
    DEPLOY_TARGET=all|amp|dashboard

EOF
}

parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-traefik)
        CLI_TRAEFIK_MODE="true"
        shift
        ;;
      --without-traefik)
        CLI_TRAEFIK_MODE="false"
        shift
        ;;
      --amp-only)
        CLI_DEPLOY_TARGET="amp"
        shift
        ;;
      --dashboard-only)
        CLI_DEPLOY_TARGET="dashboard"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done
  REMAINING_ARGS=("$@")
}

resolve_deploy_target() {
  local requested requested_lc

  requested="${CLI_DEPLOY_TARGET:-${DEPLOY_TARGET:-all}}"
  requested_lc="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"

  case "$requested_lc" in
    all|both|"")
      DEPLOY_TARGET="all"
      ;;
    amp)
      DEPLOY_TARGET="amp"
      ;;
    dashboard|dash)
      DEPLOY_TARGET="dashboard"
      ;;
    *)
      die "Invalid DEPLOY_TARGET value: '$requested' (expected all/amp/dashboard)"
      ;;
  esac
}

target_includes_amp() {
  [[ "$DEPLOY_TARGET" == "all" || "$DEPLOY_TARGET" == "amp" ]]
}

target_includes_dashboard() {
  [[ "$DEPLOY_TARGET" == "all" || "$DEPLOY_TARGET" == "dashboard" ]]
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  docker compose version >/dev/null 2>&1 || die "'docker compose' plugin not found"
  [[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"
  if target_includes_amp; then
    [[ -f "$AMP_COMPOSE" ]] || die "AMP compose not found at $AMP_COMPOSE"
  fi
  if target_includes_dashboard; then
    [[ -f "$DASH_COMPOSE" ]] || die "Dashboard compose not found at $DASH_COMPOSE"
  fi
}

load_env() {
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}

resolve_traefik_mode() {
  local requested="${CLI_TRAEFIK_MODE:-${USE_TRAEFIK:-}}"
  local requested_lc

  if [[ -z "$requested" ]]; then
    if [[ -f "$TRAEFIK_COMPOSE" ]]; then
      requested="true"
    else
      requested="false"
    fi
  fi

  requested_lc="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"

  case "$requested_lc" in
    true|1|yes|y)
      USE_TRAEFIK="true"
      [[ -f "$TRAEFIK_COMPOSE" ]] || die "Traefik enabled but compose not found at $TRAEFIK_COMPOSE"
      if [[ ! -f "$DASH_TRAEFIK_OVERRIDE" ]]; then
        warn "Traefik enabled but dashboard override file is missing: $DASH_TRAEFIK_OVERRIDE"
        warn "Dashboard will run without Traefik-specific override."
      fi
      ;;
    false|0|no|n)
      USE_TRAEFIK="false"
      ;;
    *)
      die "Invalid USE_TRAEFIK value: '$requested' (expected true/false)"
      ;;
  esac
}

amp_compose() {
  docker compose -f "$AMP_COMPOSE" --env-file "$ENV_FILE" -p "$AMP_PROJECT" "$@"
}

dash_compose() {
  local cmd=(docker compose -f "$DASH_COMPOSE" --env-file "$ENV_FILE" -p "$DASH_PROJECT")
  if [[ "$USE_TRAEFIK" == "true" && -f "$DASH_TRAEFIK_OVERRIDE" ]]; then
    cmd+=( -f "$DASH_TRAEFIK_OVERRIDE" )
  fi
  "${cmd[@]}" "$@"
}

traefik_compose() {
  docker compose -f "$TRAEFIK_COMPOSE" --env-file "$ENV_FILE" -p "$TRAEFIK_PROJECT" "$@"
}

escape_sql_literal() {
  # Escape single quotes for safe SQL literal interpolation.
  printf '%s' "$1" | sed "s/'/''/g"
}

is_truthy() {
  local value_lc
  value_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value_lc" == "true" || "$value_lc" == "1" || "$value_lc" == "yes" || "$value_lc" == "y" ]]
}

confirm_restore() {
  local label="$1"
  local answer answer_lc

  if [[ ! -t 0 ]]; then
    if is_truthy "${ASSUME_YES_RESTORE:-false}"; then
      info "Non-interactive mode with ASSUME_YES_RESTORE=true; proceeding with ${label} restore"
      return 0
    fi
    warn "Non-interactive mode; skipping ${label} restore (set ASSUME_YES_RESTORE=true to auto-approve)"
    return 1
  fi

  while true; do
    read -r -p "Restore ${label}? [y/N]: " answer
    answer_lc="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer_lc" in
      y|yes)
        return 0
        ;;
      n|no|"")
        return 1
        ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

wait_for_amp_db() {
  local retries="${AMP_DB_WAIT_RETRIES:-60}"
  local delay="${AMP_DB_WAIT_SECONDS:-2}"
  local i

  for ((i=1; i<=retries; i++)); do
    if docker exec -i "$AMP_DB_CONTAINER" pg_isready -U "$AMP_DB_USER" -d "$AMP_DB_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  die "AMP DB did not become ready in time"
}

amp_db_has_user_tables() {
  local count
  count="$(docker exec -i "$AMP_DB_CONTAINER" psql -U "$AMP_DB_USER" -d "$AMP_DB_NAME" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" \
    | tr -d '[:space:]')"
  [[ -n "$count" && "$count" != "0" ]]
}

resolve_amp_backup_file() {
  local configured

  configured="${AMP_DB_BACKUP_FILE:-}"
  if [[ -z "$configured" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$configured" = /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s' "$BASE/$configured"
  fi
}

restore_amp_db_if_needed() {
  local backup_file force_restore

  force_restore="${FORCE_AMP_DB_RESTORE:-false}"
  backup_file="$(resolve_amp_backup_file)"
  if [[ -z "$backup_file" ]]; then
    if is_truthy "$force_restore"; then
      die "FORCE_AMP_DB_RESTORE is true but AMP_DB_BACKUP_FILE is not set"
    fi
    info "AMP_DB_BACKUP_FILE is not set; skipping AMP DB restore"
    return 0
  fi
  [[ -f "$backup_file" ]] || die "Configured AMP_DB_BACKUP_FILE not found: $backup_file"

  if ! confirm_restore "AMP DB from $backup_file"; then
    info "Skipped AMP DB restore by user choice"
    return 0
  fi

  if amp_db_has_user_tables && ! is_truthy "$force_restore"; then
    info "AMP DB already has tables; skipping restore (set FORCE_AMP_DB_RESTORE=true to force)"
    return 0
  fi

  log "Restoring AMP DB from $backup_file ..."
  if docker exec -i "$AMP_DB_CONTAINER" pg_restore -U "$AMP_DB_USER" -d "$AMP_DB_NAME" --clean --if-exists < "$backup_file"; then
    log "AMP DB restore completed"
  else
    warn "AMP DB restore finished with PostgreSQL errors; continuing deployment"
  fi
}

update_amp_site_domain() {
  local raw_domain escaped_domain

  raw_domain="${AMP_SITE_DOMAIN:-${AMP_DOMAIN:-}}"
  if [[ -z "$raw_domain" ]]; then
    warn "AMP_SITE_DOMAIN/AMP_DOMAIN is empty; skipping DG_SITE_DOMAIN update"
    return 0
  fi

  escaped_domain="$(escape_sql_literal "$raw_domain")"
  log "Updating DG_SITE_DOMAIN.site_domain to '$raw_domain'"
  docker exec -i "$AMP_DB_CONTAINER" psql -U "$AMP_DB_USER" -d "$AMP_DB_NAME" -v ON_ERROR_STOP=1 -c \
    "UPDATE DG_SITE_DOMAIN SET site_domain='${escaped_domain}';"
}

init_amp_db() {
  log "Waiting for AMP DB readiness..."
  wait_for_amp_db
  restore_amp_db_if_needed
  update_amp_site_domain
}

wait_for_dashboard_dbs() {
  local retries="${DASHBOARD_DB_WAIT_RETRIES:-60}"
  local delay="${DASHBOARD_DB_WAIT_SECONDS:-2}"
  local i

  for ((i=1; i<=retries; i++)); do
      if docker exec -i "$DASHBOARD_POSTGRES_CONTAINER" pg_isready -U postgres -d viz >/dev/null 2>&1; then
      break
    fi
    sleep "$delay"
  done

  if [[ "$i" -gt "$retries" ]]; then
    die "Dashboard postgres did not become ready in time"
  fi

  for ((i=1; i<=retries; i++)); do
      if docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc 'mysqladmin ping -h 127.0.0.1 -u root -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  die "Dashboard mysql did not become ready in time"
}

dash_postgres_has_user_tables() {
  local count
  count="$(docker exec -i "$DASHBOARD_POSTGRES_CONTAINER" psql -U postgres -d viz -tAc \
     "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" \
    | tr -d '[:space:]')"
  [[ -n "$count" && "$count" != "0" ]]
}

dash_mysql_has_user_tables() {
  local count
  count="$(docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc \
     'mysql -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN (\"mysql\",\"information_schema\",\"performance_schema\",\"sys\");" -uroot -p"$MYSQL_ROOT_PASSWORD"' \
    | tr -d '[:space:]')"
  [[ -n "$count" && "$count" != "0" ]]
}

resolve_dashboard_postgres_backup_file() {
  local configured
  configured="${DASHBOARD_POSTGRES_BACKUP_FILE:-}"
  if [[ -z "$configured" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$configured" = /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s' "$BASE/$configured"
  fi
}

resolve_dashboard_mysql_backup_file() {
  local configured
  configured="${DASHBOARD_MYSQL_BACKUP_FILE:-}"
  if [[ -z "$configured" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$configured" = /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s' "$BASE/$configured"
  fi
}

resolve_dashboard_uploads_source() {
  local configured
  configured="${DASHBOARD_UPLOADS_SOURCE:-}"
  if [[ -z "$configured" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$configured" = /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s' "$BASE/$configured"
  fi
}

restore_dashboard_postgres_if_needed() {
  local backup_file force_restore

  force_restore="${FORCE_DASHBOARD_POSTGRES_RESTORE:-false}"
  backup_file="$(resolve_dashboard_postgres_backup_file)"
  if [[ -z "$backup_file" ]]; then
    if is_truthy "$force_restore"; then
      die "FORCE_DASHBOARD_POSTGRES_RESTORE is true but DASHBOARD_POSTGRES_BACKUP_FILE is not set"
    fi
    info "DASHBOARD_POSTGRES_BACKUP_FILE is not set; skipping dashboard postgres restore"
    return 0
  fi
  [[ -f "$backup_file" ]] || die "Configured DASHBOARD_POSTGRES_BACKUP_FILE not found: $backup_file"

  if ! confirm_restore "dashboard postgres from $backup_file"; then
    info "Skipped dashboard postgres restore by user choice"
    return 0
  fi

  if dash_postgres_has_user_tables && ! is_truthy "$force_restore"; then
    info "Dashboard postgres already has tables; skipping restore (set FORCE_DASHBOARD_POSTGRES_RESTORE=true to force)"
    return 0
  fi

  log "Restoring dashboard postgres from $backup_file ..."
  if docker exec -i "$DASHBOARD_POSTGRES_CONTAINER" pg_restore -U postgres -d viz --clean < "$backup_file"; then
    log "Dashboard postgres restore completed"
  else
    warn "Dashboard postgres restore finished with PostgreSQL errors; continuing deployment"
  fi
}

restore_dashboard_mysql_if_needed() {
  local backup_file force_restore mysql_auth
  local restore_user restore_password restore_db

  force_restore="${FORCE_DASHBOARD_MYSQL_RESTORE:-false}"
  backup_file="$(resolve_dashboard_mysql_backup_file)"
  if [[ -z "$backup_file" ]]; then
    if is_truthy "$force_restore"; then
      die "FORCE_DASHBOARD_MYSQL_RESTORE is true but DASHBOARD_MYSQL_BACKUP_FILE is not set"
    fi
    info "DASHBOARD_MYSQL_BACKUP_FILE is not set; skipping dashboard mysql restore"
    return 0
  fi
  [[ -f "$backup_file" ]] || die "Configured DASHBOARD_MYSQL_BACKUP_FILE not found: $backup_file"

  if ! confirm_restore "dashboard mysql from $backup_file"; then
    info "Skipped dashboard mysql restore by user choice"
    return 0
  fi

  if dash_mysql_has_user_tables && ! is_truthy "$force_restore"; then
    info "Dashboard mysql already has tables; skipping restore (set FORCE_DASHBOARD_MYSQL_RESTORE=true to force)"
    return 0
  fi

  log "Restoring dashboard mysql from $backup_file ..."
  restore_user="${DASHBOARD_MYSQL_RESTORE_USER:-${DASHBOARD_MYSQL_WP_USER:-wordpress}}"
  restore_password="${DASHBOARD_MYSQL_RESTORE_PASSWORD:-${DASHBOARD_MYSQL_WP_PASSWORD:-}}"
  restore_db="${DASHBOARD_MYSQL_RESTORE_DB:-${DASHBOARD_MYSQL_DB_NAME:-wordpress}}"

  if [[ -n "$restore_password" ]]; then
    mysql_auth="-u${restore_user} -p${restore_password} ${restore_db}"
  else
    mysql_auth="-u${restore_user} ${restore_db}"
  fi

  if docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc "mysql $mysql_auth" < "$backup_file"; then
    log "Dashboard mysql restore completed"
  else
    warn "Dashboard mysql restore finished with errors; continuing deployment"
  fi
}

restore_dashboard_uploads_if_needed() {
  local src force_restore src_base ext volume_name restore_ok

  force_restore="${FORCE_DASHBOARD_UPLOADS_RESTORE:-false}"
  src="$(resolve_dashboard_uploads_source)"
  if [[ -z "$src" ]]; then
    if is_truthy "$force_restore"; then
      die "FORCE_DASHBOARD_UPLOADS_RESTORE is true but DASHBOARD_UPLOADS_SOURCE is not set"
    fi
    info "DASHBOARD_UPLOADS_SOURCE is not set; skipping dashboard uploads restore"
    return 0
  fi

  volume_name="${DASH_PROJECT}_wordpress"

  if ! confirm_restore "dashboard uploads from $src"; then
    info "Skipped dashboard uploads restore by user choice"
    return 0
  fi

  if ! is_truthy "$force_restore"; then
    if docker run --rm -v "$volume_name:/var/www/html" busybox sh -lc '[ -d /var/www/html/wp-content/uploads ] && [ "$(ls -A /var/www/html/wp-content/uploads 2>/dev/null)" ]' >/dev/null 2>&1; then
      info "Dashboard uploads already exist; skipping restore (set FORCE_DASHBOARD_UPLOADS_RESTORE=true to force)"
      return 0
    fi
  fi

  src_base="$(basename "$src")"
  log "Restoring dashboard uploads from $src ..."
  restore_ok=true

  if [[ -d "$src" ]]; then
    if ! docker run --rm \
      -v "$volume_name:/var/www/html" \
      -v "$BASE:/backup:ro" \
      busybox sh -lc "mkdir -p /var/www/html/wp-content/uploads && cp -a /backup/${src_base}/. /var/www/html/wp-content/uploads/"; then
      restore_ok=false
    fi
  else
    ext="${src_base##*.}"
    case "$src_base" in
      *.tar.gz|*.tgz)
        if ! docker run --rm \
          -v "$volume_name:/var/www/html" \
          -v "$BASE:/backup:ro" \
          busybox sh -lc "mkdir -p /var/www/html/wp-content/uploads && tar -xzf /backup/${src_base} -C /var/www/html/wp-content/uploads"; then
          restore_ok=false
        fi
        ;;
      *.tar)
        if ! docker run --rm \
          -v "$volume_name:/var/www/html" \
          -v "$BASE:/backup:ro" \
          busybox sh -lc "mkdir -p /var/www/html/wp-content/uploads && tar -xf /backup/${src_base} -C /var/www/html/wp-content/uploads"; then
          restore_ok=false
        fi
        ;;
      *)
        warn "Unsupported dashboard uploads source: $src_base (use directory, .tar.gz, .tgz, or .tar); skipping uploads restore"
        return 0
        ;;
    esac
  fi

  if [[ "$restore_ok" == true ]]; then
    log "Dashboard uploads restore completed"
  else
    warn "Dashboard uploads restore finished with errors; continuing deployment"
  fi
}

update_dashboard_site_url() {
  local raw_url site_url home_url
  local db_name db_user db_password mysql_auth

  raw_url="${DASHBOARD_SITE_URL:-}"
  if [[ -z "$raw_url" ]]; then
    warn "DASHBOARD_SITE_URL is empty; skipping WordPress siteurl/home update"
    return 0
  fi

  site_url="$(escape_sql_literal "$raw_url")"
  home_url="$site_url"

  db_name="${DASHBOARD_MYSQL_DB_NAME:-wordpress}"
  db_user="${DASHBOARD_MYSQL_WP_USER:-wordpress}"
  db_password="${DASHBOARD_MYSQL_WP_PASSWORD:-}"

  if [[ -n "$db_password" ]]; then
    mysql_auth="-u${db_user} -p${db_password} ${db_name}"
  else
    mysql_auth="-u${db_user} ${db_name}"
  fi

  log "Updating WordPress siteurl to '${site_url}' and home to '${home_url}'"
  docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc \
    "mysql ${mysql_auth} -e \"UPDATE wp_options SET option_value='${site_url}' WHERE option_name='siteurl'; UPDATE wp_options SET option_value='${home_url}' WHERE option_name='home';\""

  info "Verifying WordPress siteurl/home:"
  docker exec -i "$DASHBOARD_MYSQL_CONTAINER" sh -lc \
    "mysql ${mysql_auth} -e \"SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');\""
}

init_dashboard_data() {
  log "Waiting for dashboard DB readiness..."
  wait_for_dashboard_dbs
  restore_dashboard_postgres_if_needed
  restore_dashboard_mysql_if_needed
  restore_dashboard_uploads_if_needed
  update_dashboard_site_url
}

install_linux_packages_noninteractive() {
  # Works when running as root or when passwordless sudo is available.
  if command -v apt-get >/dev/null 2>&1; then
    if [[ "$(id -u)" -eq 0 ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      sudo -n DEBIAN_FRONTEND=noninteractive apt-get update
      sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      return 0
    fi
  fi
  return 1
}

ensure_aws_install_prereqs() {
  local missing=()

  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v unzip >/dev/null 2>&1 || missing+=("unzip")

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  warn "Missing prerequisites for AWS CLI install: ${missing[*]}"

  case "$(uname -s)" in
    Linux)
      if install_linux_packages_noninteractive ca-certificates "${missing[@]}"; then
        log "Installed AWS CLI prerequisites: ${missing[*]}"
      else
        die "Cannot auto-install ${missing[*]} on Linux without apt/root/passwordless sudo. Install them manually and rerun."
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        log "Installing prerequisites via Homebrew: ${missing[*]}"
        brew install "${missing[@]}"
      else
        die "Missing ${missing[*]} and Homebrew is not installed. Install prerequisites manually and rerun."
      fi
      ;;
    *)
      die "Unsupported OS for auto-installing AWS prerequisites: $(uname -s)"
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl is still missing after install attempt"
  command -v unzip >/dev/null 2>&1 || die "unzip is still missing after install attempt"
}

install_aws_cli_linux_local() {
  local arch tmpdir

  case "$(uname -m)" in
    x86_64)
      arch="x86_64"
      ;;
    aarch64|arm64)
      arch="aarch64"
      ;;
    *)
      die "Unsupported Linux architecture for AWS CLI auto-install: $(uname -m)"
      ;;
  esac

  ensure_aws_install_prereqs

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  log "Downloading AWS CLI v2 (${arch})..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmpdir/awscliv2.zip"
  unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"

  log "Installing AWS CLI to user space ($HOME/.local/bin)..."
  "$tmpdir/aws/install" -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" --update
  export PATH="$HOME/.local/bin:$PATH"
}

ensure_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi

  warn "aws CLI not found; attempting automatic install..."

  case "$(uname -s)" in
    Linux)
      ensure_aws_install_prereqs
      log "Attempting to install awscli via apt-get..."
      if install_linux_packages_noninteractive awscli; then
        log "Installed awscli via apt-get"
      elif command -v apt-get >/dev/null 2>&1; then
        warn "No non-interactive sudo available; falling back to user-space AWS CLI install"
        install_aws_cli_linux_local
      else
        ensure_aws_install_prereqs
        install_aws_cli_linux_local
      fi
      ;;
    Darwin)
      ensure_aws_install_prereqs
      if command -v brew >/dev/null 2>&1; then
        log "Installing awscli via Homebrew..."
        brew install awscli
      else
        die "aws CLI is missing and Homebrew is not installed. Install Homebrew+awscli or install aws manually."
      fi
      ;;
    *)
      die "Unsupported OS for AWS CLI auto-install: $(uname -s)"
      ;;
  esac

  command -v aws >/dev/null 2>&1 || die "AWS CLI installation failed; install 'aws' manually and retry"
}

ecr_login() {
  local image="${AMP_IMAGE:-}"
  local registry region account

  if [[ -z "$image" ]]; then
    warn "AMP_IMAGE not set in .env; skipping ECR login"
    return 0
  fi

  registry=$(echo "$image" | cut -d/ -f1)
  if [[ "$registry" != *".dkr.ecr."* ]]; then
    info "AMP_IMAGE is not ECR ($registry); skipping ECR login"
    return 0
  fi

  region=$(echo "$registry" | sed 's/.*\.dkr\.ecr\.\([^.]*\)\..*/\1/')
  account=$(echo "$registry" | cut -d. -f1)

  ensure_aws_cli

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    die "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set in $ENV_FILE for ECR pulls"
  fi

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$region}"
  export AWS_EC2_METADATA_DISABLED=true

  log "Authenticating to AWS ECR (account=$account, region=$region)..."
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
}

registry_login() {
  local image registry

  image="${DASHBOARD_IMAGE:-${REPO:-}}"
  if [[ -z "$image" ]]; then
    warn "DASHBOARD_IMAGE/REPO is not set; skipping dashboard registry login"
    return 0
  fi

  registry=$(echo "$image" | cut -d/ -f1)
  if [[ -z "$registry" || "$registry" != *"."* ]]; then
    warn "Could not determine dashboard registry from '$image'; skipping login"
    return 0
  fi

  if [[ -n "${DASHBOARD_REGISTRY_USER:-}" && -n "${DASHBOARD_REGISTRY_PASSWORD:-}" ]]; then
    log "Logging in to registry $registry..."
    echo "$DASHBOARD_REGISTRY_PASSWORD" | docker login "$registry" --username "$DASHBOARD_REGISTRY_USER" --password-stdin
  else
    info "DASHBOARD_REGISTRY_USER/DASHBOARD_REGISTRY_PASSWORD not set; relying on existing docker auth for $registry"
  fi
}

pull_images() {
  if [[ "$USE_TRAEFIK" == "true" ]]; then
    log "Pulling Traefik images..."
    traefik_compose pull --quiet
  else
    info "Traefik is disabled; skipping Traefik image pull"
  fi

  if target_includes_amp; then
    log "Pulling AMP images..."
    amp_compose pull --quiet
  else
    info "AMP is excluded from this run (--dashboard-only); skipping AMP image pull"
  fi

  if target_includes_dashboard; then
    log "Pulling dashboard images..."
    dash_compose pull --quiet
  else
    info "Dashboard is excluded from this run (--amp-only); skipping dashboard image pull"
  fi
}

up_all() {
  if [[ "$USE_TRAEFIK" == "true" ]]; then
    log "Starting Traefik stack..."
    traefik_compose up -d --remove-orphans
  else
    info "Traefik is disabled; skipping Traefik startup"
  fi

  if target_includes_amp; then
    log "Starting AMP database service..."
    amp_compose up -d amp-db
    init_amp_db

    log "Starting AMP application service..."
    amp_compose up -d amp --remove-orphans
  else
    info "AMP is excluded from this run (--dashboard-only); skipping AMP startup"
  fi

  if target_includes_dashboard; then
    log "Starting dashboard database services..."
    dash_compose up -d mysql postgres
    init_dashboard_data

    log "Starting dashboard application services..."
    dash_compose up -d --remove-orphans
  else
    info "Dashboard is excluded from this run (--amp-only); skipping dashboard startup"
  fi
}

down_all() {
  if target_includes_dashboard; then
    warn "Stopping dashboard stack..."
    dash_compose down || true
  else
    info "Dashboard is excluded from this run (--amp-only); leaving dashboard stack as-is"
  fi

  if target_includes_amp; then
    warn "Stopping AMP stack..."
    amp_compose down || true
  else
    info "AMP is excluded from this run (--dashboard-only); leaving AMP stack as-is"
  fi

  if [[ "$USE_TRAEFIK" == "true" ]]; then
    warn "Stopping Traefik stack..."
    traefik_compose down || true
  else
    info "Traefik is disabled; nothing to stop there"
  fi
}

show_status() {
  if [[ "$USE_TRAEFIK" == "true" ]]; then
    info "================ Traefik ================"
    traefik_compose ps
  else
    info "================ Traefik ================"
    info "Disabled"
  fi

  if target_includes_amp; then
    info "================ AMP ===================="
    amp_compose ps
  fi

  if target_includes_dashboard; then
    info "================ Dashboard =============="
    dash_compose ps
  fi
}

show_logs() {
  local target="${1:-help}"
  local service="${2:-}"

  case "$target" in
    traefik)
      [[ "$USE_TRAEFIK" == "true" ]] || die "Traefik is disabled for this run"
      if [[ -n "$service" ]]; then
        traefik_compose logs -f "$service"
      else
        traefik_compose logs -f
      fi
      ;;
    amp)
      if [[ -n "$service" ]]; then
        amp_compose logs -f "$service"
      else
        amp_compose logs -f
      fi
      ;;
    dashboard)
      if [[ -n "$service" ]]; then
        dash_compose logs -f "$service"
      else
        dash_compose logs -f
      fi
      ;;
    *)
      docker logs -f "$target"
      ;;
  esac
}

COMMAND="${1:-help}"
shift || true
parse_common_flags "$@"

case "$COMMAND" in
  help|--help|-h)
    usage
    ;;
  deploy)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    ecr_login
    registry_login
    pull_images
    up_all
    log "Deploy complete."
    show_status
    ;;
  up)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    up_all
    log "Stacks started."
    show_status
    ;;
  down)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    down_all
    log "Stacks stopped."
    ;;
  restart)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    down_all
    up_all
    log "Restart complete."
    show_status
    ;;
  pull)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    ecr_login
    registry_login
    pull_images
    log "Pull complete. Run '$0 up' to apply updated images."
    ;;
  status)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    show_status
    ;;
  logs)
    check_requirements
    load_env
    resolve_traefik_mode
    resolve_deploy_target
    show_logs "${REMAINING_ARGS[0]:-help}" "${REMAINING_ARGS[1]:-}"
    ;;
  *)
    warn "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
