#!/usr/bin/env bash
set -Eeuo pipefail

ORG="Miraigrid"
API_VERSION="2026-03-10"
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_ROOT="/opt/miraigrid-runners"
LEGACY_DIR="/opt/miraigrid-runner"
RUNNER_NAME="$(hostname -s)"
RUNNER_LABELS="miraigrid,docker"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh --name NAME [--labels LABEL1,LABEL2,...]

Examples:
  sudo ./install.sh --name netcup-01
  sudo ./install.sh --name netcup-02 --labels miraigrid,docker,medium

Each NAME gets its own Docker container, Compose project, runner state and _work directory.
Existing legacy installs under /opt/miraigrid-runner are left untouched.
EOF
}

NAME_WAS_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      RUNNER_NAME="${2:?missing value for --name}"
      NAME_WAS_SET=1
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
  echo "Please run with sudo: sudo ./install.sh --name NAME" >&2
  exit 1
fi

if [[ ! -f compose.yml ]]; then
  echo "Run this script from the repository directory." >&2
  exit 1
fi

if [[ "$NAME_WAS_SET" -ne 1 ]]; then
  echo "--name is required for new multi-runner installs." >&2
  echo "This prevents accidentally colliding with an existing runner on the same host." >&2
  usage >&2
  exit 1
fi

if [[ ! "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Runner name may contain only letters, numbers, dot, underscore and hyphen." >&2
  exit 1
fi

slugify() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$value" ]]; then
    echo "Runner name must contain at least one letter or number." >&2
    exit 1
  fi
  printf '%s' "$value"
}

RUNNER_SLUG="$(slugify "$RUNNER_NAME")"
RUNNER_DIR="${RUNNER_ROOT}/${RUNNER_SLUG}"
COMPOSE_PROJECT="miraigrid-${RUNNER_SLUG}"
META_FILE="${RUNNER_DIR}/.miraigrid-bootstrap"

install_host_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Automatic dependency installation supports Debian/Ubuntu hosts only." >&2
    echo "On another Linux distribution, preinstall curl, jq, Docker Engine and Docker Compose v2." >&2
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

if ! command -v curl >/dev/null 2>&1 || \
   ! command -v jq >/dev/null 2>&1 || \
   ! command -v docker >/dev/null 2>&1; then
  install_host_dependencies
fi

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

# Protect an existing first-generation runner from being replaced by a new
# runner with the same GitHub name.
if [[ -f "${LEGACY_DIR}/.runner" ]]; then
  LEGACY_NAME="$(jq -r '.agentName // empty' "${LEGACY_DIR}/.runner" 2>/dev/null || true)"
  if [[ -n "$LEGACY_NAME" && "$LEGACY_NAME" == "$RUNNER_NAME" ]]; then
    echo "A legacy runner named '${RUNNER_NAME}' already exists at ${LEGACY_DIR}." >&2
    echo "Choose a different --name for the additional runner." >&2
    exit 1
  fi
fi

DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
export DOCKER_GID RUNNER_DIR RUNNER_IMAGE

compose() {
  docker compose -p "$COMPOSE_PROJECT" "$@"
}

if [[ -f "$META_FILE" ]]; then
  stored_name="$(sed -n 's/^RUNNER_NAME=//p' "$META_FILE" | head -n1 || true)"
  if [[ -n "$stored_name" && "$stored_name" != "$RUNNER_NAME" ]]; then
    echo "Runner directory collision: ${RUNNER_DIR} belongs to '${stored_name}'." >&2
    echo "Choose a different --name." >&2
    exit 1
  fi
fi

echo "Runner name:     ${RUNNER_NAME}"
echo "Runner dir:      ${RUNNER_DIR}"
echo "Compose project: ${COMPOSE_PROJECT}"
if [[ -f "${LEGACY_DIR}/.runner" ]]; then
  echo "Legacy runner detected at ${LEGACY_DIR}; it will not be modified."
fi

echo "Pulling official GitHub Actions runner image..."
compose pull runner

if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
  mkdir -p "$RUNNER_DIR"
  docker run --rm --user 0 \
    -e RUNNER_DIR="$RUNNER_DIR" \
    -v "${RUNNER_DIR}:${RUNNER_DIR}" \
    "$RUNNER_IMAGE" \
    bash -lc 'cp -a /home/runner/. "$RUNNER_DIR"/ && chown -R 1001:1001 "$RUNNER_DIR"'
fi

cat > "$META_FILE" <<EOF
RUNNER_NAME=${RUNNER_NAME}
RUNNER_SLUG=${RUNNER_SLUG}
COMPOSE_PROJECT=${COMPOSE_PROJECT}
RUNNER_DIR=${RUNNER_DIR}
EOF
chmod 644 "$META_FILE"

if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  echo "Runner is already registered. Ensuring only this runner is running..."
  compose up -d runner
  compose ps runner
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
compose run --rm --no-deps \
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

compose up -d runner

echo
echo "Runner is online (or connecting)."
compose ps runner
