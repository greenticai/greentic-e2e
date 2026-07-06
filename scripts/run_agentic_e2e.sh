#!/usr/bin/env bash
#
# Agentic-worker (dw.agent) end-to-end test.
#
# Guards the agentic demo on greentic-demo: it installs/uses a bundle that
# contains a Digital Worker (`dw.agent`) flow, boots it with `gtc start`, drives
# a full Plan-Act-Observe turn through the synchronous `POST /agent/chat`
# endpoint, and asserts the worker produced a real, non-empty reply.
#
# This is the regression guard for the whole agentic runtime chain
# (greentic-aw-runtime -> greentic-ext-runtime -> greentic-runner -> gtc): if a
# future change stops `dw.agent` from loading or answering, this test fails.
#
# Requirements:
#   - `gtc` installed and carrying dw.agent (>= 1.1.x toolchain).
#   - An LLM API key (GREENTIC_LLM_API_KEY). No Redis needed — the worker falls
#     back to in-memory state when GREENTIC_AW_REDIS_URL is unset.
#   - Optional TAVILY_API_KEY when the bundle's worker uses the Tavily tool.
#
# Usage:
#   GREENTIC_LLM_API_KEY=sk-... ./scripts/run_agentic_e2e.sh
#   ./scripts/run_agentic_e2e.sh --bundle /path/to/agentic-bundle
#   ./scripts/run_agentic_e2e.sh --dry-run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Configuration (env-overridable) ---------------------------------------
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
GTC_CMD_TIMEOUT="${GTC_CMD_TIMEOUT:-45}"
GTC_START_TIMEOUT="${GTC_START_TIMEOUT:-120}"
AGENT_TURN_TIMEOUT="${AGENT_TURN_TIMEOUT:-90}"
GATEWAY_PORT="${GREENTIC_GATEWAY_PORT:-8080}"

# Where to get the agentic bundle. A released .gtbundle URL from greentic-demo,
# or a local directory passed via --bundle.
AGENTIC_BUNDLE_SOURCE="${GREENTIC_AGENTIC_BUNDLE_SOURCE:-https://github.com/greenticai/greentic-demo/releases/latest/download/agentic-research-tavily-demo.gtbundle}"
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-}"

# /agent/chat routing. The bundle sets these up; override if your bundle differs.
AGENT_TENANT="${GREENTIC_AGENT_TENANT:-agentic-research-tavily-demo}"
AGENT_FLOW_ID="${GREENTIC_AGENT_FLOW_ID:-}"
AGENT_PROMPT="${GREENTIC_AGENT_PROMPT:-In one short sentence, what is the capital of Japan?}"

SETUP_ANSWERS="${SETUP_ANSWERS:-${REPO_ROOT}/fixtures/setup-answers/agentic-research-tavily.json}"

START_PID=""
TEMP_DIR=""

# --- Argument parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)         E2E_BUNDLE_DIR="$2"; shift 2 ;;
    --bundle-source)  AGENTIC_BUNDLE_SOURCE="$2"; shift 2 ;;
    --prompt)         AGENT_PROMPT="$2"; shift 2 ;;
    --tenant)         AGENT_TENANT="$2"; shift 2 ;;
    --flow-id)        AGENT_FLOW_ID="$2"; shift 2 ;;
    --answers)        SETUP_ANSWERS="$2"; shift 2 ;;
    --keep-running)   KEEP_RUNNING="true"; shift ;;
    --dry-run)        DRY_RUN="true"; shift ;;
    --verbose)        VERBOSE="true"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Helpers ---------------------------------------------------------------
log()         { echo "[agentic-e2e] $*"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo "[agentic-e2e][debug] $*" || true; }
die()         { echo "[agentic-e2e][ERROR] $*" >&2; exit 1; }

# Cross-platform timeout wrapper (perl, like run_provider_e2e.sh).
run_with_timeout() {
  local secs="$1"; shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid = fork();
    if ($pid == 0) { exec @ARGV or exit 127; }
    local $SIG{ALRM} = sub { kill "TERM", $pid; exit 124; };
    alarm $secs;
    waitpid($pid, 0);
    exit($? >> 8);
  ' "$secs" "$@"
}

cleanup() {
  if [[ "$KEEP_RUNNING" == "true" ]]; then
    log "Leaving services running (--keep-running); PID=${START_PID}"
    return
  fi
  if [[ -n "${START_PID}" ]] && kill -0 "${START_PID}" 2>/dev/null; then
    log "Stopping gtc start (PID ${START_PID})"
    kill -TERM "${START_PID}" 2>/dev/null || true
    sleep 2
    kill -KILL "${START_PID}" 2>/dev/null || true
  fi
  # Backstop: the runner process, if it detached.
  pkill -f "greentic-runner" 2>/dev/null || true
  [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Preconditions ---------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
  command -v gtc >/dev/null 2>&1 || die "gtc not found on PATH (install a >=1.1.x toolchain that carries dw.agent)"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v perl >/dev/null 2>&1 || die "perl is required (timeout wrapper)"
  [[ -n "${GREENTIC_LLM_API_KEY:-}" ]] || die "GREENTIC_LLM_API_KEY is required (the worker needs an LLM key)"
fi

# --- Step 1: Resolve the bundle --------------------------------------------
if [[ -z "${E2E_BUNDLE_DIR}" ]]; then
  TEMP_DIR="$(mktemp -d)"
  E2E_BUNDLE_DIR="${TEMP_DIR}/agentic-bundle"
  mkdir -p "${E2E_BUNDLE_DIR}"
  log "Step 1: Fetching agentic bundle from ${AGENTIC_BUNDLE_SOURCE}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would download + unpack ${AGENTIC_BUNDLE_SOURCE} into ${E2E_BUNDLE_DIR}"
  else
    curl -fSL "${AGENTIC_BUNDLE_SOURCE}" -o "${TEMP_DIR}/bundle.gtbundle" \
      || die "failed to download bundle from ${AGENTIC_BUNDLE_SOURCE}"
    # .gtbundle is a tar/zip archive; try both.
    tar -xzf "${TEMP_DIR}/bundle.gtbundle" -C "${E2E_BUNDLE_DIR}" 2>/dev/null \
      || unzip -q "${TEMP_DIR}/bundle.gtbundle" -d "${E2E_BUNDLE_DIR}" 2>/dev/null \
      || die "could not unpack bundle (not tar.gz or zip)"
  fi
else
  log "Step 1: Using local bundle ${E2E_BUNDLE_DIR}"
  [[ "$DRY_RUN" == "true" || -d "${E2E_BUNDLE_DIR}" ]] || die "bundle dir not found: ${E2E_BUNDLE_DIR}"
fi

# --- Step 2: Setup (seals LLM/tool secrets) --------------------------------
log "Step 2: gtc setup"
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would run: gtc setup --non-interactive --answers ${SETUP_ANSWERS} ${E2E_BUNDLE_DIR}"
else
  [[ -f "${SETUP_ANSWERS}" ]] || die "setup answers not found: ${SETUP_ANSWERS}"
  # Env vars (GREENTIC_LLM_API_KEY, TAVILY_API_KEY) are substituted by gtc setup.
  run_with_timeout "$GTC_CMD_TIMEOUT" \
    gtc setup --non-interactive --answers "${SETUP_ANSWERS}" "${E2E_BUNDLE_DIR}" \
    || die "gtc setup failed"
fi

# --- Step 3: Start ---------------------------------------------------------
log "Step 3: gtc start (port ${GATEWAY_PORT})"
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would start: gtc start ${E2E_BUNDLE_DIR} --cloudflared off --ngrok off"
  log "[DRY RUN] Would POST /agent/chat and assert a non-empty reply. Done."
  exit 0
fi

# dw.agent runs with in-memory state when GREENTIC_AW_REDIS_URL is unset.
GREENTIC_GATEWAY_PORT="${GATEWAY_PORT}" gtc start "${E2E_BUNDLE_DIR}" \
  --cloudflared off --ngrok off &
START_PID=$!
log "gtc start PID ${START_PID}"

# --- Step 4: Wait for the gateway to be ready ------------------------------
log "Step 4: Waiting for gateway on 127.0.0.1:${GATEWAY_PORT}"
ready=false
for _ in $(seq 1 "${GTC_START_TIMEOUT}"); do
  if ! kill -0 "${START_PID}" 2>/dev/null; then
    die "gtc start exited before the gateway came up"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^[2-4][0-9][0-9]$ ]]; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == "true" ]] || die "gateway did not become ready within ${GTC_START_TIMEOUT}s"
log "Gateway ready"

# --- Step 5: Drive one dw.agent turn via /agent/chat -----------------------
log "Step 5: POST /agent/chat — prompt: \"${AGENT_PROMPT}\""
REQ="$(AGENT_PROMPT="${AGENT_PROMPT}" AGENT_TENANT="${AGENT_TENANT}" AGENT_FLOW_ID="${AGENT_FLOW_ID}" python3 - <<'PY'
import json, os
req = {"text": os.environ["AGENT_PROMPT"], "tenant": os.environ["AGENT_TENANT"]}
if os.environ.get("AGENT_FLOW_ID"):
    req["flow_id"] = os.environ["AGENT_FLOW_ID"]
print(json.dumps(req))
PY
)"
log_verbose "request: ${REQ}"

RESP="$(run_with_timeout "${AGENT_TURN_TIMEOUT}" \
  curl -s -w $'\n%{http_code}' \
  -X POST "http://127.0.0.1:${GATEWAY_PORT}/agent/chat" \
  -H "Content-Type: application/json" \
  -d "${REQ}" 2>&1)" || die "request to /agent/chat timed out or failed"

HTTP_CODE="$(echo "${RESP}" | tail -1)"
BODY="$(echo "${RESP}" | sed '$d')"
log "HTTP ${HTTP_CODE}"
log_verbose "body: ${BODY}"

[[ "$HTTP_CODE" == "200" ]] || die "/agent/chat returned HTTP ${HTTP_CODE} (expected 200). Body: ${BODY}"

# --- Step 6: Assert the worker actually replied ----------------------------
REPLY="$(echo "${BODY}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write(f"non-JSON response: {exc}\n"); sys.exit(3)
replies = data.get("replies", [])
texts = [r.get("text", "").strip() for r in replies if r.get("text", "").strip()]
if not texts:
    sys.stderr.write("empty reply — dw.agent produced no text\n"); sys.exit(4)
print(texts[0])
' )" || die "dw.agent did not return a usable reply. Body: ${BODY}"

log "PASS: dw.agent replied → \"${REPLY}\""
log "Agentic-worker e2e succeeded."
exit 0
