#!/usr/bin/env bash
# End-to-end regression guard for greentic-start #438 (webchat env/revision path
# reply-shaping parity — the env-serve path must shape replies through the SAME
# shared shaper the legacy `--bundle` path uses).
#
# The bug: `gtc start` has two arms.
#   * legacy arm  — `gtc start <bundle_dir>` (a directory)
#   * env-serve   — `gtc start <archive.gtbundle>` (an archive) → the
#                   env/revision serve path (revision_serve.rs)
# The env-serve arm hand-rolled its own reply shaping that recognised only a
# subset of runner reply shapes. Everything it missed — adaptive-card
# attachments, nested renderedCard, messages[]/events[] multi-reply, OAuth
# Connect state, flow errors — was dropped to the webchat provider's "universal
# payload" placeholder (text only). #438 routes the env path through the shared
# `parse_envelopes` shaper so both arms agree.
#
# Why our suite missed it: the WebChat passthrough test
# (`run_webchat_passthrough_e2e.sh`) starts the bundle DIRECTORY → the LEGACY
# arm, which always used the full shaper. Nothing drove a rich reply through the
# ARCHIVE → env-serve arm, where the hand-rolled shaper lived. So the passthrough
# regression was invisible on the exact path that regressed.
#
# This guard reuses the same `webchat-passthrough-probe` pack UNCHANGED, but:
#   1. starts the ARCHIVE (`dist/*.gtbundle`) → forces the env/revision arm,
#   2. asserts the runtime actually took that arm (log: "revision ingress
#      listening" / "serving N revision(s)") — so the guard can never silently
#      pass on the legacy arm,
#   3. asserts the rich reply SURVIVES on the wire: an adaptive-card attachment
#      plus channelData + entities. Pre-#438 the env arm returned the text-only
#      placeholder → no attachment → this fails.
#
# Usage:
#   ./scripts/run_webchat_reply_parity_e2e.sh
#
# Options (env):
#   PORT           HTTP port for gtc start (default 8080)
#   WORK_DIR_BASE  pin scratch tree onto a real (non-symlinked) path (see below)
#   KEEP_BUNDLE    if set, don't wipe the generated bundle on exit
#   SKIP_BUILD     if set, skip the probe WASM + pack rebuild (requires existing dist/)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/webchat-passthrough-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/webchat-passthrough-bundle.json"
PORT="${PORT:-8080}"

# WORK_DIR_BASE lets callers pin the scratch tree onto a real (non-symlinked)
# path. gtc's operator-key writer rejects any symlinked ancestor, and macOS
# `mktemp -t` ignores TMPDIR and lands under /var/folders (a symlink), which
# aborts `gtc start`. CI's Linux /tmp is fine, so this only matters locally.
WORK_DIR="$(mktemp -d "${WORK_DIR_BASE:-${TMPDIR:-/tmp}}/greentic-webchat-parity-XXXXXX")"
BUNDLE_DIR="${WORK_DIR}/bundle"
ANSWERS_FILE="${WORK_DIR}/answers.json"
RUNTIME_LOG="${WORK_DIR}/runtime.log"
RESPONSE_FILE="${WORK_DIR}/activities.json"
# Isolated HOME so the env store lives under scratch, never the operator's real
# ~/.greentic. The env-serve path reads dev secrets from the shared env store
# (~/.greentic/environments/<env>/.greentic/dev/.dev.secrets.env), not the
# bundle-local store, so we must seed THERE (that's part of what #438 aligned).
RUNTIME_HOME="${WORK_DIR}/home"
mkdir -p "${RUNTIME_HOME}"
ENV_ID="local"
ENV_STORE="${RUNTIME_HOME}/.greentic/environments/${ENV_ID}/.greentic/dev/.dev.secrets.env"

cleanup() {
  HOME="${RUNTIME_HOME}" gtc stop 2>/dev/null || true
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

# The env-serve arm is triggered by starting the ARCHIVE (not the directory).
GTBUNDLE="$(ls "${BUNDLE_DIR}"/dist/*.gtbundle 2>/dev/null | head -n1)"
if [ -z "${GTBUNDLE}" ] || [ ! -f "${GTBUNDLE}" ]; then
  echo "FAIL: no .gtbundle produced under ${BUNDLE_DIR}/dist" >&2
  exit 1
fi

# --- seed webchat-gui secrets into the shared ENV store ----------------------
echo "[secrets] seeding messaging-webchat-gui into env store"
mkdir -p "$(dirname "${ENV_STORE}")"
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
  HOME="${RUNTIME_HOME}" greentic-secrets admin set \
    --env "${ENV_ID}" --tenant default --store-path "${ENV_STORE}" --visibility team \
    --category messaging-webchat-gui --name "${name}" --value "${value}" >/dev/null
done

# --- start runtime on the env/revision arm -----------------------------------
echo "[runtime] starting ARCHIVE (env/revision path) on :${PORT}"
GREENTIC_ENV="${ENV_ID}" \
GREENTIC_GATEWAY_PORT="${PORT}" \
GREENTIC_GATEWAY_LISTEN_ADDR="127.0.0.1" \
HOME="${RUNTIME_HOME}" \
  gtc start "${GTBUNDLE}" --cloudflared off \
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

echo "[probe] posting message"
curl -sf -X POST "${BASE}/conversations/${CID}/activities" \
  -H "Authorization: Bearer ${CT}" -H 'Content-Type: application/json' \
  -d '{"type":"message","from":{"id":"e2e-reviewer"},"text":"probe"}' >/dev/null

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
problems=()

# (0) The runtime must actually have taken the env/revision arm. Without this,
#     a future change that quietly routed the archive to the legacy arm would
#     let the guard pass while no longer testing #438's code path.
if ! grep -Eq "revision ingress listening|serving [0-9]+ revision" "${RUNTIME_LOG}" 2>/dev/null; then
  problems+=("runtime did not take the env/revision serve arm — archive start no longer routes to revision_serve; the parity guard is not exercising #438's path")
fi

BOT='[.activities[] | select(.from.id == "bot")][0]'

# (1) A bot reply must have arrived at all.
if ! jq -e '[.activities[] | select(.from.id == "bot")] | length > 0' "${RESPONSE_FILE}" >/dev/null 2>&1; then
  problems+=("no bot reply on the env/revision path")
else
  # (2) The adaptive-card attachment must survive — the headline #438 symptom
  #     was rich shapes collapsing to a text-only "universal payload".
  if ! jq -e "${BOT} | (.attachments // []) | any(.contentType == \"application/vnd.microsoft.card.adaptive\")" \
       "${RESPONSE_FILE}" >/dev/null 2>&1; then
    problems+=("adaptive-card attachment dropped on the env/revision path — reply collapsed to the placeholder (regression #438)")
  fi
  # (3) channelData must survive.
  if ! jq -e "${BOT} | .channelData.bug3_probe == true" "${RESPONSE_FILE}" >/dev/null 2>&1; then
    problems+=("channelData dropped on the env/revision path (regression #438)")
  fi
  # (4) entities must survive.
  if ! jq -e "${BOT} | (.entities // []) | any(.type == \"bug3-probe\")" "${RESPONSE_FILE}" >/dev/null 2>&1; then
    problems+=("entities dropped on the env/revision path (regression #438)")
  fi
fi

if [ "${#problems[@]}" -eq 0 ]; then
  echo "PASS: env/revision path shaped the reply at parity with the legacy path (adaptive card + channelData + entities survived)"
  exit 0
fi

echo "FAIL: webchat env/revision reply-parity regression:" >&2
for p in "${problems[@]}"; do echo "  - ${p}" >&2; done
echo "---runtime log tail---" >&2
tail -60 "${RUNTIME_LOG}" >&2
echo "---bot activity---" >&2
jq "${BOT}" "${RESPONSE_FILE}" >&2 2>/dev/null || cat "${RESPONSE_FILE}" >&2
exit 1
