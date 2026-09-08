#!/usr/bin/env bash
#
# Tests for scripts/wizard_pack_retry.sh's retry predicate.
#
# `gtc wizard` pulls every `oci://` provider in the bundle with no retry of its
# own. On 2026-09-08 the messaging-teams leg lost run 34189156283 to a single
# failed resolve of a pack that had not changed since 2026-07-08 and that its
# five sibling legs pulled from the same registry minutes either side.
#
# The helper retries THAT signature and nothing else. These tests pin both
# halves — the failed resolve IS retried, a deterministic wizard failure is NOT
# — and they count invocations, because the failure mode of a widened predicate
# is not a wrong verdict but the same verdict arriving three times slower, which
# no assertion on the exit code alone would notice.
#
# Run: bash scripts/test_wizard_pack_retry.sh

# The captured log fixtures below are single-quoted ON PURPOSE: they are
# verbatim CI output containing backticks that must reach the predicate
# unexpanded, exactly as the real log would. SC2016 flags that idiom.
# shellcheck disable=SC2016
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/scripts/wizard_pack_retry.sh"

[[ -f "$HELPER" ]] || { echo "missing helper: $HELPER" >&2; exit 1; }

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

# --- captured signatures ----------------------------------------------------
# Real excerpts from the runs named above. Trimmed, but the matched substrings
# are verbatim — including the missing cause: `greentic-bundle` prints its
# anyhow error with `{err}`, so the registry's own status code is nowhere in
# this log.

# Run 34189156283, messaging-teams only. 0.4s from the resolve starting to the
# failure; the pack was public, unchanged since 2026-07-08, and pulled fine the
# night before.
LOG_RESOLVE_FAILED='  [1/1] Resolving provider: oci://ghcr.io/greenticai/packs/messaging/messaging-teams:latest
resolve OCI pack ref oci://ghcr.io/greenticai/packs/messaging/messaging-teams:latest
Error: wizard step command failed: greentic-bundle ["wizard", "apply", "--answers", ".greentic/wizard/run-1788844108/delegated-answers.json"] (exit code Some(1))'

# A deterministic failure: the answers file does not match the wizard schema.
# Nothing about a second attempt changes the verdict.
LOG_BAD_ANSWERS='Error: answers file does not satisfy greentic-bundle.wizard.answers 1.0.0: missing field `target_root`'

# Also deterministic, and the one most likely to be mistaken for the transient
# case: the wizard reached the registry and the tooling refused the bundle it
# was asked to write.
LOG_BUNDLE_EXISTS='  [1/1] Resolving provider: oci://ghcr.io/greenticai/packs/messaging/messaging-teams:latest
  [done] Resolved 1 package(s)
Error: bundle already exists at /tmp/tmp.8YbnPGTGmq/bundle'

# run_helper_flaky <fail-first-N> <log-fixture> ; echoes "<rc> <gtc-calls>"
#
# `sleep` is stubbed to a no-op — the backoff is real and would add 15s to this
# suite, and the helper's timing is not what these tests are about.
run_helper_flaky() {
  local fail_n="$1" logtext="$2"
  local sb; sb="$(mktemp -d)"
  mkdir -p "${sb}/bin" "${sb}/tmp"
  printf '%s' "$logtext" > "${sb}/fixture.log"
  echo 0 > "${sb}/calls"

  cat > "${sb}/bin/gtc" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "${sb}/calls") + 1 )); echo "\$n" > "${sb}/calls"
printf '%s\n' "\$*" >> "${sb}/argv"
if [[ "\$n" -le ${fail_n} ]]; then cat "${sb}/fixture.log"; exit 1; fi
echo "wizard completed on attempt \$n"
exit 0
STUB
  chmod +x "${sb}/bin/gtc"

  printf '#!/usr/bin/env bash\nexit 0\n' > "${sb}/bin/sleep"
  chmod +x "${sb}/bin/sleep"

  local rc=0
  ( PATH="${sb}/bin:/usr/bin:/bin" \
    RUNNER_TEMP="${sb}/tmp" \
    bash -c ". '${HELPER}'; gtc_wizard_with_pack_retry --answers /tmp/answers.json" \
  ) >"${sb}/out" 2>&1 || rc=$?
  local calls; calls="$(cat "${sb}/calls")"
  LAST_OUT="$(cat "${sb}/out")"
  LAST_ARGV="$(cat "${sb}/argv" 2>/dev/null || true)"
  LAST_TMP_LEFTOVERS="$(ls -A "${sb}/tmp" 2>/dev/null || true)"
  rm -rf "$sb"
  echo "$rc $calls"
}
LAST_OUT=""
LAST_ARGV=""
LAST_TMP_LEFTOVERS=""

# --------------------------------------------------------------------------

t_failed_resolve_is_retried_then_succeeds() {
  local r; r="$(run_helper_flaky 2 "$LOG_RESOLVE_FAILED")"
  [[ "$r" == "0 3" ]] || no "expected exit 0 on the third attempt, got '${r}' (rc calls)"
}

# Retrying is not muting. Three failed resolves in a row is a real failure.
t_persistent_resolve_failure_still_fails() {
  local r; r="$(run_helper_flaky 9 "$LOG_RESOLVE_FAILED")"
  [[ "$r" == "1 3" ]] || no "expected exit 1 after exactly 3 attempts, got '${r}' (rc calls)"
}

t_bad_answers_is_not_retried() {
  local r; r="$(run_helper_flaky 9 "$LOG_BAD_ANSWERS")"
  [[ "$r" == "1 1" ]] || no "expected a single attempt, got '${r}' (rc calls)"
}

# Guards the predicate from being widened to "anything that mentions a pack".
t_bundle_already_exists_is_not_retried() {
  local r; r="$(run_helper_flaky 9 "$LOG_BUNDLE_EXISTS")"
  [[ "$r" == "1 1" ]] || no "expected a single attempt, got '${r}' (rc calls)"
}

# The step's own diagnostics read the wizard's output; the wrapper captures it
# to a file, so it has to hand it back.
t_failing_output_is_still_printed() {
  run_helper_flaky 9 "$LOG_RESOLVE_FAILED" >/dev/null
  [[ "$LAST_OUT" == *'resolve OCI pack ref oci://ghcr.io/greenticai/packs/messaging/messaging-teams:latest'* ]] \
    || no "the failing wizard output was not echoed to the job output"
}

t_successful_output_is_still_printed() {
  run_helper_flaky 0 "$LOG_RESOLVE_FAILED" >/dev/null
  [[ "$LAST_OUT" == *'wizard completed on attempt 1'* ]] \
    || no "the successful wizard output was not echoed to the job output"
}

# The call sites pass the answers path and nothing else today, but a wrapper
# that ate an argument would look identical until someone added one.
t_arguments_reach_gtc_verbatim() {
  run_helper_flaky 0 "$LOG_RESOLVE_FAILED" >/dev/null
  [[ "$LAST_ARGV" == 'wizard --answers /tmp/answers.json' ]] \
    || no "expected 'wizard --answers /tmp/answers.json', got '${LAST_ARGV}'"
}

# RUNNER_TEMP survives the whole job; a log left behind on every wizard call
# would accumulate silently.
t_capture_log_is_cleaned_up() {
  run_helper_flaky 9 "$LOG_BAD_ANSWERS" >/dev/null
  [[ -z "$LAST_TMP_LEFTOVERS" ]] \
    || no "left files behind in RUNNER_TEMP: ${LAST_TMP_LEFTOVERS}"
}

echo "gtc wizard pack-resolve retry"
run_test "retries a failed pack resolve, then succeeds"  t_failed_resolve_is_retried_then_succeeds
run_test "still FAILS when the resolve keeps failing"    t_persistent_resolve_failure_still_fails
run_test "does NOT retry a rejected answers file"        t_bad_answers_is_not_retried
run_test "does NOT retry an already-existing bundle"     t_bundle_already_exists_is_not_retried
run_test "still prints the failing wizard output"        t_failing_output_is_still_printed
run_test "still prints the successful wizard output"     t_successful_output_is_still_printed
run_test "passes its arguments through verbatim"         t_arguments_reach_gtc_verbatim
run_test "removes its capture log"                       t_capture_log_is_cleaned_up

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
