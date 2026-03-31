#!/usr/bin/env bash
#
# Local runner for AWS cloud demo E2E.
#
# Flow:
#   gtc wizard -> gtc setup -> gtc start --target aws
#   -> verify /readyz and /v1/web/webchat/demo/
#   -> optional gtc admin tunnel -> admin health/status/admins add/remove
#   -> gtc stop --destroy
#
# Required env:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_REGION or AWS_DEFAULT_REGION (optional, default: eu-north-1)
#
# Optional env:
#   GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND (default: s3)
#   AWS_REGION (default: eu-north-1)
#   AWS_DEFAULT_REGION (default: value of AWS_REGION)
#   DEMO_RELEASE_VERSION (default: v0.1.24)
#   WEBCHAT_EXPECTED_PATH (default: /v1/web/webchat/demo/)
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEMO_RELEASE_VERSION="${DEMO_RELEASE_VERSION:-v0.1.24}"
WEBCHAT_EXPECTED_PATH="${WEBCHAT_EXPECTED_PATH:-/v1/web/webchat/demo/}"
GTC_CMD="${GTC_CMD:-gtc}"
SKIP_ADMIN="${SKIP_ADMIN:-false}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
VERBOSE="${VERBOSE:-false}"
WORK_DIR=""
START_LOG=""
TUNNEL_LOG=""
TUNNEL_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-version)
      DEMO_RELEASE_VERSION="$2"
      shift 2
      ;;
    --bundle-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --skip-admin)
      SKIP_ADMIN=true
      shift
      ;;
    --keep-running)
      KEEP_RUNNING=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    log "$*"
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "missing required env: ${name}"
}

cleanup() {
  if [[ -n "${TUNNEL_PID}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill -TERM "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi

  if [[ "$KEEP_RUNNING" != "true" ]] && [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}/cloud-deploy-demo-bundle" ]]; then
    (
      cd "${WORK_DIR}" || exit 0
      "${GTC_CMD}" stop ./cloud-deploy-demo-bundle --target aws --destroy >/dev/null 2>&1 || true
    )
  fi
}

trap cleanup EXIT

command -v "${GTC_CMD}" >/dev/null 2>&1 || die "gtc not found: ${GTC_CMD}"
require_env AWS_ACCESS_KEY_ID
require_env AWS_SECRET_ACCESS_KEY
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND="${GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND:-s3}"
export GREENTIC_DEPLOY_BUNDLE_SOURCE="https://github.com/greenticai/greentic-demo/releases/download/${DEMO_RELEASE_VERSION}/cloud-deploy-demo.gtbundle"

CREATE_ANSWERS_URL="https://github.com/greenticai/greentic-demo/releases/download/${DEMO_RELEASE_VERSION}/cloud-deploy-demo-create-answers.json"
SETUP_ANSWERS_URL="https://github.com/greenticai/greentic-demo/releases/download/${DEMO_RELEASE_VERSION}/cloud-deploy-demo-setup-answers.json"

if [[ -z "${WORK_DIR}" ]]; then
  WORK_DIR="$(mktemp -d)"
fi

START_LOG="${WORK_DIR}/gtc-start.log"
TUNNEL_LOG="${WORK_DIR}/gtc-admin-tunnel.log"

log "Cloud Demo AWS E2E"
log "=================="
log "Release: ${DEMO_RELEASE_VERSION}"
log "Work dir: ${WORK_DIR}"
log "gtc: $(command -v "${GTC_CMD}")"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
rm -rf ./.greentic ./cloud-deploy-demo-bundle ./cloud-deploy-demo.gtbundle

log ""
log "Step 1: wizard"
"${GTC_CMD}" wizard --answers "${CREATE_ANSWERS_URL}"

log ""
log "Step 2: setup"
"${GTC_CMD}" setup ./cloud-deploy-demo-bundle --answers "${SETUP_ANSWERS_URL}"

log ""
log "Step 3: start aws deploy"
"${GTC_CMD}" start ./cloud-deploy-demo-bundle --target aws | tee "${START_LOG}"

OPERATOR_ENDPOINT="$(grep -o 'http://[^"]*elb[^"]*amazonaws.com' "${START_LOG}" | tail -n 1 || true)"
[[ -n "${OPERATOR_ENDPOINT}" ]] || die "failed to parse operator endpoint from ${START_LOG}"
log "Operator endpoint: ${OPERATOR_ENDPOINT}"

log ""
log "Step 4: verify readyz"
READY_HTTP_CODE="$(curl -s -o /tmp/greentic-cloud-demo-readyz.out -w '%{http_code}' "${OPERATOR_ENDPOINT}/readyz")"
[[ "${READY_HTTP_CODE}" == "200" ]] || die "readyz failed with ${READY_HTTP_CODE}"
log "PASS: /readyz -> 200"

log ""
log "Step 5: verify web ui"
WEB_HTTP_CODE="$(curl -s -o /tmp/greentic-cloud-demo-web.out -w '%{http_code}' "${OPERATOR_ENDPOINT}${WEBCHAT_EXPECTED_PATH}")"
[[ "${WEB_HTTP_CODE}" == "200" ]] || die "web ui failed with ${WEB_HTTP_CODE}"
grep -q "Greentic WebChat" /tmp/greentic-cloud-demo-web.out || die "web ui html missing expected marker"
log "PASS: ${WEBCHAT_EXPECTED_PATH} -> 200"

if [[ "${SKIP_ADMIN}" == "true" ]]; then
  log ""
  log "Step 6: skipping admin (--skip-admin)"
else
  log ""
  log "Step 6: admin tunnel"

  if ! "${GTC_CMD}" admin tunnel --help >/dev/null 2>&1; then
    die "gtc admin tunnel is not available in ${GTC_CMD}"
  fi

  "${GTC_CMD}" admin tunnel ./cloud-deploy-demo-bundle --target aws > "${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID=$!

  for _ in $(seq 1 30); do
    if grep -q "Opening admin tunnel on https://127.0.0.1:8443" "${TUNNEL_LOG}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  grep -q "Opening admin tunnel on https://127.0.0.1:8443" "${TUNNEL_LOG}" 2>/dev/null \
    || die "admin tunnel did not become ready"

  CERT_DIR="$(find "${WORK_DIR}/cloud-deploy-demo-bundle/.greentic/admin/tunnels" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${CERT_DIR}" ]] || die "failed to discover tunnel cert dir"

  ADMIN_HEALTH="$(curl --silent --show-error --cacert "${CERT_DIR}/ca.crt" \
    --cert "${CERT_DIR}/client.crt" \
    --key "${CERT_DIR}/client.key" \
    https://127.0.0.1:8443/admin/v1/health)"
  echo "${ADMIN_HEALTH}" | grep -q '"success":true' || die "admin health failed: ${ADMIN_HEALTH}"
  log "PASS: admin health"

  ADMIN_STATUS="$(curl --silent --show-error --cacert "${CERT_DIR}/ca.crt" \
    --cert "${CERT_DIR}/client.crt" \
    --key "${CERT_DIR}/client.key" \
    https://127.0.0.1:8443/admin/v1/status)"
  echo "${ADMIN_STATUS}" | grep -q '"success":true' || die "admin status failed: ${ADMIN_STATUS}"

  if command -v jq >/dev/null 2>&1; then
    BUNDLE_PATH="$(printf '%s' "${ADMIN_STATUS}" | jq -r '.data.bundle_path')"
  else
    BUNDLE_PATH="$(printf '%s' "${ADMIN_STATUS}" | sed -n 's/.*"bundle_path":"\([^"]*\)".*/\1/p')"
  fi
  [[ -n "${BUNDLE_PATH}" && "${BUNDLE_PATH}" != "null" ]] || die "failed to parse admin bundle_path"

  ADMINS_BEFORE="$(curl --silent --show-error --cacert "${CERT_DIR}/ca.crt" \
    --cert "${CERT_DIR}/client.crt" \
    --key "${CERT_DIR}/client.key" \
    https://127.0.0.1:8443/admin/v1/admins)"
  echo "${ADMINS_BEFORE}" | grep -q '"success":true' || die "admin list failed: ${ADMINS_BEFORE}"

  ADD_RESP="$(curl --silent --show-error --cacert "${CERT_DIR}/ca.crt" \
    --cert "${CERT_DIR}/client.crt" \
    --key "${CERT_DIR}/client.key" \
    -H 'content-type: application/json' \
    -d "{\"bundle_path\":\"${BUNDLE_PATH}\",\"client_cn\":\"demo-admin-e2e\"}" \
    https://127.0.0.1:8443/admin/v1/admins/add)"
  echo "${ADD_RESP}" | grep -q '"demo-admin-e2e"' || die "admin add failed: ${ADD_RESP}"
  log "PASS: admin add"

  REMOVE_RESP="$(curl --silent --show-error --cacert "${CERT_DIR}/ca.crt" \
    --cert "${CERT_DIR}/client.crt" \
    --key "${CERT_DIR}/client.key" \
    -H 'content-type: application/json' \
    -d "{\"bundle_path\":\"${BUNDLE_PATH}\",\"client_cn\":\"demo-admin-e2e\"}" \
    https://127.0.0.1:8443/admin/v1/admins/remove)"
  echo "${REMOVE_RESP}" | grep -vq '"demo-admin-e2e"' || die "admin remove failed: ${REMOVE_RESP}"
  log "PASS: admin remove"
fi

if [[ "${KEEP_RUNNING}" == "true" ]]; then
  log ""
  log "Keeping deployment running (--keep-running)"
  log "Work dir: ${WORK_DIR}"
  log "Operator endpoint: ${OPERATOR_ENDPOINT}"
  log "Tunnel log: ${TUNNEL_LOG}"
  trap - EXIT
  exit 0
fi

log ""
log "Step 7: destroy"
"${GTC_CMD}" stop ./cloud-deploy-demo-bundle --target aws --destroy

trap - EXIT
log ""
log "Cloud demo E2E PASSED"
