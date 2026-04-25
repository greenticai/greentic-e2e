#!/usr/bin/env bash
# Regression test for greentic-pack fix `fix/builtin-node-resolve-skip`
# (commit 5fe4715, version 0.5.3+).
#
# Pins: builtin runtime nodes (emit.*, session.wait, flow.call, provider.invoke)
# must be exempt from resolve.json / resolve.summary.json sidecar requirements.
#
# Positive case: a pack whose only node is `emit.response` must build cleanly
# (exit 0, no "missing resolve summary entries" error).
#
# Negative case: a pack with a real non-builtin component id and no resolve
# entry must still error with "missing resolve summary entries".
#
# Usage:
#   ./scripts/regression/2026_04_25_emit_response_build.sh
#
# Environment:
#   GREENTIC_PACK_BIN  Path to the greentic-pack binary to test.
#                      Defaults to `greentic-pack` on PATH.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures/packs"
POSITIVE_FIXTURE="${FIXTURES_DIR}/builtin-only-flow"
NEGATIVE_FIXTURE="${FIXTURES_DIR}/builtin-only-flow-negative"

GREENTIC_PACK_BIN="${GREENTIC_PACK_BIN:-greentic-pack}"

WORK_DIR="$(mktemp -d -t greentic-regression-emit-XXXXXX)"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# --- preflight --------------------------------------------------------------
if ! command -v "${GREENTIC_PACK_BIN}" >/dev/null 2>&1; then
  echo "FAIL: greentic-pack binary not found at '${GREENTIC_PACK_BIN}'" >&2
  echo "      install with 'cargo binstall greentic-pack' or set GREENTIC_PACK_BIN" >&2
  exit 1
fi

PACK_VERSION="$("${GREENTIC_PACK_BIN}" --version 2>&1 || true)"
echo "[info] using ${GREENTIC_PACK_BIN} (${PACK_VERSION})"

if [ ! -f "${POSITIVE_FIXTURE}/pack.yaml" ]; then
  echo "FAIL: positive fixture missing at ${POSITIVE_FIXTURE}" >&2
  exit 1
fi
if [ ! -f "${NEGATIVE_FIXTURE}/pack.yaml" ]; then
  echo "FAIL: negative fixture missing at ${NEGATIVE_FIXTURE}" >&2
  exit 1
fi

# --- positive test ----------------------------------------------------------
# A pack whose only node is `emit.response` must build cleanly.
echo "[positive] building emit.response-only pack"
POS_DIR="${WORK_DIR}/positive"
cp -r "${POSITIVE_FIXTURE}" "${POS_DIR}"

POS_LOG="${WORK_DIR}/positive.log"
set +e
"${GREENTIC_PACK_BIN}" build --in "${POS_DIR}" >"${POS_LOG}" 2>&1
POS_EXIT=$?
set -e

if [ "${POS_EXIT}" -ne 0 ]; then
  echo "FAIL: positive test — emit.response-only build exited ${POS_EXIT}" >&2
  echo "      regression in greentic-pack fix/builtin-node-resolve-skip" >&2
  echo "---log---" >&2
  cat "${POS_LOG}" >&2
  exit 1
fi

if grep -q "missing resolve summary entries" "${POS_LOG}"; then
  echo "FAIL: positive test — exit 0 but stderr contained 'missing resolve summary entries'" >&2
  echo "      builtin-node-resolve-skip filter regressed" >&2
  echo "---log---" >&2
  cat "${POS_LOG}" >&2
  exit 1
fi

if [ ! -f "${POS_DIR}/dist/positive.gtpack" ]; then
  echo "FAIL: positive test — expected dist/positive.gtpack not produced" >&2
  ls -la "${POS_DIR}/dist" 2>&1 >&2 || true
  exit 1
fi

echo "[positive] PASS — emit.response-only pack builds without resolve sidecar"

# --- negative test ----------------------------------------------------------
# A real component without a resolve entry must STILL error. This pins that
# the builtin exemption only applies to runtime builtins, not arbitrary
# component ids.
echo "[negative] building real-component pack without resolve entry"
NEG_DIR="${WORK_DIR}/negative"
cp -r "${NEGATIVE_FIXTURE}" "${NEG_DIR}"

NEG_LOG="${WORK_DIR}/negative.log"
set +e
"${GREENTIC_PACK_BIN}" build --in "${NEG_DIR}" >"${NEG_LOG}" 2>&1
NEG_EXIT=$?
set -e

if [ "${NEG_EXIT}" -eq 0 ]; then
  echo "FAIL: negative test — build unexpectedly succeeded" >&2
  echo "      builtin exemption is over-broad and now skips real components" >&2
  echo "---log---" >&2
  cat "${NEG_LOG}" >&2
  exit 1
fi

if ! grep -q "missing resolve summary entries" "${NEG_LOG}"; then
  echo "FAIL: negative test — build failed but not with the expected error" >&2
  echo "      expected 'missing resolve summary entries' substring" >&2
  echo "---log---" >&2
  cat "${NEG_LOG}" >&2
  exit 1
fi

echo "[negative] PASS — real-component pack still errors as expected"
echo "PASS: emit.response build regression — ${PACK_VERSION}"
