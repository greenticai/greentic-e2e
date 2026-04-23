#!/usr/bin/env bash
# End-to-end regression guard for TASK-082 Bug 3 / Bug 4 (WebChat DirectLine
# envelope passthrough). Catches:
#
#   * Bug 3 — attachments / channelData / entities stripped before reaching the
#     DirectLine wire (symptom: zero attachments, missing channelData).
#   * Bug 4 — attachments duplicated on the DirectLine wire (symptom: two or
#     more byte-identical entries).
#
# The probe flow emits exactly 1 Adaptive Card attachment + channelData +
# entities from `fixtures/packs/webchat-passthrough-probe`. After round-tripping
# through greentic-start → runner → messaging-webchat-gui provider → DirectLine
# state store → GET /activities, the test asserts the activity carries exactly
# one attachment with the original SHA-256 and the channelData / entities
# fields intact.
#
# Why this exists separately from `run_provider_e2e.sh`: the provider e2e
# script tests ingress and lifecycle but not the attachments passthrough
# contract, and attachments-passthrough has regressed three times in 2026-04.
#
# Usage:
#   ./scripts/run_webchat_passthrough_e2e.sh
#
# Options (env):
#   PORT            HTTP port for greentic-start (default 8091)
#   KEEP_BUNDLE     if set, don't wipe the generated bundle on exit
#   SKIP_BUILD      if set, skip the probe WASM + pack rebuild (requires existing dist/)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/webchat-passthrough-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/webchat-passthrough-bundle.json"
# greentic-start 0.5.x binds HTTP to a bundle-derived port (default 8080) and
# does not expose a --port flag; override via env var isn't supported either.
# Hard-code here; the preflight check guards against a conflict.
PORT="${PORT:-8080}"

WORK_DIR="$(mktemp -d -t greentic-webchat-attach-XXXXXX)"
BUNDLE_DIR="${WORK_DIR}/bundle"
ANSWERS_FILE="${WORK_DIR}/answers.json"
RUNTIME_LOG="${WORK_DIR}/runtime.log"
RESPONSE_FILE="${WORK_DIR}/activities.json"

cleanup() {
  # Stop runtime first so it flushes the state store cleanly
  if [ -n "${RUNTIME_PID:-}" ]; then
    kill "${RUNTIME_PID}" 2>/dev/null || true
  fi
  pkill -f "greentic-start.*start.*--bundle" 2>/dev/null || true
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
need greentic-start
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
import json, pathlib
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
    --env dev --tenant default --store-path "${STORE}" --visibility team \
    --category messaging-webchat-gui --name "${name}" --value "${value}" >/dev/null
done

# --- start runtime -----------------------------------------------------------
echo "[runtime] starting on :${PORT}"
(cd "${BUNDLE_DIR}" && greentic-start --locale en start --bundle . \
    --nats off --cloudflared off --ngrok off \
    > "${RUNTIME_LOG}" 2>&1) &
RUNTIME_PID=$!

for _ in $(seq 1 90); do
  if grep -q '^Ready\.' "${RUNTIME_LOG}" 2>/dev/null; then break; fi
  if ! kill -0 "${RUNTIME_PID}" 2>/dev/null; then
    echo "FAIL: runtime exited during startup" >&2
    tail -40 "${RUNTIME_LOG}" >&2
    exit 1
  fi
  sleep 1
done
if ! grep -q '^Ready\.' "${RUNTIME_LOG}"; then
  echo "FAIL: runtime did not become Ready within 90s" >&2
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

echo "[probe] posting message"
curl -sf -X POST "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" -H 'Content-Type: application/json' \
  -d '{"type":"message","from":{"id":"e2e-reviewer"},"text":"probe"}' >/dev/null

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
verdict=$(RESPONSE_FILE="${RESPONSE_FILE}" python3 - <<'PY'
import hashlib, json, os, sys
resp = json.load(open(os.environ['RESPONSE_FILE']))
bot = [a for a in resp.get('activities', []) if a.get('from', {}).get('id') == 'bot']
if not bot:
    print('NO_BOT_REPLY|')
    sys.exit(0)
target = next((a for a in bot if a.get('attachments') or 'Bug 3 probe' in (a.get('text') or '')), bot[-1])

atts = target.get('attachments') or []
channel_data = target.get('channelData') or {}
entities = target.get('entities') or []

problems = []
if len(atts) == 0:
    problems.append('attachments stripped (Bug 3)')
elif len(atts) >= 2:
    hashes = {hashlib.sha256(json.dumps(a, sort_keys=True).encode()).hexdigest() for a in atts}
    if len(hashes) == 1:
        problems.append(f'attachments duplicated: {len(atts)} identical entries (Bug 4)')
    else:
        problems.append(f'unexpected: {len(atts)} distinct attachments')

if not channel_data or not channel_data.get('bug3_probe'):
    problems.append('channelData.bug3_probe missing (partial strip)')

if not any(e.get('type') == 'bug3-probe' for e in entities):
    problems.append('entities[bug3-probe] missing (partial strip)')

if problems:
    print('FAIL|' + '; '.join(problems))
else:
    print('PASS|1 attachment, channelData+entities preserved')
PY
)

status="${verdict%%|*}"
detail="${verdict#*|}"

case "${status}" in
  PASS)
    echo "PASS: webchat attachments passthrough — ${detail}"
    exit 0
    ;;
  NO_BOT_REPLY)
    echo "FAIL: no bot reply received within 25s — runtime may not have loaded the pack" >&2
    echo "---runtime log tail---" >&2
    tail -40 "${RUNTIME_LOG}" >&2
    echo "---activities---" >&2
    cat "${RESPONSE_FILE}" >&2 || true
    exit 1
    ;;
  *)
    echo "FAIL: webchat attachments regression — ${detail}" >&2
    echo "---activities---" >&2
    cat "${RESPONSE_FILE}" >&2
    exit 1
    ;;
esac
