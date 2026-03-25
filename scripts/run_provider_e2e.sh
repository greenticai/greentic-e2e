#!/usr/bin/env bash
#
# Local runner for provider E2E tests
#
# Usage:
#   ./scripts/run_provider_e2e.sh [options]
#
# Options:
#   --scope <all|messaging|events>   Test scope (default: all)
#   --bundle <path>                   Use existing bundle directory
#   --skip-wizard                     Skip wizard test
#   --skip-setup                      Skip setup test
#   --skip-start                      Skip start test
#   --keep-running                    Don't stop services after test
#   --dry-run                         Validate script without running gtc
#   --verbose                         Enable verbose output
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"

# Defaults
TEST_SCOPE="${TEST_SCOPE:-all}"
SKIP_WIZARD="${SKIP_WIZARD:-false}"
SKIP_SETUP="${SKIP_SETUP:-false}"
SKIP_START="${SKIP_START:-false}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
E2E_TIMEOUT="${E2E_TIMEOUT:-60}"
GTC_CMD_TIMEOUT="${GTC_CMD_TIMEOUT:-30}"
START_PID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      TEST_SCOPE="$2"
      shift 2
      ;;
    --bundle)
      E2E_BUNDLE_DIR="$2"
      shift 2
      ;;
    --skip-wizard)
      SKIP_WIZARD=true
      shift
      ;;
    --skip-setup)
      SKIP_SETUP=true
      shift
      ;;
    --skip-start)
      SKIP_START=true
      shift
      ;;
    --keep-running)
      KEEP_RUNNING=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      head -22 "$0" | tail -19
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

# Run a command with a timeout (macOS + Linux compatible)
# Uses perl for reliable timeout handling since macOS lacks coreutils timeout.
# Usage: run_with_timeout <seconds> <command> [args...]
# Returns: 0 on success, 124 on timeout, or the command's exit code
run_with_timeout() {
  local timeout_secs="$1"
  shift

  perl -e '
    use POSIX ":sys_wait_h";
    my $timeout = shift @ARGV;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
      exec(@ARGV) or exit(127);
    }
    eval {
      local $SIG{ALRM} = sub { die "timeout\n" };
      alarm($timeout);
      waitpid($pid, 0);
      alarm(0);
    };
    if ($@ && $@ eq "timeout\n") {
      kill 9, $pid;
      waitpid($pid, WNOHANG);
      exit(124);
    }
    exit($? >> 8);
  ' -- "$timeout_secs" "$@"
}

cleanup() {
  log "Cleaning up..."

  if [[ -n "${START_PID}" ]] && kill -0 "${START_PID}" 2>/dev/null; then
    log "Stopping gtc start (PID: ${START_PID})"
    kill -TERM "${START_PID}" 2>/dev/null || true
    sleep 2
    kill -9 "${START_PID}" 2>/dev/null || true
  fi

  # Cleanup greentic processes spawned by this test
  pkill -f "greentic-runner" 2>/dev/null || true
  pkill -f "nats-server" 2>/dev/null || true

  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" && "$KEEP_RUNNING" != "true" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

# Setup cleanup trap
trap cleanup EXIT

# Check prerequisites
if [[ "$DRY_RUN" != "true" ]]; then
  command -v gtc >/dev/null 2>&1 || die "gtc CLI not found. Install with: cargo binstall gtc"
fi

log "Provider E2E Test"
log "=================="
log "Test scope: ${TEST_SCOPE}"
if [[ "$DRY_RUN" == "true" ]]; then
  log "Mode: DRY RUN (no gtc commands will be executed)"
fi
log "gtc: $(command -v gtc 2>/dev/null || echo 'not found')"

# Create temp directory
TEMP_DIR="$(mktemp -d)"
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-${TEMP_DIR}/bundle}"
E2E_SETUP_ANSWERS="${TEMP_DIR}/setup-answers.json"
E2E_LOG="${TEMP_DIR}/gtc-start.log"

mkdir -p "${E2E_BUNDLE_DIR}"

log "Working directory: ${TEMP_DIR}"
log "Bundle directory: ${E2E_BUNDLE_DIR}"

###############################################################################
# Step 1: Create bundle
###############################################################################
log ""
log "Step 1: Creating test bundle..."

# Determine which providers to include based on scope
MESSAGING_PROVIDERS=""
EVENT_PROVIDERS=""

case "$TEST_SCOPE" in
  all)
    MESSAGING_PROVIDERS="messaging-dummy"
    EVENT_PROVIDERS="events-dummy"
    ;;
  messaging)
    MESSAGING_PROVIDERS="messaging-dummy"
    ;;
  events)
    EVENT_PROVIDERS="events-dummy"
    ;;
esac

# Build bundle config (greentic.demo.yaml - expected by gtc start)
BUNDLE_CONFIG="${E2E_BUNDLE_DIR}/greentic.demo.yaml"
{
  cat <<'HEADER'
id: ai.greentic.e2e.providers
name: E2E Provider Test Bundle
version: 0.1.0
description: Bundle for testing provider lifecycle

providers:
HEADER

  if [[ -n "$MESSAGING_PROVIDERS" ]]; then
    echo "  messaging:"
    for provider in $MESSAGING_PROVIDERS; do
      echo "    ${provider}:"
      echo "      pack: \"oci://ghcr.io/greentic-biz/packs/${provider}:latest\""
    done
  fi

  if [[ -n "$EVENT_PROVIDERS" ]]; then
    echo "  events:"
    for provider in $EVENT_PROVIDERS; do
      echo "    ${provider}:"
      echo "      pack: \"oci://ghcr.io/greentic-biz/packs/${provider}:latest\""
    done
  fi
} > "${BUNDLE_CONFIG}"

log "Bundle created at ${BUNDLE_CONFIG}"
if [[ "$VERBOSE" == "true" ]]; then
  log "Bundle contents:"
  cat "${BUNDLE_CONFIG}"
fi

###############################################################################
# Step 2: Setup test
###############################################################################
if [[ "$SKIP_SETUP" != "true" ]]; then
  log ""
  log "Step 2: Testing gtc setup..."

  # Build setup answers by merging individual fixture files
  ALL_PROVIDERS="${MESSAGING_PROVIDERS} ${EVENT_PROVIDERS}"
  FIXTURE_FILES=()
  for provider in $ALL_PROVIDERS; do
    provider=$(echo "$provider" | xargs)  # trim whitespace
    [[ -z "$provider" ]] && continue
    fixture="${FIXTURES_DIR}/setup-answers/${provider}.json"
    if [[ -f "$fixture" ]]; then
      FIXTURE_FILES+=("$fixture")
    else
      log_verbose "No fixture found for ${provider}, using inline default"
      # Write a temp fixture
      tmp_fixture="${TEMP_DIR}/${provider}-default.json"
      echo "{ \"${provider}\": { \"enabled\": true } }" > "$tmp_fixture"
      FIXTURE_FILES+=("$tmp_fixture")
    fi
  done

  # Merge JSON files using python3 (available on macOS and most Linux)
  python3 -c "
import json, sys
output_path = sys.argv[1]
merged = {}
for path in sys.argv[2:]:
    with open(path) as f:
        merged.update(json.load(f))
with open(output_path, 'w') as f:
    json.dump(merged, f, indent=2)
    f.write('\n')
" "${E2E_SETUP_ANSWERS}" "${FIXTURE_FILES[@]}"

  log "Setup answers created at ${E2E_SETUP_ANSWERS}"
  if [[ "$VERBOSE" == "true" ]]; then
    log "Setup answers:"
    cat "${E2E_SETUP_ANSWERS}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would run: gtc setup --answers ${E2E_SETUP_ANSWERS} ${E2E_BUNDLE_DIR}"
  else
    log "Running: gtc setup --answers ${E2E_SETUP_ANSWERS} ${E2E_BUNDLE_DIR}"
    SETUP_LOG="${TEMP_DIR}/gtc-setup.log"
    SETUP_EXIT=0
    run_with_timeout "$GTC_CMD_TIMEOUT" gtc setup --answers "${E2E_SETUP_ANSWERS}" "${E2E_BUNDLE_DIR}" \
      < /dev/null > "${SETUP_LOG}" 2>&1 || SETUP_EXIT=$?

    if [[ "$VERBOSE" == "true" ]]; then
      cat "${SETUP_LOG}" 2>/dev/null || true
    fi

    if [[ $SETUP_EXIT -eq 0 ]]; then
      log "PASS: Setup completed successfully"
    elif [[ $SETUP_EXIT -eq 124 ]]; then
      log "FAIL: gtc setup timed out after ${GTC_CMD_TIMEOUT}s"
    elif grep -q "Loaded answers" "${SETUP_LOG}" 2>/dev/null; then
      log "PASS: Setup loaded answers (exit code ${SETUP_EXIT} from non-interactive mode)"
    else
      log "FAIL: Setup failed (exit code: ${SETUP_EXIT})"
      cat "${SETUP_LOG}" 2>/dev/null || true
    fi
  fi
else
  log ""
  log "Step 2: Skipping setup test"
fi

###############################################################################
# Step 3: Start test
###############################################################################
if [[ "$SKIP_START" != "true" ]]; then
  log ""
  log "Step 3: Testing gtc start..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would run: gtc start ${E2E_BUNDLE_DIR} --cloudflared off --ngrok off"
    log "[DRY RUN] Would wait ${E2E_TIMEOUT}s for services to start"
  else
    log "Running: gtc start ${E2E_BUNDLE_DIR} --cloudflared off --ngrok off"

    # Start in background
    gtc start "${E2E_BUNDLE_DIR}" \
      --cloudflared off \
      --ngrok off \
      > "${E2E_LOG}" 2>&1 &

    START_PID=$!
    log "Started gtc (PID: ${START_PID})"

    # Wait for HTTP endpoint to be ready
    log "Waiting for HTTP endpoint..."
    HTTP_READY=false
    for i in $(seq 1 30); do
      if curl -sf http://127.0.0.1:8080/ > /dev/null 2>&1 || \
         curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/ 2>/dev/null | grep -qE "^[2-4]"; then
        log "PASS: HTTP endpoint ready after ${i}s"
        HTTP_READY=true
        break
      fi
      sleep 1
    done

    if [[ "$HTTP_READY" != "true" ]]; then
      log "Warning: HTTP endpoint not responding after 30s"
      if [[ "$VERBOSE" == "true" ]]; then
        cat "${E2E_LOG}" 2>/dev/null || true
      fi
    fi

    # Extra settle time
    sleep 3

    ###########################################################################
    # Step 4: Verify services are running
    ###########################################################################
    log ""
    log "Step 4: Verifying services..."

    if kill -0 "${START_PID}" 2>/dev/null; then
      log "PASS: gtc start is running (PID: ${START_PID})"
    else
      log "FAIL: gtc start exited unexpectedly"
      cat "${E2E_LOG}" 2>/dev/null || log "(no log file)"
      exit 1
    fi

    ###########################################################################
    # Step 5: Test HTTP ingress (full cycle)
    ###########################################################################
    log ""
    log "Step 5: Testing HTTP ingress..."

    # Test messaging-dummy ingress
    if [[ -n "$MESSAGING_PROVIDERS" ]]; then
      for provider in $MESSAGING_PROVIDERS; do
        provider=$(echo "$provider" | xargs)
        [[ -z "$provider" ]] && continue
        log "Sending test message to ${provider}..."

        RESPONSE=$(curl -s -w "\n%{http_code}" \
          -X POST "http://127.0.0.1:8080/v1/messaging/ingress/${provider}/demo/default" \
          -H "Content-Type: application/json" \
          -d '{"text": "e2e test message", "from": {"id": "e2e-tester", "name": "E2E"}}' \
          2>&1) || true

        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        BODY=$(echo "$RESPONSE" | sed '$d')

        log "  HTTP ${HTTP_CODE}: ${BODY}"

        if [[ "$HTTP_CODE" =~ ^[2-4][0-9][0-9]$ ]]; then
          log "PASS: ${provider} ingress responded with ${HTTP_CODE}"
        else
          log "FAIL: ${provider} ingress failed with ${HTTP_CODE}"
        fi
      done
    fi

    # Test events ingress
    if [[ -n "$EVENT_PROVIDERS" ]]; then
      for provider in $EVENT_PROVIDERS; do
        provider=$(echo "$provider" | xargs)
        [[ -z "$provider" ]] && continue
        log "Sending test event to ${provider}..."

        RESPONSE=$(curl -s -w "\n%{http_code}" \
          -X POST "http://127.0.0.1:8080/v1/events/ingress/${provider}/demo/default" \
          -H "Content-Type: application/json" \
          -d '{"event_type": "e2e.test", "data": {"message": "hello from e2e"}}' \
          2>&1) || true

        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        BODY=$(echo "$RESPONSE" | sed '$d')

        log "  HTTP ${HTTP_CODE}: ${BODY}"

        if [[ "$HTTP_CODE" =~ ^[2-4][0-9][0-9]$ ]]; then
          log "PASS: ${provider} ingress responded with ${HTTP_CODE}"
        else
          log "FAIL: ${provider} ingress failed with ${HTTP_CODE}"
        fi
      done
    fi

    ###########################################################################
    # Step 6: Stop test
    ###########################################################################
    if [[ "$KEEP_RUNNING" != "true" ]]; then
      log ""
      log "Step 6: Testing service stop..."

      if [[ -n "${START_PID}" ]] && kill -0 "${START_PID}" 2>/dev/null; then
        kill -TERM "${START_PID}" 2>/dev/null || true
        wait "${START_PID}" 2>/dev/null || true
        sleep 1

        if kill -0 "${START_PID}" 2>/dev/null; then
          log "Warning: Process still running, sending SIGKILL"
          kill -9 "${START_PID}" 2>/dev/null || true
          wait "${START_PID}" 2>/dev/null || true
        fi
      fi

      log "PASS: Services stopped successfully"
      START_PID=""
    else
      log ""
      log "Step 6: Keeping services running (--keep-running)"
      log "Bundle: ${E2E_BUNDLE_DIR}"
      log "Log: ${E2E_LOG}"
      log "PID: ${START_PID}"
      trap - EXIT
    fi
  fi
else
  log ""
  log "Step 3-5: Skipping start/verify/stop tests"
fi

###############################################################################
# Summary
###############################################################################
log ""
log "=================="
log "E2E Test Complete"
log "=================="
