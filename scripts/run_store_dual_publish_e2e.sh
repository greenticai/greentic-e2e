#!/usr/bin/env bash
#
# Store dual-publish lifecycle E2E (publish -> install -> run)
#
# Exercises the greentic-store-server agentic-worker lifecycle end-to-end
# against REAL infrastructure (Postgres 16 + MinIO + the store image), with
# the designer side simulated via curl. The API contracts are what we verify:
#
#   1. health
#   2. register publisher (JWT)
#   3. build a worker .gtpack (describe.json + secrets-policy.json + manifest.cbor)
#   4. publish (multipart) -> 201
#   5. list / detail / version metadata round-trip
#   6. install-back: download artifact, assert byte-equal + sha header match
#   7. run -> 200, agent namespaced, admin registry recorded exactly one PUT
#   8. negative: byo-required worker -> run -> 409
#
# The store image is pulled from GHCR by default. If the pull fails (the image
# is private), the scenario SKIPS with a clear message (exit 0) rather than
# failing -- mirroring the provider-e2e missing-secrets skip pattern. Set
# STORE_IMAGE to a locally-built tag to run against a private build.
#
# Usage:
#   ./scripts/run_store_dual_publish_e2e.sh [options]
#
# Options:
#   --keep-running   Leave containers + mock admin up after the run
#   --verbose        Verbose output
#   --help, -h       Show this help
#
# The mock admin registry is a python3-stdlib HTTP server. It runs inside a
# `python:3-alpine` container ON THE SAME docker network as the store, so the
# store reaches it by container DNS name. (host.docker.internal / host-gateway
# is unreliable here: on a user-defined network it resolves to the default
# bridge gateway, which the host firewall typically drops; a sibling container
# is the portable contract-equivalent.) Recorded PUT bodies are written to a
# bind-mounted file the host then asserts against.
#
# Environment overrides:
#   STORE_IMAGE      Store-server image (default: ghcr.io/greentic-biz/greentic-store-server:latest)
#   POSTGRES_IMAGE   Postgres image (default: postgres:16-alpine)
#   MINIO_IMAGE      MinIO image (default: minio/minio:RELEASE.2025-01-20T14-49-07Z)
#   MC_IMAGE         MinIO client image (default: minio/mc:RELEASE.2025-01-17T23-25-50Z)
#   PYTHON_IMAGE     Mock admin image (default: python:3-alpine)
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures/store-dual-publish"

# Images (overridable). Default store image targets the GHCR ref from DEPLOY.md.
STORE_IMAGE="${STORE_IMAGE:-ghcr.io/greentic-biz/greentic-store-server:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2025-01-20T14-49-07Z}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2025-01-17T23-25-50Z}"
PYTHON_IMAGE="${PYTHON_IMAGE:-python:3-alpine}"

# Defaults
KEEP_RUNNING="${KEEP_RUNNING:-false}"
VERBOSE="${VERBOSE:-false}"

# Unique run id so parallel/leftover runs never collide.
RUN_ID="$(date +%s)-$$"
NET_NAME="gtc-store-e2e-${RUN_ID}"
PG_NAME="gtc-store-e2e-pg-${RUN_ID}"
MINIO_NAME="gtc-store-e2e-minio-${RUN_ID}"
STORE_NAME="gtc-store-e2e-server-${RUN_ID}"
ADMIN_NAME="gtc-store-e2e-admin-${RUN_ID}"

# Fixed-but-uncommon host ports (override is unlikely to be needed).
PG_PORT="${PG_PORT:-55432}"
MINIO_PORT="${MINIO_PORT:-59000}"
STORE_PORT="${STORE_PORT:-53000}"
# In-container port the mock admin listens on (network-internal only).
ADMIN_PORT="${ADMIN_PORT:-8080}"

# Credentials (ephemeral; this is a throwaway stack).
PG_USER="store"
PG_PASS="store-e2e-pass"
PG_DB="store"
BLOB_ACCESS_KEY="e2eaccesskey"
BLOB_SECRET_KEY="e2esecretkey1234567890abcd"
BLOB_BUCKET="greentic-store-artifacts"
JWT_SECRET="test-jwt-secret-32-bytes-long-abc"
# SIGNING_KEY_ENCRYPTION_KEY must be exactly 64 hex chars (32 bytes).
SIGNING_KEY="$(printf '00%.0s' {1..32})"
ADMIN_TOKEN="gtc_live_e2e"

ADMIN_BODY_FILE=""
ADMIN_DIR=""
FAIL_COUNT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-running)
      KEEP_RUNNING=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
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

skip() {
  log "SKIP: $*"
  exit 0
}

pass() {
  log "PASS: $*"
}

fail() {
  log "FAIL: $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
  if [[ "$KEEP_RUNNING" == "true" ]]; then
    log "Keeping infra running (--keep-running)"
    log "  store:  http://127.0.0.1:${STORE_PORT}"
    log "  admin:  container ${ADMIN_NAME} on network ${NET_NAME}"
    log "  recorded admin PUTs: ${ADMIN_BODY_FILE:-<none>}"
    return
  fi
  log "Cleaning up..."
  docker rm -f "${STORE_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${ADMIN_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${MINIO_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${PG_NAME}" >/dev/null 2>&1 || true
  docker network rm "${NET_NAME}" >/dev/null 2>&1 || true
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

trap cleanup EXIT

# Assert an HTTP status code, incrementing FAIL_COUNT on mismatch.
assert_status() {
  local label="$1" expected="$2" actual="$3" body="${4:-}"
  if [[ "$actual" == "$expected" ]]; then
    pass "${label} -> HTTP ${actual}"
  else
    fail "${label} -> expected HTTP ${expected}, got ${actual}"
    [[ -n "$body" ]] && log "  body: ${body}"
  fi
}

# Extract a JSON field via python3 (stdlib). Args: <json> <python-expr-on-d>.
json_get() {
  local json="$1" expr="$2"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(eval(sys.argv[2]))
' "$json" "$expr"
}

# Count recorded admin PUTs (non-empty lines). Always emits a single integer,
# even when the record file is empty or absent.
count_admin_puts() {
  if [[ -f "${ADMIN_BODY_FILE}" ]]; then
    grep -c . "${ADMIN_BODY_FILE}" 2>/dev/null || true
  else
    echo 0
  fi
}

###############################################################################
# Prerequisites
###############################################################################
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
docker ps >/dev/null 2>&1 || die "docker daemon not accessible"

[[ -f "${FIXTURES_DIR}/manifest.cbor" ]] \
  || die "missing CBOR fixture: ${FIXTURES_DIR}/manifest.cbor"

log "Store Dual-Publish Lifecycle E2E"
log "================================"
log "Store image: ${STORE_IMAGE}"
log "Run id:      ${RUN_ID}"

###############################################################################
# Pull store image (SKIP if unavailable, do not FAIL)
###############################################################################
log ""
log "Step 0: Resolving store image..."
if docker image inspect "${STORE_IMAGE}" >/dev/null 2>&1; then
  log "Store image present locally"
elif docker pull "${STORE_IMAGE}" >/dev/null 2>&1; then
  log "Pulled store image from registry"
else
  skip "store image '${STORE_IMAGE}' not pullable (private registry?). \
Set STORE_IMAGE to a locally-built tag to run this scenario."
fi

TEMP_DIR="$(mktemp -d)"
# The admin record file lives in its own dir so it can be bind-mounted into the
# admin container in isolation (and remain host-readable).
ADMIN_DIR="${TEMP_DIR}/admin"
mkdir -p "${ADMIN_DIR}"
chmod 777 "${ADMIN_DIR}"
ADMIN_BODY_FILE="${ADMIN_DIR}/admin-puts.jsonl"
: > "${ADMIN_BODY_FILE}"
chmod 666 "${ADMIN_BODY_FILE}"
log "Working directory: ${TEMP_DIR}"

# Network first — every container (incl. the mock admin) shares it.
docker network create "${NET_NAME}" >/dev/null
log_verbose "Created network ${NET_NAME}"

###############################################################################
# Mock admin registry (python3 stdlib HTTP server, in a sibling container)
###############################################################################
log ""
log "Step 1: Starting mock admin registry container on ${NET_NAME}..."

ADMIN_SCRIPT="${ADMIN_DIR}/mock_admin.py"
cat > "${ADMIN_SCRIPT}" <<'PYEOF'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
PREFIX = "/api/v1/designer/agents/"


class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):
        if not self.path.startswith(PREFIX):
            self.send_response(404)
            self.end_headers()
            return
        agent_id = self.path[len(PREFIX):]
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        with open(RECORD, "a") as fh:
            fh.write(json.dumps({"agent_id": agent_id, "body": body}) + "\n")
        resp = json.dumps({"agent_id": agent_id, "version": 1}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def do_GET(self):  # readiness probe
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # silence default stderr logging
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

docker run -d --name "${ADMIN_NAME}" --network "${NET_NAME}" \
  -v "${ADMIN_DIR}:/data" \
  "${PYTHON_IMAGE}" \
  python /data/mock_admin.py "${ADMIN_PORT}" /data/admin-puts.jsonl >/dev/null

# Wait for the admin server to accept connections (probe inside the container).
ADMIN_READY=false
for _ in $(seq 1 30); do
  if docker exec "${ADMIN_NAME}" python -c \
       "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(('127.0.0.1',${ADMIN_PORT})))" \
       >/dev/null 2>&1; then
    ADMIN_READY=true
    break
  fi
  sleep 0.5
done
if [[ "$ADMIN_READY" != "true" ]]; then
  docker logs "${ADMIN_NAME}" 2>&1 | tail -20 || true
  die "mock admin registry did not come up"
fi
pass "mock admin registry up (container ${ADMIN_NAME})"

###############################################################################
# Infra: Postgres + MinIO + bucket
###############################################################################
log ""
log "Step 2: Bringing up infra (Postgres + MinIO)..."

docker run -d --name "${PG_NAME}" --network "${NET_NAME}" \
  -e POSTGRES_USER="${PG_USER}" \
  -e POSTGRES_PASSWORD="${PG_PASS}" \
  -e POSTGRES_DB="${PG_DB}" \
  -p "127.0.0.1:${PG_PORT}:5432" \
  "${POSTGRES_IMAGE}" >/dev/null
log_verbose "Started Postgres ${PG_NAME}"

docker run -d --name "${MINIO_NAME}" --network "${NET_NAME}" \
  -e MINIO_ROOT_USER="${BLOB_ACCESS_KEY}" \
  -e MINIO_ROOT_PASSWORD="${BLOB_SECRET_KEY}" \
  -p "127.0.0.1:${MINIO_PORT}:9000" \
  "${MINIO_IMAGE}" server /data >/dev/null
log_verbose "Started MinIO ${MINIO_NAME}"

# Wait for Postgres.
PG_READY=false
for _ in $(seq 1 30); do
  if docker exec "${PG_NAME}" pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
    PG_READY=true
    break
  fi
  sleep 1
done
[[ "$PG_READY" == "true" ]] || die "Postgres did not become ready"
pass "Postgres ready"

# Wait for MinIO, then create the bucket and grant anonymous download
# (the store fetches artifacts back from blob storage during run).
MINIO_READY=false
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:${MINIO_PORT}/minio/health/live" 2>/dev/null; then
    MINIO_READY=true
    break
  fi
  sleep 1
done
[[ "$MINIO_READY" == "true" ]] || die "MinIO did not become ready"

docker run --rm --network "${NET_NAME}" --entrypoint /bin/sh "${MC_IMAGE}" -c "
  mc alias set local http://${MINIO_NAME}:9000 ${BLOB_ACCESS_KEY} ${BLOB_SECRET_KEY} &&
  mc mb --ignore-existing local/${BLOB_BUCKET} &&
  mc anonymous set download local/${BLOB_BUCKET}
" >/dev/null 2>&1 || die "failed to create MinIO bucket"
pass "MinIO ready + bucket '${BLOB_BUCKET}' created"

###############################################################################
# Store server
###############################################################################
log ""
log "Step 3: Starting store server..."

docker run -d --name "${STORE_NAME}" --network "${NET_NAME}" \
  -e DATABASE_URL="postgres://${PG_USER}:${PG_PASS}@${PG_NAME}:5432/${PG_DB}" \
  -e BLOB_ENDPOINT="http://${MINIO_NAME}:9000" \
  -e BLOB_REGION="us-east-1" \
  -e BLOB_BUCKET="${BLOB_BUCKET}" \
  -e BLOB_ACCESS_KEY="${BLOB_ACCESS_KEY}" \
  -e BLOB_SECRET_KEY="${BLOB_SECRET_KEY}" \
  -e BLOB_FORCE_PATH_STYLE="true" \
  -e JWT_SECRET="${JWT_SECRET}" \
  -e JWT_TTL_SECONDS="86400" \
  -e SIGNING_KEY_ENCRYPTION_KEY="${SIGNING_KEY}" \
  -e ADMIN_REGISTRY_URL="http://${ADMIN_NAME}:${ADMIN_PORT}" \
  -e ADMIN_REGISTRY_TOKEN="${ADMIN_TOKEN}" \
  -e RUN_CHAT_URL_TEMPLATE="https://chat.e2e/?agent={agent_id}" \
  -e LISTEN_ADDR="0.0.0.0:3000" \
  -e RUST_LOG="info" \
  -p "127.0.0.1:${STORE_PORT}:3000" \
  "${STORE_IMAGE}" >/dev/null

STORE_BASE="http://127.0.0.1:${STORE_PORT}"

# Wait for /health.
STORE_READY=false
for _ in $(seq 1 60); do
  if curl -sf "${STORE_BASE}/health" >/dev/null 2>&1; then
    STORE_READY=true
    break
  fi
  sleep 1
done
if [[ "$STORE_READY" != "true" ]]; then
  log "Store server did not become healthy; logs:"
  docker logs "${STORE_NAME}" 2>&1 | tail -40 || true
  die "store server unhealthy"
fi
pass "Store server healthy"

###############################################################################
# Flow under test
###############################################################################
log ""
log "Step 4: Lifecycle flow (publish -> install -> run)..."

# 4a. Health.
HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${STORE_BASE}/health")"
assert_status "health" "200" "${HEALTH_CODE}"

# 4b. Register publisher -> JWT.
HANDLE="wkr$(printf '%s' "${RUN_ID}" | tr -dc 'a-z0-9' | tail -c 8)"
[[ -n "$HANDLE" ]] || HANDLE="wkre2e1"
EMAIL="${HANDLE}@example.test"
REGISTER_RESP="$(curl -s -w $'\n%{http_code}' \
  -X POST "${STORE_BASE}/api/v1/auth/register" \
  -H 'content-type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"correct horse battery staple\",\"name\":\"Worker Publisher\",\"handle\":\"${HANDLE}\"}")"
REGISTER_CODE="$(printf '%s' "${REGISTER_RESP}" | tail -1)"
REGISTER_BODY="$(printf '%s' "${REGISTER_RESP}" | sed '$d')"
assert_status "register publisher" "200" "${REGISTER_CODE}" "${REGISTER_BODY}"
[[ "${REGISTER_CODE}" == "200" ]] || die "cannot continue without a JWT"
JWT="$(json_get "${REGISTER_BODY}" "d['token']")"
log_verbose "JWT acquired (len ${#JWT})"

# 4c. Build a worker .gtpack.
#     id REQUIRES a dot: "{handle}.support".
WORKER_NAME="${HANDLE}.support"
WORKER_VERSION="0.1.0"
# manifestSha256: sha256 of the manifest.cbor bytes (artifact-pin field).
MANIFEST_SHA="$(python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "${FIXTURES_DIR}/manifest.cbor")"

# Emit a valid v2 AgenticWorker describe.json to $1 for the current
# WORKER_NAME / WORKER_VERSION / MANIFEST_SHA.
emit_describe() {
  local out="$1"
  DESCRIBE_OUT="${out}" WORKER_NAME="${WORKER_NAME}" \
    WORKER_VERSION="${WORKER_VERSION}" MANIFEST_SHA="${MANIFEST_SHA}" python3 -c '
import json, os
name = os.environ["WORKER_NAME"]
version = os.environ["WORKER_VERSION"]
manifest_sha = os.environ["MANIFEST_SHA"]
zeros = "0" * 64
describe = {
    "apiVersion": "greentic.ai/v2",
    "kind": "AgenticWorker",
    "compat": {
        "min_designer_version": ">=1.2.0",
        "min_runner_version": "^0.12.0",
        "contract_version": "1.2.0",
    },
    "metadata": {
        "id": name,
        "name": "My Worker",
        "version": version,
        "summary": "t",
        "author": {"name": "Test"},
        "license": "MIT",
    },
    "engine": {"greenticDesigner": ">=1.2.0", "extRuntime": "^1.2.0"},
    "capabilities": {"offered": [], "required": []},
    "runtime": {
        "memoryLimitMB": 32,
        "permissions": {"network": [], "secrets": [], "callExtensionKinds": []},
        "components": {
            "worker": {
                "gtpack": {
                    "file": "worker.wasm",
                    "sha256": zeros,
                    "pack_id": name,
                    "component_version": version,
                },
                "sha256": zeros,
                "world": "test:worker/extension@0.1.0",
            }
        },
    },
    "contributions": {},
    "manifestSha256": manifest_sha,
}
with open(os.environ["DESCRIBE_OUT"], "w") as fh:
    json.dump(describe, fh)
'
}

# Build a worker .gtpack (zip) into $1, using policy json $2.
build_gtpack() {
  local out="$1" policy="$2"
  local stage="${TEMP_DIR}/stage-$$-$RANDOM"
  mkdir -p "${stage}"
  emit_describe "${stage}/describe.json"
  printf '%s' "${policy}" > "${stage}/secrets-policy.json"
  cp "${FIXTURES_DIR}/manifest.cbor" "${stage}/manifest.cbor"
  ( cd "${stage}" && zip -q -X "${out}" describe.json secrets-policy.json manifest.cbor )
  rm -rf "${stage}"
}

GTPACK="${TEMP_DIR}/worker.gtpack"
build_gtpack "${GTPACK}" '{"requirements":[]}'

ARTIFACT_SHA="$(python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "${GTPACK}")"
log_verbose "artifact sha256: ${ARTIFACT_SHA}"

# 4d. Publish (multipart). The describe in metadata must match the one inside
#     the artifact zip, so read it straight back out of the zip.
METADATA_JSON="$(GTPACK="${GTPACK}" ARTIFACT_SHA="${ARTIFACT_SHA}" python3 -c '
import json, os, zipfile
with zipfile.ZipFile(os.environ["GTPACK"]) as zf:
    describe = json.loads(zf.read("describe.json"))
print(json.dumps({"describe": describe, "artifactSha256": os.environ["ARTIFACT_SHA"]}))
')"

PUBLISH_RESP="$(curl -s -w $'\n%{http_code}' \
  -X POST "${STORE_BASE}/api/v1/agentic-workers" \
  -H "authorization: Bearer ${JWT}" \
  -F "metadata=${METADATA_JSON};type=application/json" \
  -F "artifact=@${GTPACK};type=application/octet-stream;filename=artifact.gtpack")"
PUBLISH_CODE="$(printf '%s' "${PUBLISH_RESP}" | tail -1)"
PUBLISH_BODY="$(printf '%s' "${PUBLISH_RESP}" | sed '$d')"
assert_status "publish worker" "201" "${PUBLISH_CODE}" "${PUBLISH_BODY}"

if [[ "${PUBLISH_CODE}" == "201" ]]; then
  PUB_NAME="$(json_get "${PUBLISH_BODY}" "d['name']")"
  PUB_SHA="$(json_get "${PUBLISH_BODY}" "d['artifactSha256']")"
  PUB_POLICY="$(json_get "${PUBLISH_BODY}" "d['secretsPolicyPresent']")"
  [[ "${PUB_NAME}" == "${WORKER_NAME}" ]] \
    && pass "publish name round-trip (${PUB_NAME})" \
    || fail "publish name mismatch: ${PUB_NAME} != ${WORKER_NAME}"
  [[ "${PUB_SHA}" == "${ARTIFACT_SHA}" ]] \
    && pass "publish artifactSha256 no-repack invariant" \
    || fail "publish artifactSha256 mismatch (repack?): ${PUB_SHA} != ${ARTIFACT_SHA}"
  [[ "${PUB_POLICY}" == "True" ]] \
    && pass "publish secretsPolicyPresent true" \
    || fail "publish secretsPolicyPresent not true: ${PUB_POLICY}"
fi

# 4e. List / detail / version metadata.
LIST_RESP="$(curl -s -w $'\n%{http_code}' "${STORE_BASE}/api/v1/agentic-workers")"
LIST_CODE="$(printf '%s' "${LIST_RESP}" | tail -1)"
LIST_BODY="$(printf '%s' "${LIST_RESP}" | sed '$d')"
assert_status "list workers" "200" "${LIST_CODE}"
if [[ "${LIST_CODE}" == "200" ]]; then
  FOUND="$(WORKER_NAME="${WORKER_NAME}" python3 -c '
import json, os, sys
arr = json.loads(sys.stdin.read())
name = os.environ["WORKER_NAME"]
e = next((x for x in arr if x.get("name") == name), None)
print("yes" if e and e.get("latestVersion") == "0.1.0" else "no")
' <<<"${LIST_BODY}")"
  [[ "${FOUND}" == "yes" ]] \
    && pass "list contains worker with latestVersion 0.1.0" \
    || fail "list does not contain worker ${WORKER_NAME} at 0.1.0"
fi

DETAIL_RESP="$(curl -s -w $'\n%{http_code}' \
  "${STORE_BASE}/api/v1/agentic-workers/${WORKER_NAME}")"
DETAIL_CODE="$(printf '%s' "${DETAIL_RESP}" | tail -1)"
DETAIL_BODY="$(printf '%s' "${DETAIL_RESP}" | sed '$d')"
assert_status "detail worker" "200" "${DETAIL_CODE}"
if [[ "${DETAIL_CODE}" == "200" ]]; then
  DETAIL_OK="$(WORKER_NAME="${WORKER_NAME}" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read())
name = os.environ["WORKER_NAME"]
versions = d.get("versions") or []
ok = (d.get("name") == name and d.get("latestVersion") == "0.1.0"
      and "0.1.0" in versions)
print("yes" if ok else "no")
' <<<"${DETAIL_BODY}")"
  [[ "${DETAIL_OK}" == "yes" ]] \
    && pass "detail name + latestVersion + versions round-trip" \
    || fail "detail mismatch: ${DETAIL_BODY}"
fi

META_RESP="$(curl -s -w $'\n%{http_code}' \
  "${STORE_BASE}/api/v1/agentic-workers/${WORKER_NAME}/${WORKER_VERSION}")"
META_CODE="$(printf '%s' "${META_RESP}" | tail -1)"
META_BODY="$(printf '%s' "${META_RESP}" | sed '$d')"
assert_status "version metadata" "200" "${META_CODE}"
if [[ "${META_CODE}" == "200" ]]; then
  META_SHA="$(json_get "${META_BODY}" "d['artifactSha256']")"
  META_MSHA="$(json_get "${META_BODY}" "d['manifestSha256']")"
  META_POL="$(json_get "${META_BODY}" "d['secretsPolicyPresent']")"
  META_KIND="$(json_get "${META_BODY}" "d['describe']['kind']")"
  [[ "${META_SHA}" == "${ARTIFACT_SHA}" ]] \
    && pass "metadata artifactSha256 round-trip" \
    || fail "metadata artifactSha256 mismatch"
  [[ "${META_MSHA}" == "${MANIFEST_SHA}" ]] \
    && pass "metadata manifestSha256 round-trip" \
    || fail "metadata manifestSha256 mismatch"
  [[ "${META_POL}" == "True" ]] \
    && pass "metadata secretsPolicyPresent true" \
    || fail "metadata secretsPolicyPresent not true"
  [[ "${META_KIND}" == "AgenticWorker" ]] \
    && pass "metadata describe.kind AgenticWorker" \
    || fail "metadata describe.kind not AgenticWorker"
fi

# 4f. Install-back: download artifact, assert byte-equal + sha header.
DOWNLOAD="${TEMP_DIR}/downloaded.gtpack"
DL_CODE="$(curl -s -D "${TEMP_DIR}/dl-headers.txt" -o "${DOWNLOAD}" -w '%{http_code}' \
  "${STORE_BASE}/api/v1/agentic-workers/${WORKER_NAME}/${WORKER_VERSION}/artifact")"
assert_status "artifact download" "200" "${DL_CODE}"
if [[ "${DL_CODE}" == "200" ]]; then
  DL_SHA="$(python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "${DOWNLOAD}")"
  HEADER_SHA="$(grep -i '^x-artifact-sha256:' "${TEMP_DIR}/dl-headers.txt" \
    | tr -d '\r' | awk '{print $2}')"
  if cmp -s "${GTPACK}" "${DOWNLOAD}"; then
    pass "install-back: downloaded bytes byte-equal to uploaded"
  else
    fail "install-back: downloaded bytes differ from uploaded"
  fi
  [[ "${DL_SHA}" == "${ARTIFACT_SHA}" ]] \
    && pass "install-back: recomputed sha256 matches" \
    || fail "install-back: recomputed sha256 mismatch"
  [[ "${HEADER_SHA}" == "${ARTIFACT_SHA}" ]] \
    && pass "install-back: x-artifact-sha256 header matches" \
    || fail "install-back: x-artifact-sha256 header mismatch (${HEADER_SHA})"
fi

# 4g. Run -> 200, agent namespaced, admin recorded exactly one PUT.
RUN_RESP="$(curl -s -w $'\n%{http_code}' \
  -X POST "${STORE_BASE}/api/v1/agentic-workers/${WORKER_NAME}/${WORKER_VERSION}/run" \
  -H "authorization: Bearer ${JWT}")"
RUN_CODE="$(printf '%s' "${RUN_RESP}" | tail -1)"
RUN_BODY="$(printf '%s' "${RUN_RESP}" | sed '$d')"
assert_status "run worker" "200" "${RUN_CODE}" "${RUN_BODY}"
EXPECTED_AGENT="${WORKER_NAME}.triage"
if [[ "${RUN_CODE}" == "200" ]]; then
  RUN_AGENT="$(json_get "${RUN_BODY}" "d['agents'][0]['agent_id']")"
  RUN_ADMIN_VER="$(json_get "${RUN_BODY}" "d['agents'][0]['admin_version']")"
  RUN_CHAT_URL="$(json_get "${RUN_BODY}" "d['agents'][0]['chat_url']")"
  [[ "${RUN_AGENT}" == "${EXPECTED_AGENT}" ]] \
    && pass "run agent_id namespaced (${RUN_AGENT})" \
    || fail "run agent_id mismatch: ${RUN_AGENT} != ${EXPECTED_AGENT}"
  [[ "${RUN_ADMIN_VER}" == "1" ]] \
    && pass "run admin_version == 1" \
    || fail "run admin_version not 1: ${RUN_ADMIN_VER}"
  case "${RUN_CHAT_URL}" in
    *"${EXPECTED_AGENT}"*) pass "run chat_url contains agent id" ;;
    *) fail "run chat_url missing agent id: ${RUN_CHAT_URL}" ;;
  esac
fi

# Mock admin must have recorded exactly one PUT with the rewritten id.
sleep 1
ADMIN_PUTS="$(count_admin_puts)"
[[ "${ADMIN_PUTS}" == "1" ]] \
  && pass "admin registry recorded exactly one PUT" \
  || fail "admin registry recorded ${ADMIN_PUTS} PUT(s), expected 1"
if [[ "${ADMIN_PUTS}" == "1" ]]; then
  ADMIN_REC_ID="$(EXPECTED_AGENT="${EXPECTED_AGENT}" python3 -c '
import json, sys
rec = json.loads(sys.stdin.readline())
print(rec["agent_id"])
print(rec["body"].get("agent_id"))
print(rec["body"].get("llm", {}).get("provider"))
' < "${ADMIN_BODY_FILE}")"
  REC_PATH_ID="$(printf '%s\n' "${ADMIN_REC_ID}" | sed -n '1p')"
  REC_BODY_ID="$(printf '%s\n' "${ADMIN_REC_ID}" | sed -n '2p')"
  REC_PROVIDER="$(printf '%s\n' "${ADMIN_REC_ID}" | sed -n '3p')"
  [[ "${REC_PATH_ID}" == "${EXPECTED_AGENT}" ]] \
    && pass "admin PUT path id namespaced" \
    || fail "admin PUT path id mismatch: ${REC_PATH_ID}"
  [[ "${REC_BODY_ID}" == "${EXPECTED_AGENT}" ]] \
    && pass "admin PUT body agent_id rewritten" \
    || fail "admin PUT body agent_id mismatch: ${REC_BODY_ID}"
  [[ "${REC_PROVIDER}" == "openai" ]] \
    && pass "admin PUT forwarded llm.provider verbatim" \
    || fail "admin PUT llm.provider mismatch: ${REC_PROVIDER}"
fi

# 4h. Negative: byo-required worker -> run -> 409.
log ""
log "Step 5: Negative path (byo-required worker -> run 409)..."
WORKER_NAME="${HANDLE}.byo"
BYO_GTPACK="${TEMP_DIR}/byo.gtpack"
build_gtpack "${BYO_GTPACK}" \
  '{"requirements":[{"key":"llm.openai.api_key","required":true,"policy":"byo-required"}]}'
BYO_SHA="$(python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "${BYO_GTPACK}")"
BYO_META="$(GTPACK="${BYO_GTPACK}" BYO_SHA="${BYO_SHA}" python3 -c '
import json, os, zipfile
with zipfile.ZipFile(os.environ["GTPACK"]) as zf:
    describe = json.loads(zf.read("describe.json"))
print(json.dumps({"describe": describe, "artifactSha256": os.environ["BYO_SHA"]}))
')"
BYO_PUB_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${STORE_BASE}/api/v1/agentic-workers" \
  -H "authorization: Bearer ${JWT}" \
  -F "metadata=${BYO_META};type=application/json" \
  -F "artifact=@${BYO_GTPACK};type=application/octet-stream;filename=artifact.gtpack")"
assert_status "publish byo-required worker" "201" "${BYO_PUB_CODE}"

PUTS_BEFORE="$(count_admin_puts)"
BYO_RUN_RESP="$(curl -s -w $'\n%{http_code}' \
  -X POST "${STORE_BASE}/api/v1/agentic-workers/${WORKER_NAME}/${WORKER_VERSION}/run" \
  -H "authorization: Bearer ${JWT}")"
BYO_RUN_CODE="$(printf '%s' "${BYO_RUN_RESP}" | tail -1)"
BYO_RUN_BODY="$(printf '%s' "${BYO_RUN_RESP}" | sed '$d')"
assert_status "run byo-required worker" "409" "${BYO_RUN_CODE}" "${BYO_RUN_BODY}"
case "${BYO_RUN_BODY}" in
  *"llm.openai.api_key"*) pass "409 names the byo-required key" ;;
  *) fail "409 body does not name the byo-required key" ;;
esac
PUTS_AFTER="$(count_admin_puts)"
[[ "${PUTS_BEFORE}" == "${PUTS_AFTER}" ]] \
  && pass "admin registry untouched by byo-required run" \
  || fail "admin registry called during byo-required run"

###############################################################################
# Summary
###############################################################################
log ""
log "================================"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
  log "Store Dual-Publish E2E FAILED (${FAIL_COUNT} failure(s))"
  exit 1
else
  log "Store Dual-Publish E2E PASSED"
fi
log "================================"
