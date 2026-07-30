#!/usr/bin/env bash
#
# Agentic-worker (dw.agent) end-to-end test.
#
# Guards the agentic demo on greentic-demo: it installs/uses a bundle that
# contains a Digital Worker (`dw.agent`) flow, boots it with `gtc start`, drives
# a full Plan-Act-Observe turn over the WebChat DirectLine rail (token ->
# conversation -> message -> poll), and asserts the worker produced a reply.
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
AGENTIC_BUNDLE_SOURCE="${GREENTIC_AGENTIC_BUNDLE_SOURCE:-https://github.com/greenticai/greentic-demo/releases/latest/download/agentic-research-tavily-demo-bundle.gtbundle}"
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-}"

# Webchat tenant + prompt. The demo's published answers seal the webchat rail
# under tenant `demo` (setup-answers.json: tenant=demo), so that is the tenant
# the DirectLine endpoints live under — not the bundle/pack name.
AGENT_TENANT="${GREENTIC_AGENT_TENANT:-demo}"
AGENT_FLOW_ID="${GREENTIC_AGENT_FLOW_ID:-}"
AGENT_PROMPT="${GREENTIC_AGENT_PROMPT:-In one short sentence, what is the capital of Japan?}"
# A substring the reply must contain, so the assertion tests the ANSWER and not
# merely that some bytes came back. Tied to AGENT_PROMPT — override both together.
AGENT_EXPECT="${GREENTIC_AGENT_EXPECT:-Tokyo}"

# Known-broken LLM key escape hatch. When the DeepSeek key is flagged
# non-functional (out of balance, revoked, upstream contract change), stand this
# test down with a graceful SKIP instead of letting the live agent turn fail —
# the worker can't answer without a working LLM, and that's not a regression in
# this repo. Mirrors the Playwright DEEPSEEK_KNOWN_BROKEN opt-out. Unset it once
# the key works to restore the guard.
case "$(printf '%s' "${DEEPSEEK_KNOWN_BROKEN:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes)
    echo "SKIP: DEEPSEEK_KNOWN_BROKEN set — DeepSeek key flagged non-functional; standing the agentic-worker e2e down (unset DEEPSEEK_KNOWN_BROKEN to restore)."
    exit 0
    ;;
esac

# Setup answers. Default to the demo's OWN published answers rather than a
# vendored copy: greentic-demo ships <demo>-setup-answers.json next to the
# bundle, already parameterised with ${GREENTIC_LLM_API_KEY} / ${TAVILY_API_KEY}
# placeholders for us to envsubst. A hand-maintained fixture drifts from the
# bundle (it did: it was missing the messaging-webchat-gui answers entirely, so
# `gtc setup --non-interactive` failed on a missing public_base_url). Override
# with --answers <file> to pin a local copy.
AGENTIC_SETUP_ANSWERS_SOURCE="${GREENTIC_AGENTIC_SETUP_ANSWERS_SOURCE:-https://github.com/greenticai/greentic-demo/releases/latest/download/agentic-research-tavily-demo-setup-answers.json}"
SETUP_ANSWERS="${SETUP_ANSWERS:-}"

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
  if [[ -z "${E2E_BUNDLE_DIR}" ]]; then
    command -v unsquashfs >/dev/null 2>&1 \
      || die "unsquashfs is required to unpack a .gtbundle (apt: squashfs-tools, brew: squashfs)"
  fi
  if [[ -z "${SETUP_ANSWERS}" ]]; then
    command -v envsubst >/dev/null 2>&1 \
      || die "envsubst is required to fill the published setup answers (apt: gettext-base, brew: gettext)"
  fi
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
    # A .gtbundle is a squashfs image — greentic-bundle emits it with mksquashfs.
    # (Older/hand-rolled bundles were tar/zip, so keep those as fallbacks.)
    unsquashfs -q -f -d "${E2E_BUNDLE_DIR}" "${TEMP_DIR}/bundle.gtbundle" >/dev/null 2>&1 \
      || tar -xzf "${TEMP_DIR}/bundle.gtbundle" -C "${E2E_BUNDLE_DIR}" 2>/dev/null \
      || unzip -q "${TEMP_DIR}/bundle.gtbundle" -d "${E2E_BUNDLE_DIR}" 2>/dev/null \
      || die "could not unpack bundle (not squashfs, tar.gz, or zip)"
    [[ -f "${E2E_BUNDLE_DIR}/bundle.yaml" ]] \
      || die "unpacked bundle has no bundle.yaml at ${E2E_BUNDLE_DIR}"
  fi
else
  log "Step 1: Using local bundle ${E2E_BUNDLE_DIR}"
  [[ "$DRY_RUN" == "true" || -d "${E2E_BUNDLE_DIR}" ]] || die "bundle dir not found: ${E2E_BUNDLE_DIR}"
fi

# --- Step 2: Setup (seals LLM/tool secrets) --------------------------------
log "Step 2: gtc setup"
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would fetch ${AGENTIC_SETUP_ANSWERS_SOURCE} and run: gtc setup --non-interactive --answers <answers> ${E2E_BUNDLE_DIR}"
else
  if [[ -z "${SETUP_ANSWERS}" ]]; then
    # Pull the demo's own published answers, then fill the ${...} secret
    # placeholders from the environment.
    [[ -n "${TEMP_DIR}" ]] || TEMP_DIR="$(mktemp -d)"
    raw="${TEMP_DIR}/setup-answers.raw.json"
    SETUP_ANSWERS="${TEMP_DIR}/setup-answers.json"
    log_verbose "fetching setup answers from ${AGENTIC_SETUP_ANSWERS_SOURCE}"
    curl -fsSL "${AGENTIC_SETUP_ANSWERS_SOURCE}" -o "${raw}" \
      || die "failed to download setup answers from ${AGENTIC_SETUP_ANSWERS_SOURCE}"
    # TAVILY_API_KEY is optional; envsubst would otherwise leave it unset and
    # emit a literal empty string, which is what we want.
    GREENTIC_LLM_API_KEY="${GREENTIC_LLM_API_KEY:-}" \
    TAVILY_API_KEY="${TAVILY_API_KEY:-}" \
      envsubst < "${raw}" > "${SETUP_ANSWERS}" \
      || die "envsubst failed on ${raw}"

    # Drop answer sections gtc cannot accept, or setup fails closed on B12a:
    #
    #   * packs the bundle does not ship at all (currently
    #     `agentic-research-tavily-agent` — the published answers name it but no
    #     such .gtpack is in the bundle), and
    #   * packs that ship no setup metadata (currently
    #     `agentic-research-tavily-demo` — no assets/setup.yaml, no
    #     secret-requirements). gtc refuses to classify answers as secret-or-not
    #     for such a pack and aborts rather than risk writing plaintext.
    #
    # In both cases the B12a error blames the pack's contents, which sends you
    # looking in the wrong place. The agent still gets its credentials: dw.agent
    # reads GREENTIC_LLM_API_KEY / TAVILY_API_KEY from the environment, which we
    # export into `gtc start` below.
    python3 - "${SETUP_ANSWERS}" "${E2E_BUNDLE_DIR}" <<'PY'
import json, pathlib, sys, zipfile

answers_path, bundle_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
doc = json.loads(answers_path.read_text())
answers = doc.get("setup_answers")

def accepts_answers(pack: pathlib.Path) -> bool:
    """True if the pack ships metadata letting gtc classify answers as secrets."""
    try:
        with zipfile.ZipFile(pack) as z:
            names = z.namelist()
    except Exception:
        return False
    return any(
        n.endswith("setup.yaml")
        or "secret-requirements" in n
        or "secret_requirements" in n
        or (n.startswith("qa/") and n.endswith(".json"))
        for n in names
    )

if isinstance(answers, dict):
    packs = {p.stem: p for p in bundle_dir.rglob("*.gtpack")}
    missing = [k for k in answers if k not in packs]
    no_meta = [k for k in answers if k in packs and not accepts_answers(packs[k])]
    for k in missing + no_meta:
        del answers[k]
    if missing:
        print(f"[agentic-e2e] dropped answers for packs not in the bundle: {', '.join(sorted(missing))}")
    if no_meta:
        print(f"[agentic-e2e] dropped answers for packs shipping no setup metadata: {', '.join(sorted(no_meta))}")
    if not answers:
        sys.exit("[agentic-e2e][ERROR] no usable setup answers left — the bundle changed shape")
    answers_path.write_text(json.dumps(doc, indent=2) + "\n")
PY
  fi
  [[ -f "${SETUP_ANSWERS}" ]] || die "setup answers not found: ${SETUP_ANSWERS}"
  run_with_timeout "$GTC_CMD_TIMEOUT" \
    gtc setup --non-interactive --answers "${SETUP_ANSWERS}" "${E2E_BUNDLE_DIR}" \
    || die "gtc setup failed"
fi

# --- Step 3: Start ---------------------------------------------------------
log "Step 3: gtc start (port ${GATEWAY_PORT})"
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would start: gtc start ${E2E_BUNDLE_DIR} --cloudflared off --ngrok off"
  log "[DRY RUN] Would drive one webchat turn and assert a non-empty reply. Done."
  exit 0
fi

# Refuse to run against someone else's gateway. The readiness check below only
# asks "is something answering on this port?", so a leftover greentic-start from
# an earlier run happily satisfies it — and then the turn is driven against THAT
# demo. This is not hypothetical: this test once passed on
# "WeatherAPI is configured via secrets…", a reply from the weather demo.
# Whatever is listening, it is not the bundle we just built, so stop.
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null; then
  die "something is already listening on 127.0.0.1:${GATEWAY_PORT} — refusing to start.
  A stale greentic-start/greentic-runner would silently answer this test's traffic
  and it would pass against the wrong demo. Kill it first:
      pkill -f greentic-start; pkill -f greentic-runner
  or point this run elsewhere with GREENTIC_GATEWAY_PORT=<free port>."
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

# --- Step 5+6: Drive one dw.agent turn over the WebChat DirectLine rail -----
# The agentic demo is exposed through webchat (not a synchronous endpoint): mint
# a token, open a conversation, post the user message, then poll activities for
# the worker's reply. The reply may arrive as plain text or as an Adaptive Card
# (the demo's render_answer node), so we accept either.
log "Step 5: driving one dw.agent turn over webchat — prompt: \"${AGENT_PROMPT}\""
REPLY="$(GATEWAY_PORT="${GATEWAY_PORT}" AGENT_TENANT="${AGENT_TENANT}" \
  AGENT_PROMPT="${AGENT_PROMPT}" AGENT_TURN_TIMEOUT="${AGENT_TURN_TIMEOUT}" \
  AGENT_EXPECT="${AGENT_EXPECT}" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error

base = f"http://127.0.0.1:{os.environ['GATEWAY_PORT']}/v1/messaging/webchat/{os.environ['AGENT_TENANT']}"
deadline = int(os.environ.get("AGENT_TURN_TIMEOUT", "90"))

def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=deadline) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()

# A reply that is merely non-empty proves nothing: the runtime's generic failure
# card and a stray reply from another pack both satisfy it. Require a real answer.
ERROR_MARKERS = (
    "something went wrong",
    "please try again",
    "i'm not sure what you meant",
    "service is unavailable",
)
EXPECT = os.environ.get("AGENT_EXPECT", "").strip()

def reply_text(activity):
    text = (activity.get("text") or "").strip()
    if text:
        return text
    # Adaptive Card fallback: pull the last non-title TextBlock.
    for att in activity.get("attachments", []):
        for block in att.get("content", {}).get("body", []):
            if block.get("type") == "TextBlock":
                t = (block.get("text") or "").strip()
                if t:
                    text = t
    return text

status, body = call("POST", "/token", {})
if status != 200:
    sys.stderr.write(f"token request failed: HTTP {status} {body}\n"); sys.exit(3)
token = json.loads(body)["token"]

status, body = call("POST", "/v3/directline/conversations", {}, token)
if status not in (200, 201):
    sys.stderr.write(f"start conversation failed: HTTP {status} {body}\n"); sys.exit(3)
conv = json.loads(body)["conversationId"]

msg = {"type": "message", "from": {"id": "e2e-user", "name": "E2E"}, "text": os.environ["AGENT_PROMPT"]}
status, body = call("POST", f"/v3/directline/conversations/{conv}/activities", msg, token)
if status not in (200, 201):
    sys.stderr.write(f"send message failed: HTTP {status} {body}\n"); sys.exit(3)

# Best-effort diagnostic: the last non-user reply that was not the answer, so a
# deadline miss can say WHAT the worker sent instead of just "timed out".
last_other = None

for _ in range(max(1, deadline // 3)):
    time.sleep(3)
    status, body = call("GET", f"/v3/directline/conversations/{conv}/activities", None, token)
    try:
        data = json.loads(body)
    except Exception:
        continue
    for activity in data.get("activities", []):
        if activity.get("from", {}).get("id") == "e2e-user":
            continue
        text = reply_text(activity)
        if not text:
            continue

        # A reply is not enough — the worker must actually ANSWER. Without this,
        # the runtime's generic failure card ("Something went wrong with this
        # service…") counts as a pass, and so does a reply from some other pack
        # entirely if state leaks between runs. Both happen.
        low = text.lower()
        for marker in ERROR_MARKERS:
            if marker in low:
                sys.stderr.write(f"dw.agent returned an error reply: {text}\n")
                sys.exit(5)
        # The demo greets with a welcome/suggestions card ("What's new in AI this
        # week?" …) as a non-user activity BEFORE it answers. That card is a
        # legitimate intermediate reply — skip it and keep polling for the real
        # answer. Treating the first non-user reply as THE answer races the
        # greeting card and fails intermittently (the answer arrives seconds
        # later, well within the deadline).
        if EXPECT and EXPECT.lower() not in low:
            last_other = text
            continue
        print(text)
        sys.exit(0)

# Deadline reached. If we saw replies but never the expected answer, that is a
# wrong-answer failure; report the last one. Otherwise nothing came back at all.
if last_other is not None:
    sys.stderr.write(
        f"dw.agent replied but never produced the expected answer — expected to "
        f"see {EXPECT!r}; last non-matching reply was: {last_other}\n"
    )
    sys.exit(6)
sys.stderr.write("timed out waiting for a dw.agent reply\n")
sys.exit(4)
PY
)" || die "dw.agent did not return a usable reply within ${AGENT_TURN_TIMEOUT}s"

log "PASS: dw.agent replied → \"${REPLY}\""
log "Agentic-worker e2e succeeded."
exit 0
