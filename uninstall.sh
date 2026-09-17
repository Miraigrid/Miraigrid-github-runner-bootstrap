#!/usr/bin/env bash
set -Eeuo pipefail

ORG="Miraigrid"
API_VERSION="2026-03-10"
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_ROOT="/opt/miraigrid-runners"
LEGACY_DIR="/opt/miraigrid-runner"
RUNNER_NAME=""
LEGACY=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./uninstall.sh --name NAME
  sudo ./uninstall.sh --legacy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      RUNNER_NAME="${2:?missing value for --name}"
      shift 2
      ;;
    --legacy)
      LEGACY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi

if [[ ! -f compose.yml ]]; then
  echo "Run this script from the repository directory." >&2
  exit 1
fi

if [[ "$LEGACY" -eq 1 && -n "$RUNNER_NAME" ]]; then
  echo "Use either --name NAME or --legacy, not both." >&2
  exit 1
fi

if [[ "$LEGACY" -eq 0 && -z "$RUNNER_NAME" ]]; then
  usage >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required." >&2
  exit 1
fi

slugify() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$value" ]] || exit 1
  printf '%s' "$value"
}

if [[ "$LEGACY" -eq 1 ]]; then
  RUNNER_DIR="$LEGACY_DIR"
  COMPOSE_PROJECT=""
else
  RUNNER_SLUG="$(slugify "$RUNNER_NAME")"
  RUNNER_DIR="${RUNNER_ROOT}/${RUNNER_SLUG}"
  COMPOSE_PROJECT="miraigrid-${RUNNER_SLUG}"
fi

if [[ -S /var/run/docker.sock ]]; then
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
else
  echo "/var/run/docker.sock was not found." >&2
  exit 1
fi
export DOCKER_GID RUNNER_DIR RUNNER_IMAGE

compose() {
  if [[ -n "$COMPOSE_PROJECT" ]]; then
    docker compose -p "$COMPOSE_PROJECT" "$@"
  else
    docker compose "$@"
  fi
}

if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
  compose down --remove-orphans 2>/dev/null || true
  rm -rf "$RUNNER_DIR"
  echo "No registered runner state was found. Local state removed."
  exit 0
fi

if [[ -z "${GITHUB_ADMIN_TOKEN:-}" ]]; then
  read -r -s -p "GitHub fine-grained PAT (Self-hosted runners: Read and write): " GITHUB_ADMIN_TOKEN
  echo
fi

if [[ -z "$GITHUB_ADMIN_TOKEN" ]]; then
  echo "GitHub token cannot be empty." >&2
  exit 1
fi

response="$(curl -fsSL \
  -X POST \
  -H 'Accept: application/vnd.github+json' \
  -H "Authorization: Bearer ${GITHUB_ADMIN_TOKEN}" \
  -H "X-GitHub-Api-Version: ${API_VERSION}" \
  "https://api.github.com/orgs/${ORG}/actions/runners/remove-token")"

REMOVE_TOKEN="$(jq -r '.token // empty' <<<"$response")"
if [[ -z "$REMOVE_TOKEN" ]]; then
  echo "GitHub did not return a runner removal token." >&2
  exit 1
fi

unset GITHUB_ADMIN_TOKEN

compose stop runner 2>/dev/null || true
compose run --rm --no-deps \
  -e RUNNER_REMOVE_TOKEN="$REMOVE_TOKEN" \
  runner bash -lc './config.sh remove --token "$RUNNER_REMOVE_TOKEN"'

unset REMOVE_TOKEN

compose down --remove-orphans
rm -rf "$RUNNER_DIR"

echo "Runner unregistered and local runner state removed."
