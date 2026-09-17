#!/usr/bin/env bash
set -Eeuo pipefail

ORG="Miraigrid"
API_VERSION="2026-03-10"
RUNNER_NAME="$(hostname -s)"
RUNNER_LABELS="miraigrid,docker"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--name NAME] [--labels LABEL1,LABEL2,...]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      RUNNER_NAME="${2:?missing value for --name}"
      shift 2
      ;;
    --labels)
      RUNNER_LABELS="${2:?missing value for --labels}"
      shift 2
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
  echo "Please run with sudo: sudo ./install.sh" >&2
  exit 1
fi

if [[ ! -f compose.yml ]]; then
  echo "Run this script from the repository directory." >&2
  exit 1
fi

install_host_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Docker is not installed and automatic installation currently supports Debian/Ubuntu hosts only." >&2
    exit 1
  fi

  apt-get update
  apt-get install -y ca-certificates curl jq

  if ! command -v docker >/dev/null 2>&1; then
    tmp_script="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$tmp_script"
    sh "$tmp_script"
    rm -f "$tmp_script"
  fi
}

install_host_dependencies

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required (the 'docker compose' command)." >&2
  exit 1
fi

if [[ ! -S /var/run/docker.sock ]]; then
  systemctl start docker 2>/dev/null || true
fi

if [[ ! -S /var/run/docker.sock ]]; then
  echo "/var/run/docker.sock was not found." >&2
  exit 1
fi

DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
printf 'DOCKER_GID=%s\n' "$DOCKER_GID" > .env
chmod 600 .env

echo "Pulling official GitHub Actions runner image..."
docker compose pull runner

# If the persistent runner volume is already configured, simply ensure it is running.
if docker compose run --rm --no-deps runner bash -lc 'test -f .runner' >/dev/null 2>&1; then
  echo "Runner is already registered. Ensuring it is running..."
  docker compose up -d runner
  docker compose ps runner
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
  "https://api.github.com/orgs/${ORG}/actions/runners/registration-token")"

REGISTRATION_TOKEN="$(jq -r '.token // empty' <<<"$response")"
if [[ -z "$REGISTRATION_TOKEN" ]]; then
  echo "GitHub did not return a runner registration token." >&2
  exit 1
fi

unset GITHUB_ADMIN_TOKEN

echo "Registering runner '${RUNNER_NAME}' with labels '${RUNNER_LABELS}'..."
docker compose run --rm --no-deps \
  -e RUNNER_REGISTRATION_TOKEN="$REGISTRATION_TOKEN" \
  -e RUNNER_NAME="$RUNNER_NAME" \
  -e RUNNER_LABELS="$RUNNER_LABELS" \
  runner bash -lc '
    ./config.sh \
      --unattended \
      --url https://github.com/Miraigrid \
      --token "$RUNNER_REGISTRATION_TOKEN" \
      --name "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS" \
      --work _work \
      --replace
  '

unset REGISTRATION_TOKEN

docker compose up -d runner

echo
echo "Runner is online (or connecting)."
docker compose ps runner
