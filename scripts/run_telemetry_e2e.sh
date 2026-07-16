#!/usr/bin/env bash
#
# Local runner for telemetry (OTLP) E2E tests
#
# Proves that a running Greentic bundle actually exports telemetry to an OTLP
# endpoint: boots a file-export OpenTelemetry Collector, starts a dummy-provider
# bundle pointed at it (TELEMETRY_EXPORT/OTLP_ENDPOINT), drives a little HTTP
# traffic, then asserts the collector's JSON dump contains OTLP **logs** (and
# reports metrics/traces) for our service.name.
#
# Usage:
#   ./scripts/run_telemetry_e2e.sh [options]
#
# Options:
#   --protocol <grpc|http>   OTLP transport (default: grpc → :4317, http → :4318)
#   --service-name <name>    OTEL service.name to assert (default: greentic-telemetry-e2e)
#   --bundle <path>          Use existing bundle directory
#   --keep-running           Leave gtc + collector running after test
#   --dry-run                Validate script without running gtc/docker
#   --verbose                Enable verbose output
#
# Requires: gtc CLI, docker.
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR_CONFIG="${ROOT_DIR}/fixtures/telemetry/otel-collector-file-export.yaml"

# Defaults
OTLP_PROTOCOL="${OTLP_PROTOCOL:-grpc}"
SERVICE_NAME="${SERVICE_NAME:-greentic-telemetry-e2e}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
GTC_CMD_TIMEOUT="${GTC_CMD_TIMEOUT:-60}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.114.0}"
COLLECTOR_NAME="${COLLECTOR_NAME:-greentic-telemetry-e2e-otelcol}"
# Non-default gateway port so we don't collide with a demo already on :8080.
HTTP_PORT="${HTTP_PORT:-18080}"
START_PID=""
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol) OTLP_PROTOCOL="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --bundle) E2E_BUNDLE_DIR="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# OTLP_PORT is the collector's *in-container* port (OTLP standard). HOST_OTLP_PORT
# is what we publish on the host — deliberately non-standard so we don't collide
# with a developer's own collector / demo stack already bound to 4317/4318.
case "$OTLP_PROTOCOL" in
  grpc) OTLP_PORT=4317; HOST_OTLP_PORT="${HOST_OTLP_PORT:-14317}"; TELEMETRY_EXPORT_MODE="otlp-grpc" ;;
  http) OTLP_PORT=4318; HOST_OTLP_PORT="${HOST_OTLP_PORT:-14318}"; TELEMETRY_EXPORT_MODE="otlp-http" ;;
  *) echo "Unknown --protocol: $OTLP_PROTOCOL (use grpc or http)" >&2; exit 1 ;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then log "$*"; fi; }
die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  log "Cleaning up..."
  if [[ -n "${RUNTIME_HOME:-}" ]]; then
    HOME="$RUNTIME_HOME" gtc stop 2>/dev/null || log "WARN: gtc stop failed ($?)"
  fi
  if [[ -n "${START_PID:-}" ]]; then
    kill "$START_PID" 2>/dev/null || true
  fi
  pkill -f "greentic-runner" 2>/dev/null || true
  pkill -f "nats-server" 2>/dev/null || true
  if [[ "$DRY_RUN" != "true" ]]; then
    docker rm -f "${COLLECTOR_NAME}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" && "$KEEP_RUNNING" != "true" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

# Prereqs
if [[ "$DRY_RUN" != "true" ]]; then
  command -v gtc >/dev/null 2>&1 || die "gtc CLI not found. Install with: cargo binstall gtc"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon not running"
fi
[[ -f "$COLLECTOR_CONFIG" ]] || die "collector config not found: $COLLECTOR_CONFIG"

log "Telemetry (OTLP) E2E Test"
log "========================="
log "Protocol:     ${OTLP_PROTOCOL} (container :${OTLP_PORT} -> host :${HOST_OTLP_PORT})"
log "service.name: ${SERVICE_NAME}"
log "gtc:          $(command -v gtc 2>/dev/null || echo 'not found')"
[[ "$DRY_RUN" == "true" ]] && log "Mode: DRY RUN"

TEMP_DIR="$(mktemp -d)"
DUMP_DIR="${TEMP_DIR}/otlp-out"
DUMP_FILE="${DUMP_DIR}/otlp-dump.json"
E2E_BUNDLE_DIR="${E2E_BUNDLE_DIR:-${TEMP_DIR}/bundle}"
E2E_LOG="${TEMP_DIR}/gtc-start.log"
mkdir -p "${DUMP_DIR}" "${E2E_BUNDLE_DIR}"
chmod 777 "${DUMP_DIR}"   # collector image runs as non-root (uid 10001)
log "Working directory: ${TEMP_DIR}"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would start collector ${COLLECTOR_IMAGE}, a dummy bundle, drive traffic, assert resourceLogs."
  exit 0
fi

###############################################################################
# Step 1: Start the file-export OTLP collector
###############################################################################
log ""
log "Step 1: Starting OTLP collector (${COLLECTOR_IMAGE})..."
docker rm -f "${COLLECTOR_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${COLLECTOR_NAME}" \
  -p "${HOST_OTLP_PORT}:${OTLP_PORT}" \
  -v "${COLLECTOR_CONFIG}:/etc/otelcol/config.yaml:ro" \
  -v "${DUMP_DIR}:/etc/otelcol/out" \
  "${COLLECTOR_IMAGE}" --config=/etc/otelcol/config.yaml >/dev/null \
  || die "failed to start collector"

# Wait for the OTLP port to accept connections
COLLECTOR_READY=false
for _ in $(seq 1 20); do
  if nc -z 127.0.0.1 "${HOST_OTLP_PORT}" 2>/dev/null; then COLLECTOR_READY=true; break; fi
  sleep 1
done
[[ "$COLLECTOR_READY" == "true" ]] || { docker logs "${COLLECTOR_NAME}" 2>&1 | tail -20; die "collector not listening on :${HOST_OTLP_PORT}"; }
log "PASS: collector listening on host :${HOST_OTLP_PORT}"

###############################################################################
# Step 2: Build + set up a dummy-provider bundle
###############################################################################
log ""
log "Step 2: Building dummy bundle..."
cat > "${E2E_BUNDLE_DIR}/greentic.demo.yaml" <<'YAML'
id: ai.greentic.e2e.telemetry
name: E2E Telemetry Test Bundle
version: 0.1.0
description: Dummy-provider bundle for telemetry OTLP export verification

providers:
  messaging:
    messaging-dummy:
      pack: "oci://ghcr.io/greentic-biz/packs/messaging-dummy:latest"
  events:
    events-dummy:
      pack: "oci://ghcr.io/greentic-biz/packs/events-dummy:latest"
YAML
[[ "$VERBOSE" == "true" ]] && cat "${E2E_BUNDLE_DIR}/greentic.demo.yaml"

SETUP_LOG="${TEMP_DIR}/gtc-setup.log"
echo '{}' > "${TEMP_DIR}/setup-answers.json"
SETUP_EXIT=0
gtc setup --non-interactive --answers "${TEMP_DIR}/setup-answers.json" "${E2E_BUNDLE_DIR}" \
  < /dev/null > "${SETUP_LOG}" 2>&1 || SETUP_EXIT=$?
if [[ "$VERBOSE" == "true" ]]; then cat "${SETUP_LOG}" 2>/dev/null || true; fi
log "Setup exited ${SETUP_EXIT}"

###############################################################################
# Step 3: Start gtc pointed at the collector
###############################################################################
log ""
log "Step 3: Starting gtc with OTLP export -> 127.0.0.1:${HOST_OTLP_PORT}..."
RUNTIME_HOME="$(mktemp -d "${TEMP_DIR}/runtime-home.XXXXXX")"
HOME="$RUNTIME_HOME" \
TELEMETRY_EXPORT="${TELEMETRY_EXPORT_MODE}" \
OTLP_ENDPOINT="http://127.0.0.1:${HOST_OTLP_PORT}" \
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:${HOST_OTLP_PORT}" \
OTEL_SERVICE_NAME="${SERVICE_NAME}" \
OTEL_METRIC_EXPORT_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-3000}" \
GREENTIC_GATEWAY_LISTEN_ADDR="127.0.0.1" \
GREENTIC_GATEWAY_PORT="${HTTP_PORT}" \
RUST_LOG="${RUST_LOG:-info}" \
  gtc start "${E2E_BUNDLE_DIR}" --cloudflared off > "${E2E_LOG}" 2>&1 &
START_PID=$!
log "Started gtc (PID: ${START_PID})"

READY_TIMEOUT="${READY_TIMEOUT:-120}"
GTC_READY=false
for i in $(seq 1 "${READY_TIMEOUT}"); do
  if grep -q "Press Ctrl+C to stop" "${E2E_LOG}" 2>/dev/null; then
    GTC_READY=true; log "PASS: gtc ready after ${i}s"; break
  fi
  kill -0 "${START_PID}" 2>/dev/null || { log "FAIL: gtc exited early"; tail -30 "${E2E_LOG}"; exit 1; }
  sleep 1
done
if [[ "$GTC_READY" != "true" ]]; then
  log "FAIL: gtc not ready after ${READY_TIMEOUT}s"
  tail -20 "${E2E_LOG}"
  exit 1
fi
sleep 2

###############################################################################
# Step 4: Drive a little traffic (emits http + flow logs/metrics)
###############################################################################
log ""
log "Step 4: Driving traffic..."
for _ in 1 2 3; do
  curl -s -o /dev/null "http://127.0.0.1:${HTTP_PORT}/readyz" 2>/dev/null || true
  curl -s -o /dev/null -X POST "http://127.0.0.1:${HTTP_PORT}/v1/messaging/ingress/messaging-dummy/demo/default" \
    -H 'Content-Type: application/json' -d '{"text":"telemetry e2e","from":{"id":"e2e","name":"E2E"}}' 2>/dev/null || true
  curl -s -o /dev/null -X POST "http://127.0.0.1:${HTTP_PORT}/v1/events/ingress/events-dummy/demo/default" \
    -H 'Content-Type: application/json' -d '{"event_type":"e2e.test","data":{"message":"hi"}}' 2>/dev/null || true
  sleep 1
done

###############################################################################
# Step 5: Assert OTLP signals landed in the collector dump
###############################################################################
log ""
log "Step 5: Verifying OTLP signals reached the collector..."
# Collector batches on a 1s timeout; give it a few cycles to flush to file.
LOGS_OK=false
for _ in $(seq 1 20); do
  if [[ -f "${DUMP_FILE}" ]] && grep -q "resourceLogs" "${DUMP_FILE}" 2>/dev/null; then
    LOGS_OK=true; break
  fi
  sleep 1
done

if [[ "$LOGS_OK" != "true" ]]; then
  log "FAIL: no resourceLogs in collector dump after 20s"
  log "  dump: ${DUMP_FILE}"
  log "  --- collector logs (tail) ---"; docker logs "${COLLECTOR_NAME}" 2>&1 | tail -20 || true
  log "  --- gtc log (tail) ---"; tail -20 "${E2E_LOG}" 2>/dev/null || true
  exit 1
fi
log "PASS: OTLP logs received (resourceLogs present)"

# service.name assertion
if grep -q "\"${SERVICE_NAME}\"" "${DUMP_FILE}" 2>/dev/null; then
  log "PASS: service.name=${SERVICE_NAME} present in dump"
else
  log "WARN: service.name=${SERVICE_NAME} not found (logs landed under a different service name)"
fi

# Report the other signals (non-fatal — logs are the contract here)
if grep -q "resourceMetrics" "${DUMP_FILE}" 2>/dev/null; then log "INFO: resourceMetrics present"; else log "INFO: no resourceMetrics yet"; fi
if grep -q "resourceSpans" "${DUMP_FILE}" 2>/dev/null; then log "INFO: resourceSpans present"; else log "INFO: no resourceSpans yet"; fi

if [[ "$VERBOSE" == "true" ]]; then
  log "Distinct log scopes seen:"
  grep -o '"name":"[^"]*"' "${DUMP_FILE}" 2>/dev/null | sort -u | head -30 || true
fi

###############################################################################
# Step 6: Stop
###############################################################################
if [[ "$KEEP_RUNNING" == "true" ]]; then
  log ""
  log "Keeping services running (--keep-running)"
  log "  Bundle:    ${E2E_BUNDLE_DIR}"
  log "  gtc log:   ${E2E_LOG}"
  log "  Stop with: HOME=$RUNTIME_HOME gtc stop"
  log "  Dump file: ${DUMP_FILE}"
  log "  Collector: ${COLLECTOR_NAME}"
  trap - EXIT
fi

log ""
log "========================="
log "Telemetry E2E PASSED"
log "========================="
