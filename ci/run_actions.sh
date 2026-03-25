#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.bin"
ACT_BIN="${BIN_DIR}/act"
INSTALLER="${BIN_DIR}/act-install.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/nightly-e2e.yml"
HOST_OS="$(uname -s)"

GTC_VERSION="${GTC_VERSION:-latest}"
GREENTIC_TENANT="${GREENTIC_TENANT:-3point}"
ACT_JOB="${ACT_JOB:-e2e-tests}"
ACT_MATRIX_OS="${ACT_MATRIX_OS:-linux}"
ACT_MATRIX_ARCH="${ACT_MATRIX_ARCH:-x64}"
ACT_DOCKER_CONTEXT="${ACT_DOCKER_CONTEXT:-}"
ACT_DOCKER_HOST="${ACT_DOCKER_HOST:-}"
ACT_SECRET_FILE="${ACT_SECRET_FILE:-${ROOT_DIR}/.secrets-provider}"
ACT_PLATFORM_IMAGE="${ACT_PLATFORM_IMAGE:-catthehacker/ubuntu:act-24.04}"
ACT_PULL="${ACT_PULL:-false}"

case "${ACT_MATRIX_ARCH}" in
  arm64|aarch64)
    ACT_CONTAINER_ARCHITECTURE="${ACT_CONTAINER_ARCHITECTURE:-linux/arm64}"
    ;;
  x64|amd64)
    ACT_CONTAINER_ARCHITECTURE="${ACT_CONTAINER_ARCHITECTURE:-linux/amd64}"
    ;;
  *)
    die "Unsupported ACT_MATRIX_ARCH=${ACT_MATRIX_ARCH}. Use x64 or arm64."
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

require_secret_any() {
  local first_key="$1"
  local second_key="$2"

  local first_value="${!first_key:-}"
  if [[ -z "$first_value" ]]; then
    first_value="$(secret_value_from_file "$first_key")"
  fi

  if [[ -n "$first_value" ]]; then
    return
  fi

  local second_value="${!second_key:-}"
  if [[ -z "$second_value" ]]; then
    second_value="$(secret_value_from_file "$second_key")"
  fi

  if [[ -n "$second_value" ]]; then
    return
  fi

  die "Missing required secret ${first_key} (or legacy ${second_key}). Export it in your shell or add it to ${ACT_SECRET_FILE} before running ci/run_actions.sh."
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

act_usable() {
  [[ -x "$ACT_BIN" ]] || return 1
  "$ACT_BIN" --version >/dev/null 2>&1
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

if ! act_usable; then
  require_cmd curl
  rm -f "$ACT_BIN"
  install_act
fi

if [[ "$ACT_MATRIX_OS" != "linux" ]]; then
  die "act can only run the Linux workflow locally. Set ACT_MATRIX_OS=linux."
fi

require_secret_any GREENTIC_TENANT_TOKEN GREENTIC_TENANT_KEY

DOCKER_HOST_RESOLVED="$(resolve_docker_host)"

check_docker "$DOCKER_HOST_RESOLVED"

echo "Using Docker daemon ${DOCKER_HOST_RESOLVED}"

ACT_ARGS=(
  workflow_dispatch
  --workflows "$WORKFLOW"
  --job "$ACT_JOB"
  --rm
  --pull="${ACT_PULL}"
  --input "gtc_version=${GTC_VERSION}"
  --input "greentic_tenant=${GREENTIC_TENANT}"
  --matrix "os:${ACT_MATRIX_OS}"
  --matrix "arch:${ACT_MATRIX_ARCH}"
  -P "ubuntu-24.04=${ACT_PLATFORM_IMAGE}"
  -P "ubuntu-24.04-arm=${ACT_PLATFORM_IMAGE}"
  --container-architecture "$ACT_CONTAINER_ARCHITECTURE"
  --container-daemon-socket "$DOCKER_HOST_RESOLVED"
)

GREENTIC_TENANT_TOKEN_VALUE="${GREENTIC_TENANT_TOKEN:-}"
if [[ -z "$GREENTIC_TENANT_TOKEN_VALUE" ]]; then
  GREENTIC_TENANT_TOKEN_VALUE="$(secret_value_from_file GREENTIC_TENANT_TOKEN)"
fi
if [[ -z "$GREENTIC_TENANT_TOKEN_VALUE" ]]; then
  GREENTIC_TENANT_TOKEN_VALUE="${GREENTIC_TENANT_KEY:-}"
fi
if [[ -z "$GREENTIC_TENANT_TOKEN_VALUE" ]]; then
  GREENTIC_TENANT_TOKEN_VALUE="$(secret_value_from_file GREENTIC_TENANT_KEY)"
fi

if [[ -n "$GREENTIC_TENANT_TOKEN_VALUE" ]]; then
  ACT_ARGS+=(--secret "GREENTIC_TENANT_TOKEN=${GREENTIC_TENANT_TOKEN_VALUE}")
fi

exec env DOCKER_HOST="$DOCKER_HOST_RESOLVED" DOCKER_CONTEXT= "$ACT_BIN" "${ACT_ARGS[@]}"
