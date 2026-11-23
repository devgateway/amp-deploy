#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --amp-only|--dashboard-only|--with-traefik|--without-traefik) ;;
    --help|-h)
      printf 'Usage: bash install-windows.sh [--amp-only|--dashboard-only] [--with-traefik|--without-traefik]\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || {
  printf 'Docker is not available. Enable Docker Desktop WSL integration for this distribution.\n' >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  printf 'Docker Compose is not available. Check Docker Desktop WSL integration.\n' >&2
  exit 1
}
docker_os="$(docker info --format '{{.OSType}}')" || {
  printf 'Cannot connect to Docker. Start Docker Desktop and enable WSL integration.\n' >&2
  exit 1
}
if [[ "$docker_os" != "linux" ]]; then
  printf 'Docker must be running Linux containers (current OS: %s).\n' "$docker_os" >&2
  exit 1
fi

if [[ ! -f "$BASE/.env" ]]; then
  umask 077
  cp "$BASE/.env.example" "$BASE/.env"
  printf 'Created %s/.env. Edit it with your image credentials, passwords, and URLs, then rerun this command.\n' "$BASE"
  exit 0
fi

exec bash "$BASE/deploy.sh" deploy "$@"