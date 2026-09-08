# shellcheck shell=bash
#
# Bounded retry for the one failure that takes a provider-e2e job down while
# nothing is actually wrong: `gtc wizard` resolving a provider pack from
# ghcr.io.
#
# Sourced by the wizard-running steps as
#   . scripts/wizard_pack_retry.sh
# and exercised by scripts/test_wizard_pack_retry.sh.
#
# Why this exists: `gtc wizard` hands its answers to `greentic-bundle wizard
# apply`, which pulls every `oci://` provider in the bundle — one manifest GET
# plus one blob GET each, all-or-nothing, with no retry of its own. On
# 2026-09-08 (run 34189156283) the messaging-teams leg lost the whole job to a
# single failed resolve of
# `oci://ghcr.io/greenticai/packs/messaging/messaging-teams:latest`, 0.4s in.
# That artifact had not been republished since 2026-07-08, the same ref
# resolved in the same job the night before, the five sibling messaging legs
# pulled from the same registry minutes either side, and it pulls anonymously
# today. A registry hiccup, not a broken pack — the third one this week, after
# the tenant install's truncated body (#111) and the public install's refused
# pull (#112).
#
# Only the pack-resolution phase is retried. Everything else `gtc wizard` can
# fail at — a malformed answers file, a schema rejection, a squashfs error — is
# deterministic, and retrying it would only make the same verdict arrive three
# times slower.
#
# The predicate has to match on `greentic-bundle`'s own context line, because
# that binary prints the anyhow error with `{err}` rather than `{err:#}` and so
# drops every cause: the registry's status code never reaches the job log at
# all. So a genuinely absent tag matches this predicate too, and costs 15s of
# backoff before it fails with the message it would have failed with anyway.
# That is the price of the missing cause chain, and it is worth paying until
# greentic-bundle prints one; a retry that could not fire without it would
# leave a whole matrix leg red for a hiccup.

# Attempts and backoff. Tests set GTC_WIZARD_RETRY_BASE_DELAY=0 to keep the
# suite fast; nothing in CI should override these.
GTC_WIZARD_RETRY_ATTEMPTS="${GTC_WIZARD_RETRY_ATTEMPTS:-3}"
GTC_WIZARD_RETRY_BASE_DELAY="${GTC_WIZARD_RETRY_BASE_DELAY:-5}"

# gtc_wizard_with_pack_retry [args...]
#
# Runs `gtc wizard "$@"`, retrying only a failed OCI pack resolve. The wizard's
# own output is echoed on every attempt, successful or not, so a failure still
# reads in the job log exactly as it did before this wrapper existed.
#
# Retrying is safe because the resolve happens before the wizard writes the
# bundle: the failing run produced `[1/1] Resolving provider: …` and nothing
# else. If a later change moved the write ahead of the pull, a second attempt
# would fail on the half-written bundle with a NEW message — which this
# predicate does not match, so it would be reported rather than retried.
gtc_wizard_with_pack_retry() {
  local log attempt status delay
  log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gtc-wizard.XXXXXX")"

  attempt=1
  while true; do
    status=0
    gtc wizard "$@" >"$log" 2>&1 || status=$?
    cat "$log"

    if [ "$status" -eq 0 ]; then
      rm -f "$log"
      return 0
    fi

    if ! grep -q 'resolve OCI pack ref ' "$log"; then
      break
    fi

    if [ "$attempt" -ge "$GTC_WIZARD_RETRY_ATTEMPTS" ]; then
      echo "::warning::gtc wizard still could not resolve a provider pack after ${GTC_WIZARD_RETRY_ATTEMPTS} attempts — reporting the failure rather than muting it."
      break
    fi

    delay=$(( attempt * GTC_WIZARD_RETRY_BASE_DELAY ))
    echo "::warning::gtc wizard could not resolve a provider pack from the registry; retrying in ${delay}s (attempt ${attempt}/${GTC_WIZARD_RETRY_ATTEMPTS})."
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done

  rm -f "$log"
  return "$status"
}
