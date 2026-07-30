#!/usr/bin/env bash
# End-to-end regression guard for greentic-setup #232 (env-deploy must stamp
# route_binding.tenant_selector onto the bundle under the *setup tenant*).
#
# The bug: pre-#232 the synthesized env-manifest carried NO `route_binding`
# key at all. The deployer then defaulted the bundle's tenant to `default`,
# and only a runtime-side cross-tenant read fallback masked the mismatch — so
# a bundle deployed under tenant X was silently routable as `default`. #232
# teaches env-deploy to stamp
#   route_binding.tenant_selector = { tenant: <--tenant>, team: "default" }
# with a match-all `/` path prefix (the deployer rejects a tenant_selector
# that has no host/path matcher).
#
# Why our suite missed it: nothing ever deployed a bundle under a NON-default
# tenant and asserted the on-disk binding. Every path used the default tenant,
# where "absent route_binding" and "correct route_binding" look identical from
# the outside (both route as `default`). This guard deploys under a non-default
# tenant (`acme`) and asserts the persisted environment.json binding names it.
#
# The assertion is the on-disk source of truth: it is NOT masked by any runtime
# cross-tenant read fallback. A pre-#232 binary produces environment.json with
# no `.bundles[].route_binding` key → every check below fails.
#
# Usage:
#   ./scripts/run_tenant_binding_e2e.sh
#
# Options (env):
#   TENANT       non-default tenant to deploy under (default: acme)
#   WORK_DIR_BASE  pin scratch tree onto a real (non-symlinked) path (see below)
#   KEEP_BUNDLE  if set, don't wipe the generated bundle/HOME on exit
#   SKIP_BUILD   if set, skip the probe WASM + pack rebuild (requires existing dist/)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${ROOT_DIR}/fixtures"
PROBE_PACK_SRC="${FIXTURES_DIR}/packs/type-only-routing-probe"
ANSWERS_TEMPLATE="${FIXTURES_DIR}/wizard-answers/type-only-routing-bundle.json"
TENANT="${TENANT:-acme}"

if [ "${TENANT}" = "default" ] || [ "${TENANT}" = "demo" ]; then
  echo "FAIL: TENANT must be a non-default value (got '${TENANT}') or the guard is meaningless" >&2
  exit 1
fi

# WORK_DIR_BASE lets callers pin the scratch tree onto a real (non-symlinked)
# path. gtc's operator-key writer rejects any symlinked ancestor, and macOS
# `mktemp -t` ignores TMPDIR and lands under /var/folders (a symlink), which
# aborts the deploy. CI's Linux /tmp is fine, so this only matters locally.
WORK_DIR="$(mktemp -d "${WORK_DIR_BASE:-${TMPDIR:-/tmp}}/greentic-tenant-binding-XXXXXX")"
BUNDLE_DIR="${WORK_DIR}/bundle"
ANSWERS_FILE="${WORK_DIR}/answers.json"
DEPLOY_LOG="${WORK_DIR}/deploy.log"
# Isolated HOME so we never touch the operator's real ~/.greentic environments.
DEPLOY_HOME="${WORK_DIR}/home"
mkdir -p "${DEPLOY_HOME}"

cleanup() {
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
need greentic-pack
need cargo-component
need python3
need jq

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

# env-deploy wants a real .gtbundle archive (packing the bundle *directory*
# yields a tree with no bundle-manifest.json and is rejected). The wizard
# emits the archive under dist/.
GTBUNDLE="$(ls "${BUNDLE_DIR}"/dist/*.gtbundle 2>/dev/null | head -n1)"
if [ -z "${GTBUNDLE}" ] || [ ! -f "${GTBUNDLE}" ]; then
  echo "FAIL: no .gtbundle produced under ${BUNDLE_DIR}/dist" >&2
  exit 1
fi

# --- deploy under a non-default tenant --------------------------------------
echo "[env-deploy] deploying under tenant='${TENANT}' (env=local, isolated HOME)"
if ! HOME="${DEPLOY_HOME}" gtc setup env-deploy "${GTBUNDLE}" \
       --tenant "${TENANT}" --env local --non-interactive > "${DEPLOY_LOG}" 2>&1; then
  echo "FAIL: env-deploy exited non-zero" >&2
  tail -40 "${DEPLOY_LOG}" >&2
  exit 1
fi

ENVJSON="${DEPLOY_HOME}/.greentic/environments/local/environment.json"
if [ ! -f "${ENVJSON}" ]; then
  echo "FAIL: env-deploy wrote no environment.json at ${ENVJSON}" >&2
  find "${DEPLOY_HOME}/.greentic" -name environment.json >&2 2>/dev/null || true
  tail -40 "${DEPLOY_LOG}" >&2
  exit 1
fi

# --- assertions --------------------------------------------------------------
# The on-disk binding is the source of truth (no runtime fallback masks it).
# Locate the entry for our bundle by bundle_id, then assert the full stamp.
BUNDLE_ID="type-only-routing-e2e"

problems=()

# (1) route_binding key MUST exist for our bundle. Its very absence is the
#     pre-#232 regression (deployer then defaulted tenant to `default`).
if ! jq -e --arg id "${BUNDLE_ID}" \
     '.bundles[] | select(.bundle_id==$id) | has("route_binding")' "${ENVJSON}" >/dev/null 2>&1; then
  problems+=("no route_binding on bundle '${BUNDLE_ID}' — env-deploy did not stamp the tenant binding (regression #232)")
else
  # (2) tenant_selector.tenant must equal the deploy tenant (not default/demo).
  if ! jq -e --arg id "${BUNDLE_ID}" --arg t "${TENANT}" \
       '.bundles[] | select(.bundle_id==$id) | .route_binding.tenant_selector.tenant==$t' \
       "${ENVJSON}" >/dev/null 2>&1; then
    got=$(jq -r --arg id "${BUNDLE_ID}" \
      '.bundles[] | select(.bundle_id==$id) | .route_binding.tenant_selector.tenant // "<absent>"' "${ENVJSON}")
    problems+=("tenant_selector.tenant is '${got}', expected '${TENANT}' — setup tenant not carried onto the binding (regression #232)")
  fi
  # (3) team default, match-all path prefix, no host pins — the shape the
  #     deployer requires (a selector with no matcher is rejected).
  if ! jq -e --arg id "${BUNDLE_ID}" \
       '.bundles[] | select(.bundle_id==$id) | .route_binding
          | .tenant_selector.team=="default" and .path_prefixes==["/"] and (.hosts|length)==0' \
       "${ENVJSON}" >/dev/null 2>&1; then
    problems+=("route_binding shape wrong — expected team=default, path_prefixes=[\"/\"], hosts=[]")
  fi
fi

if [ "${#problems[@]}" -eq 0 ]; then
  echo "PASS: env-deploy stamped route_binding.tenant_selector.tenant='${TENANT}' (team=default, path_prefixes=[/], hosts=[])"
  exit 0
fi

echo "FAIL: tenant-binding regression:" >&2
for p in "${problems[@]}"; do echo "  - ${p}" >&2; done
echo "---environment.json bundles---" >&2
jq '.bundles' "${ENVJSON}" >&2 2>/dev/null || cat "${ENVJSON}" >&2
echo "---deploy log tail---" >&2
tail -40 "${DEPLOY_LOG}" >&2
exit 1
