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

# A truncated HTTP body, not a broken artifact. Run 33938472752, Linux arm64
# only: the release-metadata JSON is 194132 bytes and the parse died at column
# 185662, while the other five platforms fetched the same release in the same
# run and passed. This one IS retried - and must still fail if it persists.
LOG_TRUNCATED_BODY='Error: failed to parse GitHub release metadata for `https://github.com/greentic-biz/telco-x/releases/download/v1.1.0/assistant_templates__README.md`

Caused by:
    0: error decoding response body
    1: EOF while parsing a value at line 1 column 185662'

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

# run_step_flaky <fail-first-N> <log-fixture> ; echoes "<step-rc> <gtc-calls>"
#
# Counts invocations, because the retry's failure mode is not "too few" but
# "too many": a predicate widened to cover deterministic failures would still
# reach the right verdict, just three times slower, and no assertion on the
# exit code alone would notice.
#
# `sleep` is stubbed to a no-op. The backoff is real (10s then 20s) and would
# add 30s to this suite; the step's timing is not what these tests are about.
run_step_flaky() {
  local fail_n="$1" logtext="$2"
  local sb; sb="$(mktemp -d)"
  mkdir -p "${sb}/bin" "${sb}/tmp"
  printf '%s' "$logtext" > "${sb}/fixture.log"
  echo 0 > "${sb}/calls"

  cat > "${sb}/bin/gtc" <<STUB
#!/usr/bin/env bash
# \`gtc install --help\` must advertise --token, and must not be counted.
for a in "\$@"; do [[ "\$a" == "--help" ]] && { echo "  --token <TOKEN>  tenant token"; exit 0; }; done
n=\$(( \$(cat "${sb}/calls") + 1 )); echo "\$n" > "${sb}/calls"
if [[ "\$n" -le ${fail_n} ]]; then cat "${sb}/fixture.log"; exit 1; fi
echo "tenant install completed on attempt \$n"
exit 0
STUB
  chmod +x "${sb}/bin/gtc"

  printf '#!/usr/bin/env bash\nexit 0\n' > "${sb}/bin/sleep"
  chmod +x "${sb}/bin/sleep"

  extract_step > "${sb}/step.sh"
  local rc=0
  ( PATH="${sb}/bin:/usr/bin:/bin" \
    RUNNER_TEMP="${sb}/tmp" \
    GREENTIC_TENANT_TOKEN=stub-token \
    GREENTIC_TENANT=3point \
    GTC_RELEASE=1.1.2 \
    bash "${sb}/step.sh" ) >"${sb}/out" 2>&1 || rc=$?
  local calls; calls="$(cat "${sb}/calls")"
  rm -rf "$sb"
  echo "$rc $calls"
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

t_truncated_body_is_retried_then_succeeds() {
  local r; r="$(run_step_flaky 2 "$LOG_TRUNCATED_BODY")"
  [[ "$r" == "0 3" ]] || no "expected exit 0 on the third attempt, got '${r}' (rc calls)"
}

# Retrying is not muting. Three truncated bodies in a row is a real failure.
t_persistent_truncation_still_fails() {
  local r; r="$(run_step_flaky 9 "$LOG_TRUNCATED_BODY")"
  [[ "$r" == "1 3" ]] || no "expected exit 1 after exactly 3 attempts, got '${r}' (rc calls)"
}

# Guards the retry predicate from being widened.
t_soft_skip_signature_is_decided_on_the_first_attempt() {
  local r; r="$(run_step_flaky 9 "$LOG_DESIGNER_JSON")"
  [[ "$r" == "0 1" ]] || no "expected a soft-skip after ONE attempt, got '${r}' (rc calls)"
}

t_real_failure_is_not_retried() {
  local r; r="$(run_step_flaky 9 "$LOG_REAL_FAILURE")"
  [[ "$r" == "1 1" ]] || no "expected a single attempt, got '${r}' (rc calls)"
}

echo "nightly-e2e tenant-install soft-skip"
run_test "no longer mutes the Windows .zip-is-really-a-tar breakage" t_windows_zip_is_tar_is_no_longer_muted
run_test "does NOT skip on the extract warning alone"           t_extract_warning_alone_is_not_a_skip
run_test "does NOT skip an unrelated failure"                   t_real_failure_still_fails
run_test "still skips the missing greentic-designer.json"       t_designer_json_still_skips
run_test "still skips the absent macos/x86_64 target"           t_chat2data_still_skips
run_test "retries a truncated response body, then succeeds"     t_truncated_body_is_retried_then_succeeds
run_test "still FAILS when the truncation persists"             t_persistent_truncation_still_fails
run_test "decides a soft-skip signature on the first attempt"   t_soft_skip_signature_is_decided_on_the_first_attempt
run_test "does NOT retry an unrelated failure"                  t_real_failure_is_not_retried

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
