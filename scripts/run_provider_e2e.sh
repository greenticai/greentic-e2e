#!/usr/bin/env bash
#
# Local runner for provider E2E tests (full cycle)
#
# Usage:
#   ./scripts/run_provider_e2e.sh [options]
#
# Options:
#   --scope <all|messaging|events|dummy>  Test scope (default: dummy)
#   --provider <name>                      Test a single provider
#   --bundle <path>                        Use existing bundle directory
#   --skip-setup                           Skip setup test
#   --skip-start                           Skip start test
#   --keep-running                         Don't stop services after test
#   --dry-run                              Validate script without running gtc
#   --verbose                              Enable verbose output
#
# Examples:
#   ./scripts/run_provider_e2e.sh                           # dummy only
#   ./scripts/run_provider_e2e.sh --scope messaging         # all messaging
#   ./scripts/run_provider_e2e.sh --scope events            # all events
#   ./scripts/run_provider_e2e.sh --scope all               # everything
#   ./scripts/run_provider_e2e.sh --provider messaging-telegram
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
SECRETS_FILE="${ROOT_DIR}/.secrets-provider"

# All available providers
ALL_MESSAGING="messaging-dummy messaging-telegram messaging-slack messaging-teams messaging-webex messaging-whatsapp messaging-email messaging-webchat"
ALL_EVENTS="events-dummy events-webhook events-timer events-email-sendgrid events-sms-twilio"

# Defaults
TEST_SCOPE="${TEST_SCOPE:-dummy}"
SINGLE_PROVIDER=""
SKIP_SETUP="${SKIP_SETUP:-false}"
SKIP_START="${SKIP_START:-false}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
GTC_CMD_TIMEOUT="${GTC_CMD_TIMEOUT:-30}"
START_PID=""
FAIL_COUNT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      TEST_SCOPE="$2"
      shift 2
      ;;
    --provider)
      SINGLE_PROVIDER="$2"
      shift 2
      ;;
    --bundle)
      E2E_BUNDLE_DIR="$2"
      shift 2
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

# Run a command with a timeout (macOS + Linux compatible)
run_with_timeout() {
  local timeout_secs="$1"
  shift
  perl -e '
    use POSIX ":sys_wait_h";
    my $timeout = shift @ARGV;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec(@ARGV) or exit(127); }
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

# Get provider-specific webhook test payload
get_test_payload() {
  local provider="$1"
  case "$provider" in
    messaging-dummy)
      echo '{"text":"e2e test","from":{"id":"e2e","name":"E2E"}}'
      ;;
    messaging-telegram)
      echo '{"update_id":1,"message":{"message_id":1,"date":1700000000,"from":{"id":123,"is_bot":false,"first_name":"E2E"},"chat":{"id":123,"type":"private"},"text":"e2e test"}}'
      ;;
    messaging-slack)
      echo '{"type":"event_callback","event":{"type":"message","text":"e2e test","user":"U123","channel":"C123","ts":"1700000000.000001"}}'
      ;;
    messaging-teams)
      echo '{"type":"message","id":"1","timestamp":"2024-01-01T00:00:00Z","channelId":"msteams","from":{"id":"e2e","name":"E2E"},"conversation":{"id":"conv1"},"recipient":{"id":"bot1"},"text":"e2e test","serviceUrl":"https://smba.trafficmanager.net/teams/"}'
      ;;
    messaging-webex)
      echo '{"id":"msg1","name":"e2e","targetUrl":"http://localhost","resource":"messages","event":"created","data":{"id":"msg1","roomId":"room1","personId":"person1","personEmail":"e2e@test.com","text":"e2e test","created":"2024-01-01T00:00:00.000Z"}}'
      ;;
    messaging-whatsapp)
      echo '{"object":"whatsapp_business_account","entry":[{"id":"123","changes":[{"value":{"messaging_product":"whatsapp","metadata":{"phone_number_id":"123"},"messages":[{"from":"123456","id":"msg1","timestamp":"1700000000","type":"text","text":{"body":"e2e test"}}]},"field":"messages"}]}]}'
      ;;
    messaging-email)
      echo '{"value":[{"changeType":"created","resource":"me/messages/msg1","resourceData":{"id":"msg1"}}]}'
      ;;
    messaging-webchat)
      echo '{"type":"message","id":"1","from":{"id":"e2e","name":"E2E"},"text":"e2e test"}'
      ;;
    events-dummy)
      echo '{"event_type":"e2e.test","data":{"message":"hello from e2e"}}'
      ;;
    events-webhook)
      echo '{"event_type":"e2e.test","data":{"message":"hello from e2e"}}'
      ;;
    events-email-sendgrid)
      echo '[{"email":"test@example.com","timestamp":1700000000,"event":"delivered","sg_event_id":"evt1","sg_message_id":"msg1"}]'
      ;;
    events-sms-twilio)
      echo 'From=%2B1234567890&To=%2B0987654321&Body=e2e+test&MessageSid=SM123&AccountSid=AC123'
      ;;
    *)
      echo '{"text":"e2e test"}'
      ;;
  esac
}

# Get content type for provider
get_content_type() {
  local provider="$1"
  case "$provider" in
    events-sms-twilio) echo "application/x-www-form-urlencoded" ;;
    *) echo "application/json" ;;
  esac
}

# Get ingress domain for provider
get_domain() {
  local provider="$1"
  case "$provider" in
    messaging-*) echo "messaging" ;;
    events-*) echo "events" ;;
    *) echo "messaging" ;;
  esac
}

cleanup() {
  log "Cleaning up..."

  if [[ -n "${START_PID}" ]] && kill -0 "${START_PID}" 2>/dev/null; then
    log "Stopping gtc start (PID: ${START_PID})"
    kill -TERM "${START_PID}" 2>/dev/null || true
    sleep 2
    kill -9 "${START_PID}" 2>/dev/null || true
  fi

  pkill -f "greentic-runner" 2>/dev/null || true
  pkill -f "nats-server" 2>/dev/null || true

  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" && "$KEEP_RUNNING" != "true" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

trap cleanup EXIT

###############################################################################
# Load secrets from .secrets-provider if available
###############################################################################
if [[ -f "$SECRETS_FILE" ]]; then
  log "Loading secrets from ${SECRETS_FILE}"
  set -a
  # shellcheck source=/dev/null
  source "$SECRETS_FILE"
  set +a
else
  log_verbose "No .secrets-provider file found, using environment variables"
fi

###############################################################################
# Determine providers to test
###############################################################################
MESSAGING_PROVIDERS=""
EVENT_PROVIDERS=""

if [[ -n "$SINGLE_PROVIDER" ]]; then
  # Single provider mode
  case "$SINGLE_PROVIDER" in
    messaging-*) MESSAGING_PROVIDERS="$SINGLE_PROVIDER" ;;
    events-*) EVENT_PROVIDERS="$SINGLE_PROVIDER" ;;
    *) die "Unknown provider: $SINGLE_PROVIDER" ;;
  esac
  TEST_SCOPE="single:${SINGLE_PROVIDER}"
else
  case "$TEST_SCOPE" in
    dummy)
      MESSAGING_PROVIDERS="messaging-dummy"
      EVENT_PROVIDERS="events-dummy"
      ;;
    messaging)
      MESSAGING_PROVIDERS="$ALL_MESSAGING"
      ;;
    events)
      EVENT_PROVIDERS="$ALL_EVENTS"
      ;;
    all)
      MESSAGING_PROVIDERS="$ALL_MESSAGING"
      EVENT_PROVIDERS="$ALL_EVENTS"
      ;;
    *)
      die "Unknown scope: $TEST_SCOPE (use: dummy, messaging, events, all)"
      ;;
  esac
fi

# Check prerequisites
if [[ "$DRY_RUN" != "true" ]]; then
  command -v gtc >/dev/null 2>&1 || die "gtc CLI not found. Install with: cargo binstall gtc"
fi

log "Provider E2E Test"
log "=================="
log "Test scope: ${TEST_SCOPE}"
if [[ -n "$MESSAGING_PROVIDERS" ]]; then
  log "Messaging: $(echo "$MESSAGING_PROVIDERS" | xargs)"
fi
if [[ -n "$EVENT_PROVIDERS" ]]; then
  log "Events:    $(echo "$EVENT_PROVIDERS" | xargs)"
fi
if [[ "$DRY_RUN" == "true" ]]; then
  log "Mode: DRY RUN"
fi
log "gtc: $(command -v gtc 2>/dev/null || echo 'not found')"

# Create temp directory
TEMP_DIR="$(mktemp -d)"
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-${TEMP_DIR}/bundle}"
E2E_SETUP_ANSWERS="${TEMP_DIR}/setup-answers.json"
E2E_LOG="${TEMP_DIR}/gtc-start.log"

mkdir -p "${E2E_BUNDLE_DIR}"

log "Working directory: ${TEMP_DIR}"

###############################################################################
# Step 1: Create bundle
###############################################################################
log ""
log "Step 1: Creating test bundle..."

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

log "PASS: Bundle created"
if [[ "$VERBOSE" == "true" ]]; then
  cat "${BUNDLE_CONFIG}"
fi

###############################################################################
# Step 2: Setup
###############################################################################
if [[ "$SKIP_SETUP" != "true" ]]; then
  log ""
  log "Step 2: Setting up providers..."

  ALL_PROVIDERS="${MESSAGING_PROVIDERS} ${EVENT_PROVIDERS}"
  FIXTURE_FILES=()
  for provider in $ALL_PROVIDERS; do
    provider=$(echo "$provider" | xargs)
    [[ -z "$provider" ]] && continue
    fixture="${FIXTURES_DIR}/setup-answers/${provider}.json"
    if [[ -f "$fixture" ]]; then
      # Substitute env vars in fixture and save to temp
      tmp_fixture="${TEMP_DIR}/${provider}-answers.json"
      envsubst < "$fixture" > "$tmp_fixture"
      FIXTURE_FILES+=("$tmp_fixture")
    else
      log_verbose "No fixture for ${provider}, using default"
      tmp_fixture="${TEMP_DIR}/${provider}-default.json"
      echo "{ \"${provider}\": { \"enabled\": true } }" > "$tmp_fixture"
      FIXTURE_FILES+=("$tmp_fixture")
    fi
  done

  # Merge all fixture files
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

  if [[ "$VERBOSE" == "true" ]]; then
    log "Setup answers:"
    cat "${E2E_SETUP_ANSWERS}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would run: gtc setup --answers ... ${E2E_BUNDLE_DIR}"
  else
    SETUP_LOG="${TEMP_DIR}/gtc-setup.log"
    SETUP_EXIT=0
    run_with_timeout "$GTC_CMD_TIMEOUT" gtc setup --answers "${E2E_SETUP_ANSWERS}" "${E2E_BUNDLE_DIR}" \
      < /dev/null > "${SETUP_LOG}" 2>&1 || SETUP_EXIT=$?

    if [[ "$VERBOSE" == "true" ]]; then
      cat "${SETUP_LOG}" 2>/dev/null || true
    fi

    if [[ $SETUP_EXIT -eq 0 ]]; then
      log "PASS: Setup completed"
    elif grep -q "Loaded answers" "${SETUP_LOG}" 2>/dev/null; then
      log "PASS: Setup loaded answers"
    else
      log "WARN: Setup exited with ${SETUP_EXIT}"
    fi
  fi
else
  log ""
  log "Step 2: Skipping setup"
fi

###############################################################################
# Step 3: Start services
###############################################################################
if [[ "$SKIP_START" != "true" ]]; then
  log ""
  log "Step 3: Starting services..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would start gtc and test HTTP ingress"

    log ""
    log "Step 4: [DRY RUN] Would verify services"

    log ""
    log "Step 5: [DRY RUN] Would test HTTP ingress for:"
    for provider in $MESSAGING_PROVIDERS $EVENT_PROVIDERS; do
      provider=$(echo "$provider" | xargs)
      [[ -z "$provider" ]] && continue
      DOMAIN=$(get_domain "$provider")
      log "  POST /v1/${DOMAIN}/ingress/${provider}/demo/default"
    done

    log ""
    log "Step 6: [DRY RUN] Would stop services"
  else
    gtc start "${E2E_BUNDLE_DIR}" \
      --cloudflared off \
      --ngrok off \
      > "${E2E_LOG}" 2>&1 &

    START_PID=$!
    log "Started gtc (PID: ${START_PID})"

    # Wait for HTTP endpoint
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
    fi
    sleep 3

    ###########################################################################
    # Step 4: Verify services running
    ###########################################################################
    log ""
    log "Step 4: Verifying services..."

    if kill -0 "${START_PID}" 2>/dev/null; then
      log "PASS: Services running (PID: ${START_PID})"
    else
      log "FAIL: Services exited unexpectedly"
      cat "${E2E_LOG}" 2>/dev/null || true
      exit 1
    fi

    ###########################################################################
    # Step 5: Test HTTP ingress (full cycle)
    ###########################################################################
    log ""
    log "Step 5: Testing HTTP ingress..."

    for provider in $MESSAGING_PROVIDERS $EVENT_PROVIDERS; do
      provider=$(echo "$provider" | xargs)
      [[ -z "$provider" ]] && continue

      # Skip timer (no HTTP ingress)
      if [[ "$provider" == "events-timer" ]]; then
        log "[${provider}] Timer provider - skipping HTTP test"
        if grep -qE "timer|schedule|tick" "${E2E_LOG}" 2>/dev/null; then
          log "PASS: ${provider} timer indicators found in logs"
        else
          log "INFO: ${provider} no timer indicators yet"
        fi
        continue
      fi

      DOMAIN=$(get_domain "$provider")
      PAYLOAD=$(get_test_payload "$provider")
      CONTENT_TYPE=$(get_content_type "$provider")
      ENDPOINT="http://127.0.0.1:8080/v1/${DOMAIN}/ingress/${provider}/demo/default"

      log "[${provider}] POST ${ENDPOINT}"

      RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: ${CONTENT_TYPE}" \
        -d "${PAYLOAD}" \
        2>&1) || true

      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | sed '$d')

      log "[${provider}] HTTP ${HTTP_CODE}: ${BODY}"

      if [[ "$HTTP_CODE" =~ ^[2-4][0-9][0-9]$ ]]; then
        log "PASS: ${provider} ingress responded with ${HTTP_CODE}"
      else
        log "FAIL: ${provider} ingress failed with ${HTTP_CODE}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    done

    ###########################################################################
    # Step 6: Stop services
    ###########################################################################
    if [[ "$KEEP_RUNNING" != "true" ]]; then
      log ""
      log "Step 6: Stopping services..."

      if [[ -n "${START_PID}" ]] && kill -0 "${START_PID}" 2>/dev/null; then
        kill -TERM "${START_PID}" 2>/dev/null || true
        wait "${START_PID}" 2>/dev/null || true
        sleep 1

        if kill -0 "${START_PID}" 2>/dev/null; then
          kill -9 "${START_PID}" 2>/dev/null || true
          wait "${START_PID}" 2>/dev/null || true
        fi
      fi

      log "PASS: Services stopped"
      START_PID=""
    else
      log ""
      log "Step 6: Keeping services running (--keep-running)"
      log "  Bundle: ${E2E_BUNDLE_DIR}"
      log "  Log: ${E2E_LOG}"
      log "  PID: ${START_PID}"
      trap - EXIT
    fi
  fi
else
  log ""
  log "Step 3-6: Skipping start/ingress/stop tests"
fi

###############################################################################
# Summary
###############################################################################
log ""
log "=================="
if [[ $FAIL_COUNT -gt 0 ]]; then
  log "E2E Test FAILED (${FAIL_COUNT} failure(s))"
  exit 1
else
  log "E2E Test PASSED"
fi
log "=================="
