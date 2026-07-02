#!/usr/bin/env bash
# End-to-end regression guard for `gtdx new --kind mcp --from-openapi <spec>`.
#
# This is the OpenAPI -> MCP router scaffolding path: gtdx shells out to
# `greentic-mcp-gen` (found via GTDX_MCP_GEN_BIN) to generate a
# `wasix:mcp/router` wasm component from an OpenAPI spec, then auto-authors a
# publish-ready `describe.json` by patching in the network origins (from the
# spec's `servers:`) and secret requirements (from the spec's security scheme)
# that the generator emits in its `component-meta.json` sidecar.
#
# The test asserts the produced extension is well-formed AND that gtdx ran the
# generator hermetically — i.e. it did NOT move the original spec away and did
# NOT litter the working directory with the generator's bookkeeping dirs
# (input/done/error/uploaded), which the raw generator creates by default.
#
# Why this exists: the OpenAPI seeding path stitches together two private repos
# (greentic-designer-sdk's gtdx + greentic-mcp-generator) and a WASM build.
# Unit tests in each repo cover their own half, but only an e2e that runs the
# real binaries end-to-end catches contract drift between them (e.g. the
# component-meta.json shape, the hermetic-execution guard, or the describe.json
# enrichment) and shape regressions in the generated artifact.
#
# Usage:
#   ./scripts/run_mcp_openapi_gen_e2e.sh
#
# Binary resolution (source-build friendly):
#   GTDX_BIN          absolute path to a locally-built `gtdx` (else `gtdx` on PATH)
#   GTDX_MCP_GEN_BIN  absolute path to a locally-built `greentic-mcp-gen`
#                     (else `greentic-mcp-gen` on PATH). Exported so gtdx finds it.
#   The released binaries are private and may lag the source, so CI and local
#   runs point these at source-built binaries.
#
# Options (env):
#   GREENTIC_MCP_GEN_DRY_RUN  if "true", skips the heavy cargo WASM build; the
#                             generator still emits a placeholder wasm plus a
#                             real describe.json + component-meta.json sidecar,
#                             so assertions (b)-(d) still run. Default: real build.
#   KEEP_WORKDIR              if set, don't wipe the mktemp workdir on exit.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
SPEC_FIXTURE="${FIXTURES_DIR}/openapi/weatherapi.yaml"

# --- resolve binaries (source-build override wins, else PATH) ----------------
GTDX_BIN="${GTDX_BIN:-gtdx}"
GTDX_MCP_GEN_BIN="${GTDX_MCP_GEN_BIN:-greentic-mcp-gen}"
# gtdx discovers the generator through this env var; export it unconditionally.
export GTDX_MCP_GEN_BIN

WORK="$(mktemp -d -t greentic-mcp-openapi-XXXXXX)"

cleanup() {
  if [ -z "${KEEP_WORKDIR:-}" ]; then
    rm -rf "${WORK}"
  else
    echo "[kept] work dir: ${WORK}"
  fi
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 not found on PATH" >&2; exit 1; }; }
need jq

# Resolve gtdx: if GTDX_BIN is an absolute/relative path, require it to exist;
# otherwise require it on PATH.
if [[ "${GTDX_BIN}" == */* ]]; then
  [ -x "${GTDX_BIN}" ] || { echo "FAIL: GTDX_BIN not executable: ${GTDX_BIN}" >&2; exit 1; }
else
  command -v "${GTDX_BIN}" >/dev/null 2>&1 || { echo "FAIL: gtdx not found on PATH (set GTDX_BIN)" >&2; exit 1; }
fi

# Resolve greentic-mcp-gen the same way.
if [[ "${GTDX_MCP_GEN_BIN}" == */* ]]; then
  [ -x "${GTDX_MCP_GEN_BIN}" ] || { echo "FAIL: GTDX_MCP_GEN_BIN not executable: ${GTDX_MCP_GEN_BIN}" >&2; exit 1; }
else
  command -v "${GTDX_MCP_GEN_BIN}" >/dev/null 2>&1 || { echo "FAIL: greentic-mcp-gen not found on PATH (set GTDX_MCP_GEN_BIN)" >&2; exit 1; }
fi

[ -f "${SPEC_FIXTURE}" ] || { echo "FAIL: OpenAPI fixture missing: ${SPEC_FIXTURE}" >&2; exit 1; }

echo "[info] gtdx            = ${GTDX_BIN}"
echo "[info] greentic-mcp-gen = ${GTDX_MCP_GEN_BIN}"
echo "[info] spec fixture     = ${SPEC_FIXTURE}"
echo "[info] dry-run          = ${GREENTIC_MCP_GEN_DRY_RUN:-false}"
echo "[info] workdir          = ${WORK}"

# Record the original spec's checksum so we can prove gtdx didn't touch it.
SPEC_SHA_BEFORE="$(sha256sum "${SPEC_FIXTURE}" | awk '{print $1}')"

DEMO_DIR="${WORK}/demo"

# --- run gtdx new --kind mcp --from-openapi ----------------------------------
echo "[gen] scaffolding mcp extension from OpenAPI spec"
(
  cd "${WORK}"
  "${GTDX_BIN}" new --kind mcp --from-openapi "${SPEC_FIXTURE}" demo \
    --dir "${DEMO_DIR}" -y --no-git
)

# --- assertions --------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; exit 1; }

# (a) a non-empty *.component.wasm was produced in the demo dir
WASM="$(ls "${DEMO_DIR}"/*.component.wasm 2>/dev/null | head -n1 || true)"
[ -n "${WASM}" ] || fail "no *.component.wasm produced in ${DEMO_DIR}"
[ -s "${WASM}" ] || fail "produced wasm is empty: ${WASM}"
echo "PASS: wasm produced — $(basename "${WASM}") ($(wc -c < "${WASM}") bytes)"

# (b) describe.json exists and is a well-formed publish-ready mcp router
DESCRIBE="${DEMO_DIR}/describe.json"
[ -f "${DESCRIBE}" ] || fail "describe.json missing at ${DESCRIBE}"
jq -e '.' "${DESCRIBE}" >/dev/null 2>&1 || fail "describe.json is not valid JSON"

jq -e '.kind == "wasix:mcp/router"' "${DESCRIBE}" >/dev/null 2>&1 \
  || fail "describe.json .kind is not \"wasix:mcp/router\" (got: $(jq -c '.kind' "${DESCRIBE}"))"
echo "PASS: describe.json .kind == wasix:mcp/router"

jq -e '.runtime.permissions.network | length > 0' "${DESCRIBE}" >/dev/null 2>&1 \
  || fail "runtime.permissions.network is empty (expected the spec's servers: origin)"
echo "PASS: runtime.permissions.network populated — $(jq -c '.runtime.permissions.network' "${DESCRIBE}")"

jq -e '.secret_requirements | length > 0' "${DESCRIBE}" >/dev/null 2>&1 \
  || fail "secret_requirements is empty (expected the apiKey security scheme to seed it)"
echo "PASS: secret_requirements populated — $(jq -c '[.secret_requirements[].key]' "${DESCRIBE}")"

# (c) the ORIGINAL fixture spec must still exist, unmodified (gtdx must not move it)
[ -f "${SPEC_FIXTURE}" ] || fail "original spec was moved/deleted by gtdx: ${SPEC_FIXTURE}"
SPEC_SHA_AFTER="$(sha256sum "${SPEC_FIXTURE}" | awk '{print $1}')"
[ "${SPEC_SHA_BEFORE}" = "${SPEC_SHA_AFTER}" ] \
  || fail "original spec content changed (before=${SPEC_SHA_BEFORE} after=${SPEC_SHA_AFTER})"
echo "PASS: original spec preserved (unmoved, unmodified)"

# (d) no generator bookkeeping junk dirs leaked into the workdir (hermetic run).
#     The raw generator defaults to ./input ./done ./error ./uploaded ./output.
for junk in input done error uploaded output; do
  if [ -e "${WORK}/${junk}" ]; then
    fail "generator bookkeeping dir leaked into workdir: ${WORK}/${junk} (gtdx ran non-hermetically)"
  fi
done
echo "PASS: no generator bookkeeping dirs leaked (hermetic run)"

echo "PASS: mcp-openapi-gen e2e"
