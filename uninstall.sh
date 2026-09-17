#!/usr/bin/env bash
set -Eeuo pipefail

ORG="Miraigrid"
API_VERSION="2026-03-10"
RUNNER_DIR="/opt/miraigrid-runner"

if [[ ${EUID} -ne 0 ]]; then
  echo "Please run with sudo: sudo ./uninstall.sh" >&2
  exit 1
fi

if [[ ! -f compose.yml ]]; then
  echo "Run this script from the repository directory." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required." >&2
  exit 1
fi

if [[ -S /var/run/docker.sock ]]; then
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
  printf 'DOCKER_GID=%s\n' "$DOCKER_GID" > .env
  chmod 600 .env
fi

# Nothing registered locally: just clean up the container and local files.
if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
  docker compose down --remove-orphans 2>/dev/null || true
  rm -rf "$RUNNER_DIR"
  rm -f .env
  echo "No registered runner state was found. Local runner state removed."
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

docker compose stop runner 2>/dev/null || true

docker compose run --rm --no-deps \
  -e RUNNER_REMOVE_TOKEN="$REMOVE_TOKEN" \
  runner bash -lc './config.sh remove --token "$RUNNER_REMOVE_TOKEN"'

unset REMOVE_TOKEN

docker compose down --remove-orphans
rm -rf "$RUNNER_DIR"
rm -f .env

echo "Runner unregistered and local runner state removed."
