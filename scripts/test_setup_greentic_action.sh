#!/usr/bin/env bash
#
# Integration tests for .github/actions/setup-greentic/action.yml.
#
# The unit tests in test_setup_greentic_net.sh prove lib/net.sh retries. They
# cannot prove the ACTION uses it — a step that forgets to source the lib, or
# calls curl directly, passes those tests and still dies on the first reset.
# This suite extracts each step's real `run:` body out of the YAML and executes
# it against stubbed network tools.
#
# Run: bash scripts/test_setup_greentic_action.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="${ROOT_DIR}/.github/actions/setup-greentic"
ACTION="${ACTION_DIR}/action.yml"

[[ -f "$ACTION" ]] || { echo "missing action: $ACTION" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

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

# Extract one step's `run:` body by name, with GHA expressions resolved to their
# input defaults so the result is executable bash.
step_body() {
  ACTION="$ACTION" STEP="$1" python3 - <<'PY'
import os, re, sys, yaml
d = yaml.safe_load(open(os.environ["ACTION"]))
defaults = {k: str(v.get("default", "")) for k, v in (d.get("inputs") or {}).items()}
want = os.environ["STEP"]
for st in d["runs"]["steps"]:
    name = re.sub(r"\$\{\{[^}]*\}\}", "", st["name"]).strip()
    if want in name:
        body = st.get("run", "")
        def sub(m):
            expr = m.group(1).strip()
            if expr.startswith("inputs."):
                return defaults.get(expr.split(".", 1)[1], "")
            return "stub-token"
        sys.stdout.write(re.sub(r"\$\{\{(.*?)\}\}", sub, body))
        sys.exit(0)
sys.exit(f"step not found: {want}")
PY
}

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "${SANDBOX}/bin" "${SANDBOX}/home/.cargo/bin" "${SANDBOX}/tmp"
  COUNTER="${SANDBOX}/attempts"
  : > "$COUNTER"
  # A sandboxed HOME keeps the step's `PATH="$HOME/.cargo/bin:$PATH"` off the
  # real toolchain, so `command -v cargo-binstall` is genuinely false.
  export HOME="${SANDBOX}/home"
  export RUNNER_TEMP="${SANDBOX}/tmp"
  export RUNNER_OS=Linux
  export GITHUB_ACTION_PATH="$ACTION_DIR"
  export GITHUB_PATH="${SANDBOX}/github_path"; : > "$GITHUB_PATH"
  export GT_RETRY_BASE_DELAY=0
  # PATH is REPLACED, not prepended. Inheriting the developer's own
  # ~/.cargo/bin let `command -v cargo-binstall` succeed, so the step
  # short-circuited and the test asserted nothing while reporting green.
  PATH="${SANDBOX}/bin:/usr/bin:/bin"
}

attempts() { wc -l < "$COUNTER" | tr -d ' '; }

# Fold `\`-continued lines into one. Without this a line-based grep for
# `curl ... | bash` misses the real thing, which wraps the url onto its own
# line — both pipe checks below passed against the known-broken original.
join_continuations() {
  awk '{
    while (sub(/\\$/, "")) {
      if ((getline nxt) > 0) { sub(/^[[:space:]]+/, "", nxt); $0 = $0 nxt } else break
    }
    print
  }'
}

# A `cargo` that only knows `binstall -V`, so the step's final check resolves.
stub_cargo() {
  cat > "${SANDBOX}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "binstall" ]] && { echo "cargo-binstall 1.99.0 (stub)"; exit 0; }
exit 0
STUB
  chmod +x "${SANDBOX}/bin/cargo"
}

# curl stub: fails with a connection reset for the first $1 attempts, then
# serves an "installer" that drops a cargo-binstall on PATH.
stub_curl_reset_then_ok() {
  local resets="$1"
  cat > "${SANDBOX}/bin/curl" <<STUB
#!/usr/bin/env bash
echo x >> "${COUNTER}"
n=\$(wc -l < "${COUNTER}" | tr -d ' ')
out=""; prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-o" || "\$prev" == "--output" ]]; then out="\$a"; fi
  prev="\$a"
done
if (( n <= ${resets} )); then
  echo "curl: (35) Recv failure: Connection reset by peer" >&2
  exit 35
fi
cat > "\$out" <<'INSTALLER'
#!/usr/bin/env bash
printf '#!/usr/bin/env bash\necho stub\n' > "\${SANDBOX_BIN}/cargo-binstall"
chmod +x "\${SANDBOX_BIN}/cargo-binstall"
INSTALLER
exit 0
STUB
  chmod +x "${SANDBOX}/bin/curl"
  export SANDBOX_BIN="${SANDBOX}/bin"
}

stub_curl_always_reset() {
  cat > "${SANDBOX}/bin/curl" <<STUB
#!/usr/bin/env bash
echo x >> "${COUNTER}"
echo "curl: (35) Recv failure: Connection reset by peer" >&2
exit 35
STUB
  chmod +x "${SANDBOX}/bin/curl"
}

# --------------------------------------------------------------------------

# Structural: a step that calls the helpers must also source them. Sourcing is
# per-step (each composite step is a fresh shell), so this is easy to forget in
# a step added later, and the omission only shows up as a live CI failure.
t_every_helper_step_sources_lib() {
  local missing
  missing="$(ACTION="$ACTION" python3 - <<'PY'
import os, re, yaml
d = yaml.safe_load(open(os.environ["ACTION"]))
bad = []
for st in d["runs"]["steps"]:
    body = st.get("run", "")
    uses = re.search(r"\bgt_(fetch|retry)\b", body)
    srcs = "lib/net.sh" in body
    if uses and not srcs:
        bad.append(st["name"])
    # A direct curl anywhere in this action is the bug this all exists to stop.
    if re.search(r"^\s*curl\b", body, re.M):
        bad.append(st["name"] + " (calls curl directly)")
print("\n".join(bad))
PY
)"
  [[ -z "$missing" ]] || no "steps not routed through lib/net.sh: ${missing}"
}

# THE regression, at the level that actually failed: the real step body must
# survive the two resets that took run 33363027898 down.
t_binstall_step_survives_resets() {
  new_sandbox
  stub_cargo
  stub_curl_reset_then_ok 2
  local body; body="$(step_body "Install cargo-binstall")" || no "could not extract step"
  echo "$body" > "${SANDBOX}/step.sh"
  bash "${SANDBOX}/step.sh" >"${SANDBOX}/log" 2>&1 \
    || no "step failed: $(tail -3 "${SANDBOX}/log")"
  [[ "$(attempts)" == "3" ]] || no "made $(attempts) fetch attempts, want 3"
  [[ -x "${SANDBOX}/bin/cargo-binstall" ]] || no "cargo-binstall was never installed"
}

# A step that swallowed a total outage would be worse than the bug: the job
# would fail later, somewhere unrelated.
t_binstall_step_fails_on_total_outage() {
  new_sandbox
  stub_cargo
  stub_curl_always_reset
  local body; body="$(step_body "Install cargo-binstall")" || no "could not extract step"
  echo "$body" > "${SANDBOX}/step.sh"
  ! bash "${SANDBOX}/step.sh" >"${SANDBOX}/log" 2>&1 || no "step reported success"
  (( $(attempts) > 1 )) || no "gave up after $(attempts) attempt(s); retries not wired"
}

# The installer must never be piped into a shell: a truncated body would run.
t_binstall_step_does_not_pipe_into_shell() {
  local body; body="$(step_body "Install cargo-binstall" | join_continuations)" || no "could not extract step"
  if grep -Eq 'curl[^|]*\|[[:space:]]*(bash|sh)\b' <<<"$body"; then
    no "step pipes a download straight into a shell"
  fi
}

t_rust_step_does_not_pipe_into_shell() {
  local body; body="$(step_body "Bootstrap Rust" | join_continuations)" || no "could not extract step"
  if grep -Eq 'curl[^|]*\|[[:space:]]*(bash|sh)\b' <<<"$body"; then
    no "step pipes a download straight into a shell"
  fi
}

echo "setup-greentic action"
run_test "every helper-using step sources lib/net.sh" t_every_helper_step_sources_lib
run_test "cargo-binstall step survives transient resets" t_binstall_step_survives_resets
run_test "cargo-binstall step still fails on a total outage" t_binstall_step_fails_on_total_outage
run_test "cargo-binstall step never pipes a download into a shell" t_binstall_step_does_not_pipe_into_shell
run_test "rust bootstrap never pipes a download into a shell" t_rust_step_does_not_pipe_into_shell

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
