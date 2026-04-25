#!/usr/bin/env bash
# Regression test for greentic-runner fix `fix/ingress-extensions-and-template-null`
# (commit 22d633b — the second commit on that branch).
#
# Pins: a bare `{{expr}}` template that resolves to a missing key OR explicit
# JSON null must render as the empty string `""`, not propagate as null /
# "not found" — matching the 0.5.4 contract that downstream JSON-Schema
# validators rely on (notably component-llm-openai's `content` field).
#
# Architecture decision: shell test (matches existing greentic-e2e
# convention). The runner already has a unit test for the template renderer
# itself; this file pins the cross-binary behaviour: a flow whose node input
# is `'{{in.input.text}}'`, fed an empty payload, must not error.
#
# Status: SKIP-BY-DEFAULT. Set RUN_E2E=1 to run end-to-end.
#
# Usage:
#   RUN_E2E=1 ./scripts/regression/2026_04_25_null_template_handling.sh
#
# Environment:
#   PORT          HTTP port for greentic-start (default 8082)
#   KEEP_BUNDLE   if set, don't wipe the generated bundle on exit

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/null-template-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/null-template-bundle.json"
PORT="${PORT:-8082}"

# --- skip gate --------------------------------------------------------------
if [ -z "${RUN_E2E:-}" ]; then
  cat >&2 <<'EOF'
[SKIP] 2026_04_25_null_template_handling.sh — full e2e test, gated behind RUN_E2E=1.

What this test pins:
  * greentic-runner fix/ingress-extensions-and-template-null (22d633b):
    bare `{{in.input.text}}` template against a missing or null path renders
    as `""`, not `null` and not "expression not found".

Canonical assertion:
  After posting an empty DirectLine activity (no text body), the runtime
  must:
    1. NOT log `invalid type: null, expected a string`
    2. NOT crash the flow
    3. Produce a bot reply where the rendered content is the empty string

Negative path (regression mode prior to fix):
  The same payload caused component-llm-openai to refuse the request with a
  schema error.

To run end-to-end:
  RUN_E2E=1 PORT=8082 ./scripts/regression/2026_04_25_null_template_handling.sh

Requires:
  gtc, greentic-start, greentic-pack, greentic-secrets, cargo-component,
  curl, jq, python3 on PATH; patched greentic-runner (>= 0.5.10) binary.

Note:
  greentic-runner already has a unit test for the template renderer
  (crates/greentic-runner-host/src/runner/templating.rs ::
   missing_bare_expression_renders_empty_string,
   null_bare_expression_renders_empty_string).
  This script complements it by pinning the cross-binary, full-pack path.
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

WORK_DIR="$(mktemp -d -t greentic-null-template-XXXXXX)"
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
echo "[build] null-template probe WASM + pack"
(cd "${PROBE_PACK_SRC}/components/null-template-probe" \
  && cargo component build --release --target wasm32-wasip2 --quiet)
(cd "${PROBE_PACK_SRC}" && rm -f pack.lock.cbor && greentic-pack build --in . --no-update >/dev/null)

PROBE_PACK="$(ls "${PROBE_PACK_SRC}"/dist/*.gtpack 2>/dev/null | head -n1)"
if [ -z "${PROBE_PACK}" ] || [ ! -f "${PROBE_PACK}" ]; then
  echo "FAIL: probe pack build produced no .gtpack" >&2
  exit 1
fi

# --- render answers + generate bundle ---------------------------------------
echo "[bundle] generating bundle"
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
TOKEN=$(curl -sf -X POST "${BASE}/tokens/generate" \
  -H 'Content-Type: application/json' -d '{}' | jq -r '.token')
CONV_RESP=$(curl -sf -X POST "${BASE}/conversations" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}')
CID=$(echo "${CONV_RESP}" | jq -r '.conversationId')
CT=$(echo "${CONV_RESP}" | jq -r '.token')
sleep 1
WM=$(curl -sf "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" | jq -r '.watermark // "0"')

# Send a payload with NO `text` field — this is the regression payload.
echo "[probe] posting empty message (no text field)"
curl -sf -X POST "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" -H 'Content-Type: application/json' \
  -d '{"type":"message","from":{"id":"e2e-reviewer"}}' >/dev/null

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
# 1. Runtime log MUST NOT contain `invalid type: null, expected a string`.
# 2. Bot reply MUST exist (probe forwards a deterministic reply with the
#    rendered content; rendered content must be the empty string).
if grep -q 'invalid type: null, expected a string' "${RUNTIME_LOG}"; then
  echo "FAIL: runtime logged 'invalid type: null, expected a string' — null-template fix regressed" >&2
  grep -n 'invalid type: null' "${RUNTIME_LOG}" >&2
  exit 1
fi

verdict=$(RESPONSE_FILE="${RESPONSE_FILE}" python3 - <<'PY'
import json, os, sys
resp = json.load(open(os.environ['RESPONSE_FILE']))
bot = [a for a in resp.get('activities', []) if a.get('from', {}).get('id') == 'bot']
if not bot:
    print('NO_BOT_REPLY|flow likely errored on null-template render')
    sys.exit(0)
target = bot[-1]
text = target.get('text') or ''
# The probe encodes its observed `content` field as JSON in the reply text.
try:
    received = json.loads(text)
except Exception as exc:
    print(f'BAD_TEXT|reply text not JSON: {exc}; text={text!r}')
    sys.exit(0)

content = received.get('content', '<missing>')
# Canonical contract: missing/null path renders as ""
if content == '':
    print('PASS|content rendered as empty string')
elif content is None:
    print('FAIL|content rendered as JSON null (regression: should be "")')
else:
    print(f'FAIL|content rendered as {content!r} (expected "")')
PY
)

status="${verdict%%|*}"
detail="${verdict#*|}"

case "${status}" in
  PASS)
    echo "PASS: null-template handling — ${detail}"
    exit 0
    ;;
  NO_BOT_REPLY)
    echo "FAIL: ${detail}" >&2
    echo "---runtime log tail---" >&2
    tail -40 "${RUNTIME_LOG}" >&2
    exit 1
    ;;
  *)
    echo "FAIL: null-template handling — ${detail}" >&2
    cat "${RESPONSE_FILE}" >&2
    exit 1
    ;;
esac
