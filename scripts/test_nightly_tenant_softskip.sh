#!/usr/bin/env bash
#
# Tests for nightly-e2e.yml's "Run gtc tenant install" soft-skip classifier.
#
# That step decides whether a failed `gtc install --tenant` is a KNOWN upstream
# release-artifact breakage (warn and pass) or a real failure (fail the job).
# Getting it wrong is expensive in both directions: too narrow and the nightly
# sits red on something this repo cannot fix; too broad and it mutes genuine
# regressions while still reporting green.
#
# The step's real `run:` body is extracted from the YAML and driven against a
# stubbed `gtc` that replays captured log signatures.
#
# Run: bash scripts/test_nightly_tenant_softskip.sh

# The captured log fixtures below are single-quoted ON PURPOSE: they are
# verbatim CI output containing backticks and $-signs that must reach the
# classifier unexpanded, exactly as the real log would. SC2016 flags that idiom.
# shellcheck disable=SC2016
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/nightly-e2e.yml"
STEP_NAME="Run gtc tenant install"

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

# greentic-component v1.1.3: the Windows asset named .zip was a POSIX tar, so
# binstall could not extract it, built from source, and collided.
# Run 32434112475. FIXED upstream in greentic-component 1.1.5, and the
# soft-skip entry was removed with it — so this signature must now FAIL the
# job. Kept as a fixture precisely so a silent recurrence is caught: if these
# release assets ever regress to tar-named-zip, the nightly goes red again
# instead of quietly passing on a mute nobody remembers.
LOG_WINDOWS_ZIP_IS_TAR='  WARN resolve: Error while downloading and extracting from fetcher github.com: Failed to extract zipfile: format: end of central directory record not found
  WARN The package greentic-component v1.1.3 will be installed from source (with cargo)
error: binary `greentic-component.exe` already exists in destination
Add --force to overwrite
ERROR Cargo errored! ExitStatus(ExitStatus(101))
Error: `cargo binstall` failed while installing greentic-component (crate greentic-component), exit code Some(70)'

# The extract failure ALONE. cargo-binstall recovers from this routinely by
# building from source, so on its own it must NOT authorise a skip.
LOG_EXTRACT_WARNING_ONLY='  WARN resolve: Error while downloading and extracting from fetcher github.com: Failed to extract zipfile: format: end of central directory record not found
  WARN The package greentic-component v1.1.3 will be installed from source (with cargo)
   Compiling greentic-component v1.1.3
error: could not compile `greentic-component` due to 3 previous errors'

LOG_DESIGNER_JSON='ERROR asset `greentic-designer.json` not found in release v1.0.13'
LOG_CHAT2DATA='ERROR greentic-chat2data: no target for macos / x86_64'

# A genuine regression that must fail the job.
LOG_REAL_FAILURE='ERROR Fatal error:
  × tenant 3point is not entitled to greentic-operator
Error: tenant resolution failed, exit code Some(2)'

# run_step <log-fixture> ; echoes the step exit code
run_step() {
  local logtext="$1"
  local sb; sb="$(mktemp -d)"
  mkdir -p "${sb}/bin" "${sb}/tmp"
  printf '%s' "$logtext" > "${sb}/fixture.log"

  cat > "${sb}/bin/gtc" <<STUB
#!/usr/bin/env bash
# \`gtc install --help\` must advertise --token so the step takes that arm.
for a in "\$@"; do [[ "\$a" == "--help" ]] && { echo "  --token <TOKEN>  tenant token"; exit 0; }; done
cat "${sb}/fixture.log"
exit 1
STUB
  chmod +x "${sb}/bin/gtc"

  extract_step > "${sb}/step.sh"
  local rc=0
  ( PATH="${sb}/bin:/usr/bin:/bin" \
    RUNNER_TEMP="${sb}/tmp" \
    GREENTIC_TENANT_TOKEN=stub-token \
    GREENTIC_TENANT=3point \
    GTC_RELEASE=1.1.2 \
    bash "${sb}/step.sh" ) >"${sb}/out" 2>&1 || rc=$?
  rm -rf "$sb"
  echo "$rc"
}

# --------------------------------------------------------------------------

t_windows_zip_is_tar_is_no_longer_muted() {
  local rc; rc="$(run_step "$LOG_WINDOWS_ZIP_IS_TAR")"
  [[ "$rc" != "0" ]] || no "still soft-skipped; the entry should have gone with the upstream fix"
}

# The whole point of requiring TWO signatures.
t_extract_warning_alone_is_not_a_skip() {
  local rc; rc="$(run_step "$LOG_EXTRACT_WARNING_ONLY")"
  [[ "$rc" != "0" ]] || no "a lone extract warning was soft-skipped; it must fail the job"
}

t_real_failure_still_fails() {
  local rc; rc="$(run_step "$LOG_REAL_FAILURE")"
  [[ "$rc" != "0" ]] || no "an unrelated failure was soft-skipped"
}

# The two pre-existing signatures must keep working.
t_designer_json_still_skips() {
  local rc; rc="$(run_step "$LOG_DESIGNER_JSON")"
  [[ "$rc" == "0" ]] || no "expected soft-skip (exit 0), got exit ${rc}"
}

t_chat2data_still_skips() {
  local rc; rc="$(run_step "$LOG_CHAT2DATA")"
  [[ "$rc" == "0" ]] || no "expected soft-skip (exit 0), got exit ${rc}"
}

echo "nightly-e2e tenant-install soft-skip"
run_test "no longer mutes the Windows .zip-is-really-a-tar breakage" t_windows_zip_is_tar_is_no_longer_muted
run_test "does NOT skip on the extract warning alone"           t_extract_warning_alone_is_not_a_skip
run_test "does NOT skip an unrelated failure"                   t_real_failure_still_fails
run_test "still skips the missing greentic-designer.json"       t_designer_json_still_skips
run_test "still skips the absent macos/x86_64 target"           t_chat2data_still_skips

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
