#!/usr/bin/env bash
#
# Tests for nightly-e2e.yml's "Run gtc public install" retry predicate.
#
# `gtc install --release` prefetches ~110 packs and components from ghcr.io,
# one pull each, all-or-nothing, with no retry of its own. On 2026-09-07 the
# macOS x64 leg lost run 34075162802 to a single `401 Not authorized` on the
# 101st manifest GET; the package was public, the other five platforms pulled
# it in the same run, and the same commit had passed the night before.
#
# The step retries THAT signature and nothing else. These tests pin both
# halves: the transient pull IS retried, and a deterministic failure (a source
# build that does not compile) is NOT — because on macOS x64 the deterministic
# case costs ~30 minutes per attempt, and three of them breach the job timeout.
#
# The step's real `run:` body is extracted from the YAML and driven against a
# stubbed `gtc` that replays a captured log signature.
#
# Run: bash scripts/test_nightly_public_install_retry.sh

# The captured log fixtures below are single-quoted ON PURPOSE: they are
# verbatim CI output containing backticks that must reach the predicate
# unexpanded, exactly as the real log would. SC2016 flags that idiom.
# shellcheck disable=SC2016
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/nightly-e2e.yml"
STEP_NAME="Run gtc public install"

[[ -f "$WORKFLOW" ]] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }

pass=0
fail=0
no() { printf '     %s\n' "${1:-assertion failed}"; exit 1; }
run_test() {
  local name="$1" body="$2"
  if ( set +e; "$body" ); then
    printf '  ok   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"; fail=$((fail + 1))
  fi
}

extract_step() {
  WORKFLOW="$WORKFLOW" STEP="$STEP_NAME" python3 - <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ["WORKFLOW"]))
want = os.environ["STEP"]
for job in d["jobs"].values():
    for st in job.get("steps", []):
        if st.get("name") == want:
            sys.stdout.write(st["run"]); sys.exit(0)
sys.exit(f"step not found: {want}")
PY
}

# --- captured signatures ----------------------------------------------------
# Real excerpts. Trimmed, but the matched substrings are verbatim.

# Run 34075162802, macOS x64 only. 100 packs prefetched fine in the seconds
# before this one; the package is public and pulls anonymously; the same
# commit passed the night before. A registry hiccup, not a broken release.
LOG_TRANSIENT_401='Prefetching pack packs/deployer/greentic.deploy.juju-k8s:0.5.22 (ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-k8s:0.5.22)
Prefetched pack packs/deployer/greentic.deploy.juju-k8s:0.5.22 -> sha256:fd868b0fb22a257f36eb08d0aff47e72dfa7970b4f85d107a0cd0a48937c0d81
Prefetching pack packs/deployer/greentic.deploy.juju-machine:0.5.22 (ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22)
failed to prefetch release artifacts: failed to prefetch ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22: oci pack error: failed to pull `ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22`: Not authorized: url https://ghcr.io/v2/greenticai/packs/deployer/greentic.deploy.juju-machine/manifests/0.5.22'

# A deterministic failure: the binstall fallback built greentic-deployer from
# source and the build did not compile. Retrying costs ~30 min per attempt on
# macOS x64 and arrives at the same answer.
LOG_SOURCE_BUILD_FAILED='Installing greentic-deployer binary greentic-deployer.
cargo-binstall:  WARN The package greentic-deployer v1.1.16 will be installed from source (with cargo)
   Compiling greentic-deployer v1.1.16
error[E0308]: mismatched types
error: could not compile `greentic-deployer` (bin "greentic-deployer") due to 1 previous error
error: failed to compile `greentic-deployer v1.1.16`
Failed to install greentic-deployer binary greentic-deployer.'

# A pull refused for a reason that is NOT a 401. Same prefetch site, same
# "failed to pull" wrapper; must not be retried.
LOG_MANIFEST_MISSING='Prefetching pack packs/deployer/greentic.deploy.juju-machine:0.5.22 (ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22)
failed to prefetch release artifacts: failed to prefetch ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22: oci pack error: failed to pull `ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22`: Image manifest not found: ghcr.io/greenticai/packs/deployer/greentic.deploy.juju-machine:0.5.22'

# run_step_flaky <fail-first-N> <log-fixture> ; echoes "<step-rc> <gtc-calls>"
#
# Counts invocations, because the retry's failure mode is not "too few" but
# "too many": a predicate widened to cover deterministic failures would still
# reach the right verdict, just three times slower, and no assertion on the
# exit code alone would notice.
#
# `sleep` is stubbed to a no-op. The backoff is real and would add half a
# minute to this suite; the step's timing is not what these tests are about.
run_step_flaky() {
  local fail_n="$1" logtext="$2"
  local sb; sb="$(mktemp -d)"
  mkdir -p "${sb}/bin" "${sb}/tmp"
  printf '%s' "$logtext" > "${sb}/fixture.log"
  echo 0 > "${sb}/calls"

  cat > "${sb}/bin/gtc" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "${sb}/calls") + 1 )); echo "\$n" > "${sb}/calls"
if [[ "\$n" -le ${fail_n} ]]; then cat "${sb}/fixture.log"; exit 1; fi
echo "public install completed on attempt \$n"
exit 0
STUB
  chmod +x "${sb}/bin/gtc"

  printf '#!/usr/bin/env bash\nexit 0\n' > "${sb}/bin/sleep"
  chmod +x "${sb}/bin/sleep"

  extract_step > "${sb}/step.sh"
  local rc=0
  ( PATH="${sb}/bin:/usr/bin:/bin" \
    RUNNER_TEMP="${sb}/tmp" \
    GTC_RELEASE=1.1.2 \
    bash "${sb}/step.sh" ) >"${sb}/out" 2>&1 || rc=$?
  local calls; calls="$(cat "${sb}/calls")"
  LAST_OUT="$(cat "${sb}/out")"
  rm -rf "$sb"
  echo "$rc $calls"
}
LAST_OUT=""

# --------------------------------------------------------------------------

t_transient_401_is_retried_then_succeeds() {
  local r; r="$(run_step_flaky 2 "$LOG_TRANSIENT_401")"
  [[ "$r" == "0 3" ]] || no "expected exit 0 on the third attempt, got '${r}' (rc calls)"
}

# Retrying is not muting. Three refused pulls in a row is a real failure.
t_persistent_401_still_fails() {
  local r; r="$(run_step_flaky 9 "$LOG_TRANSIENT_401")"
  [[ "$r" == "1 3" ]] || no "expected exit 1 after exactly 3 attempts, got '${r}' (rc calls)"
}

# Guards the predicate from being widened to "any failed pull".
t_missing_manifest_is_not_retried() {
  local r; r="$(run_step_flaky 9 "$LOG_MANIFEST_MISSING")"
  [[ "$r" == "1 1" ]] || no "expected a single attempt, got '${r}' (rc calls)"
}

t_source_build_failure_is_not_retried() {
  local r; r="$(run_step_flaky 9 "$LOG_SOURCE_BUILD_FAILED")"
  [[ "$r" == "1 1" ]] || no "expected a single attempt, got '${r}' (rc calls)"
}

# The "Diagnose public install failure" step reads the printed log; a retry
# must not swallow it.
t_failed_log_is_still_printed() {
  run_step_flaky 9 "$LOG_SOURCE_BUILD_FAILED" >/dev/null
  [[ "$LAST_OUT" == *'could not compile `greentic-deployer`'* ]] \
    || no "the failing install log was not echoed to the job output"
}

echo "nightly-e2e public-install retry"
run_test "retries a transient 401 from the registry, then succeeds" t_transient_401_is_retried_then_succeeds
run_test "still FAILS when the 401 persists"                        t_persistent_401_still_fails
run_test "does NOT retry a missing manifest"                        t_missing_manifest_is_not_retried
run_test "does NOT retry a failed source build"                     t_source_build_failure_is_not_retried
run_test "still prints the failing install log"                     t_failed_log_is_still_printed

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
