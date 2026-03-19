#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.bin"
ACT_BIN="${BIN_DIR}/act"
INSTALLER="${BIN_DIR}/act-install.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/nightly-e2e.yml"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

GTC_VERSION="${GTC_VERSION:-0.9.5}"
TEST_TENANT="${TEST_TENANT:-3point}"
ACT_JOB="${ACT_JOB:-e2e-tests}"
ACT_MATRIX_OS="${ACT_MATRIX_OS:-ubuntu-latest}"
ACT_MATRIX_ARCH="${ACT_MATRIX_ARCH:-x64}"
ACT_DOCKER_CONTEXT="${ACT_DOCKER_CONTEXT:-}"
ACT_DOCKER_HOST="${ACT_DOCKER_HOST:-}"
ACT_SECRET_FILE="${ACT_SECRET_FILE:-${ROOT_DIR}/.secrets}"

case "$HOST_ARCH" in
  arm64|aarch64)
    ACT_CONTAINER_ARCHITECTURE="${ACT_CONTAINER_ARCHITECTURE:-linux/arm64}"
    ;;
  *)
    ACT_CONTAINER_ARCHITECTURE="${ACT_CONTAINER_ARCHITECTURE:-linux/amd64}"
    ;;
esac

mkdir -p "$BIN_DIR"

die() {
  echo "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

secret_value_from_file() {
  local key="$1"
  [[ -f "$ACT_SECRET_FILE" ]] || return 0

  local line
  line="$(grep -E "^${key}=" "$ACT_SECRET_FILE" | tail -n 1 || true)"
  printf '%s\n' "${line#*=}"
}

require_secret() {
  local key="$1"
  local value="${!key:-}"

  if [[ -z "$value" ]]; then
    value="$(secret_value_from_file "$key")"
  fi

  if [[ -n "$value" ]]; then
    return
  fi

  die "Missing required secret ${key}. Export it in your shell or add it to ${ACT_SECRET_FILE} before running ci/run_actions.sh."
}

docker_context_exists() {
  local context="$1"
  docker context inspect "$context" >/dev/null 2>&1
}

resolve_docker_host() {
  if [[ -n "$ACT_DOCKER_HOST" ]]; then
    printf '%s\n' "$ACT_DOCKER_HOST"
    return
  fi

  local context="$ACT_DOCKER_CONTEXT"
  if [[ -z "$context" ]]; then
    if [[ "$HOST_OS" == "Darwin" ]] && docker_context_exists desktop-linux; then
      context="desktop-linux"
    else
      context="$(docker context show)"
    fi
  fi

  docker context inspect "$context" --format '{{ .Endpoints.docker.Host }}'
}

install_act() {
  echo "Installing act into ${BIN_DIR}"
  curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh -o "$INSTALLER"
  bash "$INSTALLER" -b "$BIN_DIR"
  rm -f "$INSTALLER"
}

check_docker() {
  require_cmd docker

  local docker_host="$1"

  if DOCKER_HOST="$docker_host" DOCKER_CONTEXT= docker info >/dev/null 2>&1; then
    return
  fi

  if [[ "$HOST_OS" == "Darwin" && -d "/Applications/Docker.app" ]]; then
    die "Docker Desktop is installed but not reachable at ${docker_host}. Start Docker Desktop or set ACT_DOCKER_CONTEXT/ACT_DOCKER_HOST to a running daemon and rerun ci/run_actions.sh."
  fi

  die "Docker is required to run GitHub Actions locally with act. The configured daemon ${docker_host} is not reachable. Set ACT_DOCKER_CONTEXT or ACT_DOCKER_HOST to a running Docker daemon and rerun ci/run_actions.sh."
}

if [[ ! -x "$ACT_BIN" ]]; then
  require_cmd curl
  install_act
fi

if [[ "$ACT_MATRIX_OS" != "ubuntu-latest" ]]; then
  die "act can only run the Linux workflow locally. Set ACT_MATRIX_OS=ubuntu-latest."
fi

require_secret GREENTIC_TENANT_KEY

DOCKER_HOST_RESOLVED="$(resolve_docker_host)"

check_docker "$DOCKER_HOST_RESOLVED"

echo "Using Docker daemon ${DOCKER_HOST_RESOLVED}"

ACT_ARGS=(
  workflow_dispatch
  --workflows "$WORKFLOW"
  --job "$ACT_JOB"
  --rm
  --input "gtc_version=${GTC_VERSION}"
  --input "test_tenant=${TEST_TENANT}"
  --matrix "os:${ACT_MATRIX_OS}"
  --matrix "arch:${ACT_MATRIX_ARCH}"
  --container-architecture "$ACT_CONTAINER_ARCHITECTURE"
  --container-daemon-socket "$DOCKER_HOST_RESOLVED"
)

if [[ -n "${GREENTIC_TENANT_KEY:-}" ]]; then
  ACT_ARGS+=(--secret "GREENTIC_TENANT_KEY=${GREENTIC_TENANT_KEY}")
fi

exec env DOCKER_HOST="$DOCKER_HOST_RESOLVED" DOCKER_CONTEXT= "$ACT_BIN" "${ACT_ARGS[@]}"
