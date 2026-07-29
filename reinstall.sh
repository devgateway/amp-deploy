#!/usr/bin/env bash
# =============================================================================
# reinstall.sh — Reinstall or upgrade AMP and/or amp-dashboard
#
# Two modes:
#
#   --keep-data (default)
#     Upgrade in place: pull the latest images and recreate containers.
#     Named volumes (databases, uploads) are left untouched.
#     Equivalent to: ./deploy.sh deploy [scope/traefik flags]
#
#   --wipe-data
#     Destructive reinstall: stop the selected stack(s) and remove their
#     named volumes (databases, uploads), then pull fresh images and bring
#     everything back up from scratch. Requires confirmation unless --yes
#     is given. Runs ./backup.sh first (scoped to the same target) unless
#     --skip-backup is given.
#
# Usage:
#   ./reinstall.sh [--keep-data|--wipe-data] [--amp-only|--dashboard-only] \
#                  [--with-traefik|--without-traefik] [--yes] [--skip-backup] \
#                  [--help]
#
# Env toggles (same precedence as deploy.sh: CLI flag > .env > default):
#   DEPLOY_TARGET=all|amp|dashboard
#   USE_TRAEFIK=true|false
#   ASSUME_YES_WIPE=true|false   # non-interactive confirmation for --wipe-data
# =============================================================================

set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$BASE/.env}"

AMP_COMPOSE="${AMP_COMPOSE:-$BASE/amp/docker-compose.yml}"
DASH_COMPOSE="${DASH_COMPOSE:-$BASE/amp-dashboard/docker-compose.yml}"
DASH_TRAEFIK_OVERRIDE="${DASH_TRAEFIK_OVERRIDE:-$BASE/amp-dashboard/docker-compose.traefik.yml}"

AMP_PROJECT="${AMP_PROJECT:-amp}"
DASH_PROJECT="${DASH_PROJECT:-amp-dashboard}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
info() { echo -e "${CYAN}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %T')]${NC} $*"; }
die()  { echo -e "${RED}[$(date '+%Y-%m-%d %T')] ERROR:${NC} $*" >&2; exit 1; }

DEPLOY_TARGET=""
CLI_DEPLOY_TARGET=""
USE_TRAEFIK_FLAG=""
DATA_MODE="keep-data"
ASSUME_YES=false
SKIP_BACKUP=false

usage() {
  sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amp-only)
      CLI_DEPLOY_TARGET="amp"
      shift
      ;;
    --dashboard-only)
      CLI_DEPLOY_TARGET="dashboard"
      shift
      ;;
    --with-traefik|--without-traefik)
      USE_TRAEFIK_FLAG="$1"
      shift
      ;;
    --keep-data)
      DATA_MODE="keep-data"
      shift
      ;;
    --wipe-data)
      DATA_MODE="wipe-data"
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --skip-backup)
      SKIP_BACKUP=true
      shift
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

resolve_deploy_target() {
  local requested requested_lc
  requested="${CLI_DEPLOY_TARGET:-${DEPLOY_TARGET:-all}}"
  requested_lc="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"
  case "$requested_lc" in
    all|both|"") DEPLOY_TARGET="all" ;;
    amp) DEPLOY_TARGET="amp" ;;
    dashboard|dash) DEPLOY_TARGET="dashboard" ;;
    *) die "Invalid DEPLOY_TARGET value: '$requested' (expected all/amp/dashboard)" ;;
  esac
}

target_includes_amp() {
  [[ "$DEPLOY_TARGET" == "all" || "$DEPLOY_TARGET" == "amp" ]]
}

target_includes_dashboard() {
  [[ "$DEPLOY_TARGET" == "all" || "$DEPLOY_TARGET" == "dashboard" ]]
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  docker compose version >/dev/null 2>&1 || die "'docker compose' plugin not found"
  [[ -x "$BASE/deploy.sh" ]] || die "deploy.sh not found or not executable at $BASE/deploy.sh"
  if target_includes_amp; then
    [[ -f "$AMP_COMPOSE" ]] || die "AMP compose not found at $AMP_COMPOSE"
  fi
  if target_includes_dashboard; then
    [[ -f "$DASH_COMPOSE" ]] || die "Dashboard compose not found at $DASH_COMPOSE"
  fi
}

amp_compose() {
  docker compose -f "$AMP_COMPOSE" --env-file "$ENV_FILE" -p "$AMP_PROJECT" "$@"
}

dash_compose() {
  local cmd=(docker compose -f "$DASH_COMPOSE" --env-file "$ENV_FILE" -p "$DASH_PROJECT")
  if [[ -f "$DASH_TRAEFIK_OVERRIDE" ]]; then
    cmd+=( -f "$DASH_TRAEFIK_OVERRIDE" )
  fi
  "${cmd[@]}" "$@"
}

confirm_wipe() {
  local label="$1" answer answer_lc

  if is_truthy "$ASSUME_YES"; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    if is_truthy "${ASSUME_YES_WIPE:-false}"; then
      info "Non-interactive mode with ASSUME_YES_WIPE=true; proceeding with ${label} wipe"
      return 0
    fi
    die "Non-interactive mode and --wipe-data requested for ${label}; pass --yes or set ASSUME_YES_WIPE=true to confirm"
  fi

  warn "This will DELETE ${label} containers AND named volumes (databases/uploads). This cannot be undone."
  read -r -p "Type 'wipe ${label}' to confirm, or anything else to abort: " answer
  answer_lc="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  if [[ "$answer_lc" == "wipe ${label,,}" ]]; then
    return 0
  fi
  warn "Aborted ${label} wipe."
  return 1
}

is_truthy() {
  local value_lc
  value_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value_lc" == "true" || "$value_lc" == "1" || "$value_lc" == "yes" || "$value_lc" == "y" ]]
}

run_backup() {
  if is_truthy "$SKIP_BACKUP"; then
    warn "Skipping pre-wipe backup (--skip-backup passed)"
    return 0
  fi

  local backup_args=()
  case "$DEPLOY_TARGET" in
    amp) backup_args=(--amp-only) ;;
    dashboard) backup_args=(--dashboard-only) ;;
    all) backup_args=() ;;
  esac

  log "Running pre-wipe backup (${backup_args[*]:-both stacks})..."
  if ! "$BASE/backup.sh" "${backup_args[@]}"; then
    die "Backup failed; aborting wipe. Re-run with --skip-backup to bypass (not recommended)."
  fi
}

wipe_data() {
  if target_includes_amp; then
    if confirm_wipe "AMP"; then
      warn "Wiping AMP stack (containers + volumes)..."
      amp_compose down -v --remove-orphans || true
      log "AMP wipe complete."
    else
      die "AMP wipe was not confirmed; aborting reinstall."
    fi
  fi

  if target_includes_dashboard; then
    if confirm_wipe "Dashboard"; then
      warn "Wiping Dashboard stack (containers + volumes)..."
      dash_compose down -v --remove-orphans || true
      log "Dashboard wipe complete."
    else
      die "Dashboard wipe was not confirmed; aborting reinstall."
    fi
  fi
}

run_deploy() {
  local args=(deploy)
  case "$DEPLOY_TARGET" in
    amp) args+=(--amp-only) ;;
    dashboard) args+=(--dashboard-only) ;;
    all) ;;
  esac
  [[ -n "$USE_TRAEFIK_FLAG" ]] && args+=("$USE_TRAEFIK_FLAG")

  log "Delegating to deploy.sh ${args[*]} ..."
  "$BASE/deploy.sh" "${args[@]}"
}

load_env
resolve_deploy_target
check_requirements

log "Reinstall mode: ${DATA_MODE} (target: ${DEPLOY_TARGET})"

if [[ "$DATA_MODE" == "wipe-data" ]]; then
  run_backup
  wipe_data
else
  info "Keeping existing data (volumes untouched); this is an in-place upgrade."
fi

run_deploy
log "Reinstall complete."
