#!/usr/bin/env bash
#
# Local runner for cloud demo E2E.
#
# Flow:
#   gtc wizard -> gtc setup -> gtc start --target <aws|azure|gcp>
#   -> verify /readyz and /v1/web/webchat/demo/
#   -> optional gtc admin tunnel (AWS only for now)
#   -> gtc stop --destroy
#
# Required env for AWS:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_REGION or AWS_DEFAULT_REGION (optional, default: eu-north-1)
#
# Required env for Azure:
#   ARM_SUBSCRIPTION_ID
#   ARM_TENANT_ID
#   ARM_CLIENT_ID
#   ARM_CLIENT_SECRET
#   GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_KEY_VAULT_ID
#
# Required env for GCP:
#   GOOGLE_APPLICATION_CREDENTIALS
#   GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_PROJECT_ID
#   GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_REGION (optional, default: us-central1)
#
# Required tools on PATH:
#   gtc, terraform (for cloud targets), oras (to fetch the deployer provider pack)
#
# Optional env:
#   GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND (default: s3)
#   AWS_REGION (default: eu-north-1)
#   AWS_DEFAULT_REGION (default: value of AWS_REGION)
#   GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_LOCATION (default: westeurope)
#   GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_REGION (default: us-central1)
#   DEMO_RELEASE_VERSION (default: latest)
#   WEBCHAT_EXPECTED_PATH (default: /v1/web/webchat/demo/)
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEMO_RELEASE_VERSION="${DEMO_RELEASE_VERSION:-latest}"
WEBCHAT_EXPECTED_PATH="${WEBCHAT_EXPECTED_PATH:-/v1/web/webchat/demo/}"
GTC_CMD="${GTC_CMD:-gtc}"
TARGET="${TARGET:-aws}"
SKIP_ADMIN="${SKIP_ADMIN:-false}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
VERBOSE="${VERBOSE:-false}"
HTTP_MAX_TIME="${HTTP_MAX_TIME:-10}"
READY_RETRIES="${READY_RETRIES:-18}"
WEB_RETRIES="${WEB_RETRIES:-12}"
WORK_DIR=""
START_LOG=""
TUNNEL_LOG=""
STOP_LOG=""
TUNNEL_PID=""
OPERATOR_ENDPOINT=""

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
    --target)
      TARGET="$2"
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

parse_output_ref() {
  local key="$1"
  python3 - "$START_LOG" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
text = open(path, "r", encoding="utf-8").read()
decoder = json.JSONDecoder()
i = 0
last = None
while i < len(text):
    try:
        obj, end = decoder.raw_decode(text, i)
    except json.JSONDecodeError:
        i += 1
        continue
    last = obj
    i = end

value = ""
if isinstance(last, dict):
    exec_obj = last.get("execution") or {}
    outcome = exec_obj.get("outcome_payload") or {}
    refs = outcome.get("output_refs") or {}
    value = refs.get(key, "")
print(value)
PY
}

emit_runtime_diagnostics() {
  local admin_ca_ref cluster_name service_name task_arn

  admin_ca_ref="$(parse_output_ref admin_ca_secret_ref || true)"
  [[ -n "${admin_ca_ref}" ]] || return 0

  cluster_name="$(printf '%s\n' "${admin_ca_ref}" | sed -n 's#.*greentic/admin/\(greentic-[^/]*\)/.*#\1-cluster#p')"
  service_name="$(printf '%s\n' "${cluster_name}" | sed 's/-cluster$/-service/')"
  [[ -n "${cluster_name}" ]] || return 0

  log ""
  log "Diagnostics: ECS service"
  aws ecs describe-services \
    --region "${AWS_REGION}" \
    --cluster "${cluster_name}" \
    --services "${service_name}" || true

  log ""
  log "Diagnostics: ECS tasks"
  aws ecs list-tasks \
    --region "${AWS_REGION}" \
    --cluster "${cluster_name}" || true

  task_arn="$(aws ecs list-tasks \
    --region "${AWS_REGION}" \
    --cluster "${cluster_name}" \
    --query 'taskArns[0]' \
    --output text 2>/dev/null || true)"
  if [[ -n "${task_arn}" && "${task_arn}" != "None" ]]; then
    log ""
    log "Diagnostics: ECS task detail"
    aws ecs describe-tasks \
      --region "${AWS_REGION}" \
      --cluster "${cluster_name}" \
      --tasks "${task_arn}" || true
  fi
}

wait_for_http_200() {
  local url="$1"
  local output_file="$2"
  local retries="$3"
  local expected_marker="${4:-}"
  local label="$5"
  local attempt code

  rm -f "${output_file}"
  for attempt in $(seq 1 "${retries}"); do
    code="$(curl --silent --show-error --max-time "${HTTP_MAX_TIME}" \
      -o "${output_file}" -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
      if [[ -z "${expected_marker}" ]] || grep -q "${expected_marker}" "${output_file}"; then
        return 0
      fi
      log_verbose "${label}: HTTP 200 but expected marker missing on attempt ${attempt}/${retries}"
    else
      log_verbose "${label}: HTTP ${code:-curl-error} on attempt ${attempt}/${retries}"
    fi
    sleep 5
  done

  emit_runtime_diagnostics
  return 1
}

wait_for_local_port() {
  local host="$1"
  local port="$2"
  local retries="$3"
  local attempt

  for attempt in $(seq 1 "${retries}"); do
    if python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(1.0)
try:
    sock.connect((host, port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
    then
      return 0
    fi
    log_verbose "port ${host}:${port} not ready on attempt ${attempt}/${retries}"
    sleep 1
  done

  return 1
}

admin_curl_json() {
  local cert_dir="$1"
  local path="$2"
  local data="${3:-}"
  if [[ -n "${data}" ]]; then
    curl --silent --show-error --max-time "${HTTP_MAX_TIME}" \
      --cacert "${cert_dir}/ca.crt" \
      --cert "${cert_dir}/client.crt" \
      --key "${cert_dir}/client.key" \
      -H 'content-type: application/json' \
      -d "${data}" \
      "https://127.0.0.1:8443${path}"
  else
    curl --silent --show-error --max-time "${HTTP_MAX_TIME}" \
      --cacert "${cert_dir}/ca.crt" \
      --cert "${cert_dir}/client.crt" \
      --key "${cert_dir}/client.key" \
      "https://127.0.0.1:8443${path}"
  fi
}

wait_for_admin_success() {
  local cert_dir="$1"
  local path="$2"
  local retries="$3"
  local label="$4"
  local data="${5:-}"
  local attempt resp

  for attempt in $(seq 1 "${retries}"); do
    resp="$(admin_curl_json "${cert_dir}" "${path}" "${data}" 2>/dev/null || true)"
    if printf '%s' "${resp}" | grep -q '"success":true'; then
      printf '%s' "${resp}"
      return 0
    fi
    log_verbose "${label}: not ready on attempt ${attempt}/${retries}"
    sleep 2
  done

  return 1
}

cleanup() {
  if [[ -n "${TUNNEL_PID}" ]] && kill -0 "${TUNNEL_PID}" 2>/dev/null; then
    kill -TERM "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi

  if [[ "$KEEP_RUNNING" != "true" ]] && [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}/cloud-deploy-demo-bundle" ]]; then
    (
      cd "${WORK_DIR}" || exit 0
      "${GTC_CMD}" stop ./cloud-deploy-demo-bundle --target "${TARGET}" --destroy >>"${STOP_LOG}" 2>&1 || true

      if [[ "${TARGET}" == "aws" ]] && [[ -d "${WORK_DIR}/.greentic/deploy/aws" ]]; then
        while IFS= read -r cleanup_script; do
          [[ -n "${cleanup_script}" ]] || continue
          bash "${cleanup_script}" >>"${STOP_LOG}" 2>&1 || true
        done < <(find "${WORK_DIR}/.greentic/deploy/aws" -name terraform-aws-cleanup.sh -type f 2>/dev/null)
      fi
    )
  fi
}

trap cleanup EXIT

command -v "${GTC_CMD}" >/dev/null 2>&1 || die "gtc not found: ${GTC_CMD}"
case "${TARGET}" in
  aws)
    require_env AWS_ACCESS_KEY_ID
    require_env AWS_SECRET_ACCESS_KEY
    export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-north-1}}"
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
    export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND="${GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND:-s3}"
    ;;
  azure)
    require_env ARM_SUBSCRIPTION_ID
    require_env ARM_TENANT_ID
    require_env ARM_CLIENT_ID
    require_env ARM_CLIENT_SECRET
    require_env GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_KEY_VAULT_ID
    export GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_LOCATION="${GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_LOCATION:-westeurope}"
    export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND="${GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND:-azurerm}"
    SKIP_ADMIN=true
    ;;
  gcp)
    require_env GOOGLE_APPLICATION_CREDENTIALS
    require_env GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_PROJECT_ID
    export GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_REGION="${GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_REGION:-us-central1}"
    export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND="${GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND:-gcs}"
    SKIP_ADMIN=true
    ;;
  *)
    die "unsupported target: ${TARGET} (expected aws, azure or gcp)"
    ;;
esac

if [[ "${DEMO_RELEASE_VERSION}" == "latest" ]]; then
  RELEASE_ASSET_BASE="https://github.com/greenticai/greentic-demo/releases/latest/download"
else
  RELEASE_ASSET_BASE="https://github.com/greenticai/greentic-demo/releases/download/${DEMO_RELEASE_VERSION}"
fi

export GREENTIC_DEPLOY_BUNDLE_SOURCE="${RELEASE_ASSET_BASE}/cloud-deploy-demo.gtbundle"

CREATE_ANSWERS_URL="${RELEASE_ASSET_BASE}/cloud-deploy-demo-create-answers.json"
SETUP_ANSWERS_URL="${RELEASE_ASSET_BASE}/cloud-deploy-demo-setup-answers.json"

if [[ -z "${WORK_DIR}" ]]; then
  WORK_DIR="$(mktemp -d)"
fi

LOCAL_CREATE_ANSWERS="${WORK_DIR}/cloud-deploy-demo-create-answers.json"

START_LOG="${WORK_DIR}/gtc-start.log"
TUNNEL_LOG="${WORK_DIR}/gtc-admin-tunnel.log"
STOP_LOG="${WORK_DIR}/gtc-stop.log"

log "Cloud Demo ${TARGET^^} E2E"
log "===================="
log "Release: ${DEMO_RELEASE_VERSION}"
log "Work dir: ${WORK_DIR}"
log "gtc: $(command -v "${GTC_CMD}")"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
rm -rf ./.greentic ./cloud-deploy-demo-bundle ./cloud-deploy-demo.gtbundle

log ""
log "Step 1: wizard"
curl -fsSL "${CREATE_ANSWERS_URL}" -o "${LOCAL_CREATE_ANSWERS}"
"${GTC_CMD}" wizard --answers "${LOCAL_CREATE_ANSWERS}"

log ""
log "Step 2: setup"
"${GTC_CMD}" setup --non-interactive ./cloud-deploy-demo-bundle --answers "${SETUP_ANSWERS_URL}"

log ""
log "Step 2b: stage deployer pack for ${TARGET}"
# `gtc start --target <cloud>` looks for the deployer provider pack under the
# bundle, in `.greentic/deployment-targets.json` metadata, or adjacent to the
# `greentic-deployer` binary at `<bin-dir>/dist/`. The cloud demo bundle from
# greentic-demo doesn't ship one, the cargo-binstall'd deployer release
# tarball doesn't include `dist/`, and `gtc install` doesn't hydrate it. Pull
# the canonical pack from GHCR and drop it into the bundle layout fallback.
command -v oras >/dev/null 2>&1 || die "oras not found on PATH (install via oras-project/setup-oras@v1 or https://oras.land/cli)"
DEPLOYER_PACK_REF="ghcr.io/greenticai/packs/deployer/greentic.deploy.${TARGET}:stable"
DEPLOYER_DIR="${WORK_DIR}/cloud-deploy-demo-bundle/providers/deployer"
DEPLOYER_PULL_DIR="${WORK_DIR}/.greentic/deployer-pull"
mkdir -p "${DEPLOYER_DIR}" "${DEPLOYER_PULL_DIR}"
log_verbose "pulling ${DEPLOYER_PACK_REF}"
(
  cd "${DEPLOYER_PULL_DIR}"
  rm -rf dist
  oras pull "${DEPLOYER_PACK_REF}" >/dev/null
)
DEPLOYER_PACK_SRC="${DEPLOYER_PULL_DIR}/dist/${TARGET}.gtpack"
[[ -f "${DEPLOYER_PACK_SRC}" ]] || die "deployer pack not pulled to ${DEPLOYER_PACK_SRC}"
mv "${DEPLOYER_PACK_SRC}" "${DEPLOYER_DIR}/${TARGET}.gtpack"
log "Staged ${DEPLOYER_DIR}/${TARGET}.gtpack from ${DEPLOYER_PACK_REF}"

log ""
log "Step 3: start ${TARGET} deploy"
"${GTC_CMD}" start ./cloud-deploy-demo-bundle --target "${TARGET}" | tee "${START_LOG}"

case "${TARGET}" in
  aws)
    OPERATOR_ENDPOINT="$(grep -o 'http://[^"]*elb[^"]*amazonaws.com' "${START_LOG}" | tail -n 1 || true)"
    ;;
  azure)
    OPERATOR_ENDPOINT="$(grep -Eo 'https://[^[:space:]]+azurecontainerapps\.io' "${START_LOG}" | tail -n 1 || true)"
    ;;
  gcp)
    OPERATOR_ENDPOINT="$(grep -Eo 'https://[^[:space:]]+\.a\.run\.app' "${START_LOG}" | tail -n 1 || true)"
    ;;
esac
[[ -n "${OPERATOR_ENDPOINT}" ]] || die "failed to parse operator endpoint from ${START_LOG}"
log "Operator endpoint: ${OPERATOR_ENDPOINT}"

log ""
log "Step 4: verify readyz"
wait_for_http_200 \
  "${OPERATOR_ENDPOINT}/readyz" \
  "/tmp/greentic-cloud-demo-readyz.out" \
  "${READY_RETRIES}" \
  '"status":"ready"' \
  "readyz" \
  || die "readyz did not become healthy"
log "PASS: /readyz -> 200"

log ""
log "Step 5: verify web ui"
wait_for_http_200 \
  "${OPERATOR_ENDPOINT}${WEBCHAT_EXPECTED_PATH}" \
  "/tmp/greentic-cloud-demo-web.out" \
  "${WEB_RETRIES}" \
  "Greentic WebChat" \
  "web ui" \
  || die "web ui did not become healthy"
log "PASS: ${WEBCHAT_EXPECTED_PATH} -> 200"

if [[ "${SKIP_ADMIN}" == "true" ]]; then
  log ""
  if [[ "${TARGET}" == "azure" ]]; then
    log "Step 6: skipping admin (not yet supported for azure)"
  elif [[ "${TARGET}" == "gcp" ]]; then
    log "Step 6: skipping admin (not yet supported for gcp)"
  else
    log "Step 6: skipping admin (--skip-admin)"
  fi
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
  wait_for_local_port 127.0.0.1 8443 20 || die "admin tunnel port 8443 did not become reachable"

  CERT_DIR="$(find "${WORK_DIR}/cloud-deploy-demo-bundle/.greentic/admin/tunnels" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${CERT_DIR}" ]] || die "failed to discover tunnel cert dir"

  ADMIN_HEALTH="$(wait_for_admin_success "${CERT_DIR}" "/admin/v1/health" 15 "admin health")"
  echo "${ADMIN_HEALTH}" | grep -q '"success":true' || die "admin health failed: ${ADMIN_HEALTH}"
  log "PASS: admin health"

  ADMIN_STATUS="$(wait_for_admin_success "${CERT_DIR}" "/admin/v1/status" 15 "admin status")"
  echo "${ADMIN_STATUS}" | grep -q '"success":true' || die "admin status failed: ${ADMIN_STATUS}"

  if command -v jq >/dev/null 2>&1; then
    BUNDLE_PATH="$(printf '%s' "${ADMIN_STATUS}" | jq -r '.data.bundle_path')"
  else
    BUNDLE_PATH="$(printf '%s' "${ADMIN_STATUS}" | sed -n 's/.*"bundle_path":"\([^"]*\)".*/\1/p')"
  fi
  [[ -n "${BUNDLE_PATH}" && "${BUNDLE_PATH}" != "null" ]] || die "failed to parse admin bundle_path"

  ADMINS_BEFORE="$(wait_for_admin_success "${CERT_DIR}" "/admin/v1/admins" 15 "admin list")"
  echo "${ADMINS_BEFORE}" | grep -q '"success":true' || die "admin list failed: ${ADMINS_BEFORE}"

  ADD_RESP="$(wait_for_admin_success \
    "${CERT_DIR}" \
    "/admin/v1/admins/add" \
    15 \
    "admin add" \
    "{\"bundle_path\":\"${BUNDLE_PATH}\",\"client_cn\":\"demo-admin-e2e\"}")"
  echo "${ADD_RESP}" | grep -q '"demo-admin-e2e"' || die "admin add failed: ${ADD_RESP}"
  log "PASS: admin add"

  REMOVE_RESP="$(wait_for_admin_success \
    "${CERT_DIR}" \
    "/admin/v1/admins/remove" \
    15 \
    "admin remove" \
    "{\"bundle_path\":\"${BUNDLE_PATH}\",\"client_cn\":\"demo-admin-e2e\"}")"
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
"${GTC_CMD}" stop ./cloud-deploy-demo-bundle --target "${TARGET}" --destroy

trap - EXIT
log ""
log "Cloud demo E2E PASSED"
