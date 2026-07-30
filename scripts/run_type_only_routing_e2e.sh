#!/usr/bin/env bash
# End-to-end regression guard for greentic-runner #611 (type-only provider
# ingress must route to the *entry* flow, not error "ambiguous").
#
# The bug: when provider ingress is routed by flow *type* only (no flow_id /
# pack_id — the normal messaging-ingress case) and a pack ships MORE THAN ONE
# flow of that type, resolve_flow_id used to bail with
#   "flow type <type> is ambiguous; pack_id is required"
# and no reply ever reached the client. #611 taught the resolver to fall back
# to the single *entry* flow (a flow is entry unless tagged `internal`), so a
# public entrypoint alongside internal helper flows of the same type resolves
# cleanly.
#
# Why our suite missed it: every fixture bundle shipped a SINGLE flow, so the
# ambiguity branch was never entered. This probe pack
# (`fixtures/packs/type-only-routing-probe`) ships two `messaging`-type flows:
#   * entry_main       — the entrypoint (untagged → entry)
#   * internal_helper  — tagged `internal` → must never win a type-only route
# It then drives a type-only WebChat DirectLine ingress and asserts a bot reply
# comes back AND the runtime never logged the ambiguity bail.
#
# Usage:
#   ./scripts/run_type_only_routing_e2e.sh
#
# Options (env):
#   PORT           HTTP port for gtc start (default 8080)
#   WORK_DIR_BASE  pin scratch tree onto a real (non-symlinked) path (see below)
#   KEEP_BUNDLE    if set, don't wipe the generated bundle on exit
#   SKIP_BUILD     if set, skip the probe WASM + pack rebuild (requires existing dist/)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/type-only-routing-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/type-only-routing-bundle.json"
PORT="${PORT:-8080}"

# WORK_DIR_BASE lets callers pin the scratch tree onto a real (non-symlinked)
# path. gtc's operator-key writer rejects any symlinked ancestor, and macOS
# `mktemp -t` ignores TMPDIR and lands under /var/folders (a symlink), which
# aborts `gtc start`. CI's Linux /tmp is fine, so this only matters locally.
WORK_DIR="$(mktemp -d "${WORK_DIR_BASE:-${TMPDIR:-/tmp}}/greentic-type-routing-XXXXXX")"
BUNDLE_DIR="${WORK_DIR}/bundle"
ANSWERS_FILE="${WORK_DIR}/answers.json"
RUNTIME_LOG="${WORK_DIR}/runtime.log"
RESPONSE_FILE="${WORK_DIR}/activities.json"

cleanup() {
  if [ -n "${RUNTIME_HOME:-}" ]; then
    HOME="${RUNTIME_HOME}" gtc stop 2>/dev/null || echo "WARN: gtc stop failed ($?)" >&2
  fi
  kill "${RUNTIME_PID:-}" 2>/dev/null || true
  sleep 1
  if [ -z "${KEEP_BUNDLE:-}" ]; then
    rm -rf "${WORK_DIR}"
  else
    echo "[kept] work dir: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

# --- preflight --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 not found on PATH" >&2; exit 1; }; }
need gtc
need greentic-secrets
need greentic-pack
need cargo-component
need curl
need python3
need jq

if lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: port ${PORT} is already in use" >&2
  exit 1
fi

# --- build probe pack -------------------------------------------------------
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "[build] probe WASM + pack"
  (cd "${PROBE_PACK_SRC}/components/bug3-test" \
    && cargo component build --release --target wasm32-wasip2 --quiet)
  (cd "${PROBE_PACK_SRC}" && greentic-pack build --in . >/dev/null)
fi

PROBE_PACK="$(ls "${PROBE_PACK_SRC}"/dist/*.gtpack 2>/dev/null | head -n1)"
if [ -z "${PROBE_PACK}" ] || [ ! -f "${PROBE_PACK}" ]; then
  echo "FAIL: probe pack build produced no .gtpack in ${PROBE_PACK_SRC}/dist" >&2
  exit 1
fi

# --- render answers -> generate bundle --------------------------------------
echo "[bundle] rendering wizard answers + generating bundle"
python3 - <<PY
import pathlib
tpl = pathlib.Path("${ANSWERS_TEMPLATE}").read_text()
tpl = tpl.replace("{{PROBE_PACK_PATH}}", "${PROBE_PACK}")
tpl = tpl.replace("{{BUNDLE_DIR}}", "${BUNDLE_DIR}")
pathlib.Path("${ANSWERS_FILE}").write_text(tpl)
PY
gtc wizard --answers "${ANSWERS_FILE}" >/dev/null

# --- seed webchat-gui secrets ------------------------------------------------
echo "[secrets] seeding messaging-webchat-gui"
STORE="${BUNDLE_DIR}/.greentic/dev/.dev.secrets.env"
mkdir -p "$(dirname "${STORE}")"
JWT_SECRET="596ec03de88199a33a950175b958607846a99f8b75b550f21217f16306fcd3c9"
for pair in \
  "base_url=" \
  "jwt_signing_key=${JWT_SECRET}" \
  "mode=local_queue" \
  "public_base_url=http://localhost:${PORT}" \
  "route=webchat" \
  "tenant_channel_id="
do
  name="${pair%%=*}"
  value="${pair#*=}"
  greentic-secrets admin set \
    --env local --tenant default --store-path "${STORE}" --visibility team \
    --category messaging-webchat-gui --name "${name}" --value "${value}" >/dev/null
done

# --- start runtime -----------------------------------------------------------
echo "[runtime] starting on :${PORT}"
RUNTIME_HOME="$(mktemp -d "${WORK_DIR}/runtime-home.XXXXXX")"
GREENTIC_GATEWAY_PORT="${PORT}" \
GREENTIC_GATEWAY_LISTEN_ADDR="127.0.0.1" \
HOME="${RUNTIME_HOME}" \
  gtc start "${BUNDLE_DIR}" --cloudflared off \
  > "${RUNTIME_LOG}" 2>&1 &
RUNTIME_PID=$!

for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${PORT}/readyz" >/dev/null 2>&1; then break; fi
  if ! kill -0 "${RUNTIME_PID}" 2>/dev/null; then
    echo "FAIL: gtc exited during startup" >&2
    tail -40 "${RUNTIME_LOG}" >&2
    exit 1
  fi
  sleep 1
done
if ! curl -sf "http://127.0.0.1:${PORT}/readyz" >/dev/null 2>&1; then
  echo "FAIL: runtime did not pass /readyz within 90s" >&2
  tail -40 "${RUNTIME_LOG}" >&2
  exit 1
fi

# --- probe -------------------------------------------------------------------
BASE="http://127.0.0.1:${PORT}/v1/messaging/webchat/default/v3/directline"
echo "[probe] minting DirectLine token + conversation"
TOKEN=$(curl -sf -X POST "${BASE}/tokens/generate" \
  -H 'Content-Type: application/json' -d '{}' | jq -r '.token')
CONV_RESP=$(curl -sf -X POST "${BASE}/conversations" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}')
CID=$(echo "${CONV_RESP}" | jq -r '.conversationId')
CT=$(echo "${CONV_RESP}" | jq -r '.token')
sleep 1
WM=$(curl -sf "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" | jq -r '.watermark // "0"')

echo "[probe] posting message (type-only messaging ingress)"
curl -sf -X POST "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" -H 'Content-Type: application/json' \
  -d '{"type":"message","from":{"id":"e2e-reviewer"},"text":"route me"}' >/dev/null

ACTS='{"activities":[]}'
for _ in $(seq 1 25); do
  sleep 1
  ACTS=$(curl -sf "${BASE}/conversations/${CID}/activities?watermark=${WM}" \
    -H "Authorization: Bearer ${CT}")
  if echo "${ACTS}" | jq -e '[.activities[] | select(.from.id == "bot")] | length > 0' >/dev/null 2>&1; then
    break
  fi
done
echo "${ACTS}" > "${RESPONSE_FILE}"

# --- assertions --------------------------------------------------------------
# The exact pre-#611 failure string. If the runtime logged this, the resolver
# declared the two same-type flows ambiguous instead of picking the entry flow.
AMBIGUITY_MARKER="is ambiguous; pack_id is required"

problems=()

# (1) A bot reply must have arrived — proves the type-only ingress resolved to
#     the entry flow and ran it. Pre-fix this bundle produced NO reply.
if ! jq -e '[.activities[] | select(.from.id == "bot")] | length > 0' "${RESPONSE_FILE}" >/dev/null 2>&1; then
  problems+=("no bot reply — type-only ingress did not resolve to the entry flow (regression #611)")
fi

# (2) The runtime must NOT have logged the ambiguity bail.
if grep -qF "${AMBIGUITY_MARKER}" "${RUNTIME_LOG}" 2>/dev/null; then
  problems+=("runtime logged the ambiguity bail — two same-type flows were not disambiguated to the entry flow")
fi

# (3) If the runtime logs the resolved flow id, it must be the entry flow and
#     never the internal helper. Absence of any such log line is not a failure
#     (log verbosity varies); a line naming internal_helper as routed IS.
if grep -Eiq 'route|resolv|selected|dispatch' "${RUNTIME_LOG}" 2>/dev/null \
   && grep -Eiq 'internal_helper' "${RUNTIME_LOG}" 2>/dev/null \
   && grep -Ei 'route|resolv|selected|dispatch' "${RUNTIME_LOG}" 2>/dev/null | grep -qi 'internal_helper'; then
  problems+=("runtime routed to internal_helper — an internal flow won a type-only route (regression #611)")
fi

if [ "${#problems[@]}" -eq 0 ]; then
  echo "PASS: type-only ingress resolved to the entry flow across two same-type flows (no ambiguity)"
  exit 0
fi

echo "FAIL: type-only routing regression:" >&2
for p in "${problems[@]}"; do echo "  - ${p}" >&2; done
echo "---runtime log tail---" >&2
tail -60 "${RUNTIME_LOG}" >&2
echo "---activities---" >&2
cat "${RESPONSE_FILE}" >&2 || true
exit 1
