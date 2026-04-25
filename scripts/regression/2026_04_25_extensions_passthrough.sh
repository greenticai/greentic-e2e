#!/usr/bin/env bash
# Regression test for greentic-runner fix `fix/ingress-extensions-and-template-null`
# (commit a47fae2) AND greentic-start `fix/preserve-envelope-extensions-in-flow-input`
# (commit 8b0a020).
#
# Pins: a synthesised DirectLine activity carrying `channelData.r1_principals`
# must reach the WASM input verbatim at the canonical JSON Pointer
# `/input/extensions/channel_data/r1_principals`.
#
# Why: a regression at this boundary silently dropped channel-specific
# passthrough payloads (the R1 demo's `r1_principals` came through as null on
# 2026-04-25 morning until both repos were patched).
#
# Architecture decision: shell test (matches existing greentic-e2e convention,
# see run_webchat_passthrough_e2e.sh).
#
# Status: SKIP-BY-DEFAULT. Set RUN_E2E=1 to run. The full path requires:
#   - gtc, greentic-start, greentic-pack, greentic-secrets, jq, curl, python3
#   - patched greentic-runner (>= 0.5.10) + patched greentic-start (>= 0.5.4)
#   - probe pack at fixtures/packs/extensions-passthrough-probe (this script
#     builds it from the on-disk fixture; the WASM probe is the same one used
#     by run_webchat_passthrough_e2e.sh — bug3-test echoes envelope.extensions
#     into the bot reply via emit.response handlebars templates)
#
# Usage:
#   RUN_E2E=1 ./scripts/regression/2026_04_25_extensions_passthrough.sh
#
# Environment:
#   PORT          HTTP port for greentic-start (default 8080)
#   KEEP_BUNDLE   if set, don't wipe the generated bundle on exit

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/extensions-passthrough-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/extensions-passthrough-bundle.json"
PORT="${PORT:-8080}"

# --- skip gate --------------------------------------------------------------
if [ -z "${RUN_E2E:-}" ]; then
  cat >&2 <<'EOF'
[SKIP] 2026_04_25_extensions_passthrough.sh — full e2e test, gated behind RUN_E2E=1.

What this test pins:
  * greentic-runner fix/ingress-extensions-and-template-null (a47fae2):
    DirectLine `channelData` plumbs through Activity → IngressEnvelope → WASM
    input.
  * greentic-start fix/preserve-envelope-extensions-in-flow-input (8b0a020):
    `ChannelMessageEnvelope.extensions` survives the json!({"input": envelope})
    shape that run_app_flow builds for the runner.

Canonical assertion:
  WASM input contains
    /input/extensions/channel_data/r1_principals
  with the original payload preserved (snake_case key names).

To run end-to-end:
  RUN_E2E=1 PORT=8080 ./scripts/regression/2026_04_25_extensions_passthrough.sh

Requires:
  gtc, greentic-start, greentic-pack, greentic-secrets, cargo-component,
  curl, jq, python3 on PATH; patched greentic-runner + greentic-start binaries.
EOF
  exit 0
fi

# --- preflight --------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 not found on PATH" >&2; exit 1; }; }
need gtc
need greentic-start
need greentic-secrets
need greentic-pack
need cargo-component
need curl
need jq
need python3

if [ ! -f "${ANSWERS_TEMPLATE}" ]; then
  echo "FAIL: missing wizard answers template at ${ANSWERS_TEMPLATE}" >&2
  exit 1
fi
if [ ! -d "${PROBE_PACK_SRC}" ]; then
  echo "FAIL: missing probe pack source at ${PROBE_PACK_SRC}" >&2
  exit 1
fi
if lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: port ${PORT} is already in use" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t greentic-extensions-passthrough-XXXXXX)"
BUNDLE_DIR="${WORK_DIR}/bundle"
ANSWERS_FILE="${WORK_DIR}/answers.json"
RUNTIME_LOG="${WORK_DIR}/runtime.log"
RESPONSE_FILE="${WORK_DIR}/activities.json"

cleanup() {
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

# --- build probe pack -------------------------------------------------------
echo "[build] probe WASM + pack"
(cd "${PROBE_PACK_SRC}/components/extensions-probe" \
  && cargo component build --release --target wasm32-wasip2 --quiet)
(cd "${PROBE_PACK_SRC}" && rm -f pack.lock.cbor && greentic-pack build --in . --no-update >/dev/null)

PROBE_PACK="$(ls "${PROBE_PACK_SRC}"/dist/*.gtpack 2>/dev/null | head -n1)"
if [ -z "${PROBE_PACK}" ] || [ ! -f "${PROBE_PACK}" ]; then
  echo "FAIL: probe pack build produced no .gtpack" >&2
  exit 1
fi

# --- render answers + generate bundle ---------------------------------------
echo "[bundle] generating bundle from wizard answers"
python3 - <<PY
import pathlib
tpl = pathlib.Path("${ANSWERS_TEMPLATE}").read_text()
tpl = tpl.replace("{{PROBE_PACK_PATH}}", "${PROBE_PACK}")
tpl = tpl.replace("{{BUNDLE_DIR}}", "${BUNDLE_DIR}")
pathlib.Path("${ANSWERS_FILE}").write_text(tpl)
PY
gtc wizard --answers "${ANSWERS_FILE}" >/dev/null

# --- seed webchat-gui secrets -----------------------------------------------
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
(cd "${BUNDLE_DIR}" && GREENTIC_GATEWAY_PORT="${PORT}" greentic-start --locale en start --bundle . \
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
echo "[probe] minting DirectLine token"
TOKEN=$(curl -sf -X POST "${BASE}/tokens/generate" \
  -H 'Content-Type: application/json' -d '{}' | jq -r '.token')
CONV_RESP=$(curl -sf -X POST "${BASE}/conversations" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}')
CID=$(echo "${CONV_RESP}" | jq -r '.conversationId')
CT=$(echo "${CONV_RESP}" | jq -r '.token')
sleep 1
WM=$(curl -sf "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" | jq -r '.watermark // "0"')

echo "[probe] posting message with channelData.r1_principals"
curl -sf -X POST "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" -H 'Content-Type: application/json' \
  -d '{
    "type":"message",
    "from":{"id":"e2e-reviewer"},
    "text":"probe-extensions",
    "channelData":{
      "r1_principals":{"country":"US","industry":"telecom"}
    }
  }' >/dev/null

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
# The probe component echoes WASM input back into the bot reply text as JSON.
# We assert the canonical JSON Pointer is preserved AND camelCase is absent.
verdict=$(RESPONSE_FILE="${RESPONSE_FILE}" python3 - <<'PY'
import json, os, sys
resp = json.load(open(os.environ['RESPONSE_FILE']))
bot = [a for a in resp.get('activities', []) if a.get('from', {}).get('id') == 'bot']
if not bot:
    print('NO_BOT_REPLY|')
    sys.exit(0)
# The probe encodes the received WASM input JSON in `text`.
target = bot[-1]
text = target.get('text') or ''
try:
    received = json.loads(text)
except Exception as exc:
    print(f'BAD_TEXT|reply text not JSON: {exc}; text={text!r}')
    sys.exit(0)

# Canonical assertion: snake_case keys at /input/extensions/channel_data/r1_principals
def at(d, path):
    cur = d
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur

r1 = at(received, ['input', 'extensions', 'channel_data', 'r1_principals'])
problems = []
if r1 is None:
    problems.append('missing /input/extensions/channel_data/r1_principals (regression in runner or greentic-start)')
else:
    if r1.get('country') != 'US':
        problems.append(f'r1_principals.country mutated: {r1.get("country")!r}')
    if r1.get('industry') != 'telecom':
        problems.append(f'r1_principals.industry mutated: {r1.get("industry")!r}')

# camelCase forms must NOT appear
if at(received, ['input', 'extensions', 'channelData']) is not None:
    problems.append('extensions.channelData (camelCase) leaked — must be channel_data')
if at(received, ['input', 'channelData']) is not None:
    problems.append('input.channelData appeared at wrong nesting (must be inside extensions.)')

if problems:
    print('FAIL|' + '; '.join(problems))
else:
    print('PASS|extensions.channel_data.r1_principals reached WASM input')
PY
)

status="${verdict%%|*}"
detail="${verdict#*|}"

case "${status}" in
  PASS)
    echo "PASS: extensions passthrough — ${detail}"
    exit 0
    ;;
  NO_BOT_REPLY)
    echo "FAIL: no bot reply received within 25s" >&2
    tail -40 "${RUNTIME_LOG}" >&2
    cat "${RESPONSE_FILE}" >&2 || true
    exit 1
    ;;
  *)
    echo "FAIL: extensions passthrough — ${detail}" >&2
    cat "${RESPONSE_FILE}" >&2
    exit 1
    ;;
esac
