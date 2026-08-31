# shellcheck shell=bash
#
# Bounded retries for the network fetches in the setup-greentic action.
#
# Sourced by the action's steps as
#   . "${{ github.action_path }}/lib/net.sh"
# and exercised by scripts/test_setup_greentic_net.sh.
#
# Why this exists: every step in this action reaches the network, and each one
# of them is a single point of failure for a whole matrix job. Run 33363027898
# lost `tenant-binding` 53ms into `Install cargo-binstall` to
# `curl: (35) Recv failure: Connection reset by peer` while the two sibling jobs
# fetched the same url seconds either side and passed. The url was fine; the
# step just ran it once.
#
# Note the asymmetry that made this worth centralising rather than patching the
# one line: `gtc install` in this same action already had a 3-attempt loop, and
# cargo-binstall's own installer fetches its tarball with `curl --retry 10`.
# Both ends of the chain retried. Only our fetch of the installer did not.
#
# Retries live in bash rather than in `curl --retry-all-errors` so the behaviour
# does not depend on the runner's curl version, and so the same helper can wrap
# non-curl network commands (`cargo binstall`).

# Attempts and backoff. Tests set GT_RETRY_BASE_DELAY=0 to keep the suite fast;
# nothing in CI should override these.
GT_RETRY_ATTEMPTS="${GT_RETRY_ATTEMPTS:-4}"
GT_RETRY_BASE_DELAY="${GT_RETRY_BASE_DELAY:-5}"

# gt_retry <label> <command> [args...]
#
# Runs the command until it succeeds or the attempt budget is spent. Backoff is
# linear (base, 2*base, 3*base) — a transient reset clears in seconds, and an
# outage that does not is better surfaced as a failed job than waited out inside
# a 25-minute timeout.
gt_retry() {
  local label="$1"
  shift

  local attempt=1
  local delay
  while true; do
    if "$@"; then
      return 0
    fi

    if (( attempt >= GT_RETRY_ATTEMPTS )); then
      echo "${label}: failed after ${GT_RETRY_ATTEMPTS} attempts" >&2
      return 1
    fi

    delay=$(( attempt * GT_RETRY_BASE_DELAY ))
    echo "${label}: attempt ${attempt}/${GT_RETRY_ATTEMPTS} failed; retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

# gt_fetch <url> <dest>
#
# Downloads a url to dest, retrying transient failures.
#
# The download lands on a scratch path and is only moved to dest once curl has
# exited 0 AND the body is non-empty, so dest is never a partial file. That
# matters more than the retry: the call site this replaces was
#
#     curl ... https://.../install-from-binstall-release.sh | bash
#
# which hands bash whatever bytes arrived before a reset. A truncated installer
# does not fail at the pipe — it runs, half-installs, and fails later somewhere
# with no connection to the network blip that caused it. Piping a download into
# a shell has no way to check what it is about to execute; writing a file first
# does.
gt_fetch() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.partial"

  # shellcheck disable=SC2317  # run indirectly, via gt_retry below
  _gt_fetch_once() {
    rm -f "$tmp"
    # --fail so an HTTP error page is never mistaken for the payload.
    # --connect-timeout/--max-time so a hung connection cannot eat the job's
    # whole timeout budget before the first retry is even considered.
    if ! curl --proto '=https' --tlsv1.2 \
        --fail --location --silent --show-error \
        --connect-timeout 20 --max-time 180 \
        -o "$tmp" "$url"; then
      rm -f "$tmp"
      return 1
    fi
    if [[ ! -s "$tmp" ]]; then
      echo "gt_fetch: ${url} returned an empty body" >&2
      rm -f "$tmp"
      return 1
    fi
    mv "$tmp" "$dest"
  }

  gt_retry "fetch ${url}" _gt_fetch_once
}
