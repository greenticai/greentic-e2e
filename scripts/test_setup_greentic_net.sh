#!/usr/bin/env bash
#
# Unit tests for .github/actions/setup-greentic/lib/net.sh.
#
# Regression guard for run 33363027898, where the `Install cargo-binstall` step
# of the shared toolchain action died 53ms in with
#
#     curl: (35) Recv failure: Connection reset by peer
#
# taking the whole `tenant-binding` job down in 28s. The two sibling matrix jobs
# fetched the SAME url seconds either side of it and passed, so the fetch was
# transient — but the step ran it exactly once, so one reset was fatal.
#
# These tests stub `curl` on PATH so the retry and truncation behaviour can be
# driven deterministically without touching the network.
#
# Run: bash scripts/test_setup_greentic_net.sh

# The curl-stub bodies below are single-quoted ON PURPOSE: they must reach the
# stub file unexpanded and expand when the stub RUNS, against curl's real
# arguments. SC2016 flags exactly that idiom.
# shellcheck disable=SC2016
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT_DIR}/.github/actions/setup-greentic/lib/net.sh"

[[ -f "$LIB" ]] || { echo "missing lib: $LIB" >&2; exit 1; }

pass=0
fail=0

# Each test body runs in its own subshell so its stubbed PATH and sourced lib
# cannot leak into the next one. That means a body CANNOT report a failure by
# incrementing a counter — the increment would be lost with the subshell — so
# `no` exits non-zero and the parent counts the subshell's status. An earlier
# revision of this file counted inside the subshell and printed "0 passed, 0
# failed" while every test ran; a red suite would have reported green.
no() { printf '     %s\n' "${1:-assertion failed}"; exit 1; }

run_test() {
  local name="$1"
  local body="$2"
  if ( set +e; "$body" ); then
    printf '  ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"
    fail=$((fail + 1))
  fi
}

# Private dir with a stub `curl` first on PATH. The stub counts its own
# invocations in a file so a test can assert how many attempts happened.
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "${SANDBOX}/bin"
  COUNTER="${SANDBOX}/attempts"
  : > "$COUNTER"
  PATH="${SANDBOX}/bin:${PATH}"
  # Retries must not really sleep, or the suite takes minutes.
  export GT_RETRY_BASE_DELAY=0
  DEST="${SANDBOX}/out.sh"
}

attempts() { wc -l < "$COUNTER" | tr -d ' '; }

# write_curl_stub <script-body>
# The body runs with "$@" set to curl's real arguments. Helpers available:
#   curl_out   -- the path curl was asked to write (-o <path>)
#   n          -- this invocation's 1-based attempt number
write_curl_stub() {
  cat > "${SANDBOX}/bin/curl" <<STUB
#!/usr/bin/env bash
echo x >> "${COUNTER}"
n=\$(wc -l < "${COUNTER}" | tr -d ' ')
curl_out=""
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-o" || "\$prev" == "--output" ]]; then curl_out="\$a"; fi
  prev="\$a"
done
$1
STUB
  chmod +x "${SANDBOX}/bin/curl"
}

RESET='echo "curl: (35) Recv failure: Connection reset by peer" >&2; exit 35'

# --------------------------------------------------------------------------

t_first_attempt() {
  new_sandbox
  write_curl_stub 'printf "installer\n" > "$curl_out"; exit 0'
  # shellcheck source=/dev/null
  source "$LIB"
  gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1 || no "gt_fetch returned non-zero"
  [[ "$(cat "$DEST")" == "installer" ]] || no "dest content is $(cat "$DEST")"
  [[ "$(attempts)" == "1" ]] || no "made $(attempts) attempts, want 1"
}

# THE regression: two connection resets (curl exit 35, exactly what run
# 33363027898 hit), then a good response.
t_retries_reset() {
  new_sandbox
  write_curl_stub "
if (( n < 3 )); then ${RESET}; fi
printf 'installer\n' > \"\$curl_out\"
exit 0"
  # shellcheck source=/dev/null
  source "$LIB"
  gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1 || no "gt_fetch gave up"
  [[ "$(cat "$DEST")" == "installer" ]] || no "dest content is $(cat "$DEST")"
  [[ "$(attempts)" == "3" ]] || no "made $(attempts) attempts, want 3"
}

t_gives_up() {
  new_sandbox
  write_curl_stub "$RESET"
  # shellcheck source=/dev/null
  source "$LIB"
  ! gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1 || no "gt_fetch reported success"
  [[ ! -e "$DEST" ]] || no "left a file at dest"
}

# `curl | bash` executes whatever bytes arrived before the reset. A half
# installer on PATH is worse than none: it fails later, somewhere else.
t_no_truncated_publish() {
  new_sandbox
  write_curl_stub '
printf "half-an-inst" > "$curl_out"
echo "curl: (18) transfer closed with outstanding read data remaining" >&2
exit 18'
  # shellcheck source=/dev/null
  source "$LIB"
  gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1
  [[ ! -e "$DEST" ]] || no "dest holds: $(cat "$DEST")"
}

t_rejects_empty() {
  new_sandbox
  write_curl_stub ': > "$curl_out"; exit 0'
  # shellcheck source=/dev/null
  source "$LIB"
  ! gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1 || no "accepted a zero-byte body"
  [[ ! -e "$DEST" ]] || no "left a file at dest"
}

t_retry_flaky_command() {
  new_sandbox
  # shellcheck source=/dev/null
  source "$LIB"
  local tries="${SANDBOX}/tries"
  : > "$tries"
  # shellcheck disable=SC2317  # run indirectly, via gt_retry
  flaky() { echo x >> "$tries"; (( $(wc -l < "$tries") >= 2 )); }
  gt_retry "flaky thing" flaky >/dev/null 2>&1 || no "gt_retry gave up"
  [[ "$(wc -l < "$tries" | tr -d ' ')" == "2" ]] || no "ran $(wc -l < "$tries") times, want 2"
}

t_retry_surfaces_failure() {
  new_sandbox
  # shellcheck source=/dev/null
  source "$LIB"
  ! gt_retry "doomed" false >/dev/null 2>&1 || no "gt_retry reported success"
}

# The action's steps run with `set -euo pipefail`; a helper that trips errexit
# on its first failed attempt would never reach attempt 2.
t_survives_errexit() {
  new_sandbox
  write_curl_stub "
if (( n < 2 )); then ${RESET}; fi
printf 'installer\n' > \"\$curl_out\"; exit 0"
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$LIB"
  gt_fetch https://example.invalid/x.sh "$DEST" >/dev/null 2>&1 || no "gt_fetch did not recover"
  [[ -s "$DEST" ]] || no "dest is empty"
}

echo "gt_fetch"
run_test "fetches on the first attempt"           t_first_attempt
run_test "retries past a transient connection reset" t_retries_reset
run_test "fails when every attempt fails"         t_gives_up
run_test "never publishes a truncated download"   t_no_truncated_publish
run_test "rejects an empty download"              t_rejects_empty
run_test "retries even under set -euo pipefail"   t_survives_errexit

echo "gt_retry"
run_test "retries a flaky command until it succeeds" t_retry_flaky_command
run_test "fails when the command never succeeds"     t_retry_surfaces_failure

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
