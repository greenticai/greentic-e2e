#!/usr/bin/env bash
# playwright/scripts/bootstrap-gtc.sh
# Install gtc per channel for the Playwright e2e suite.
# Usage: bootstrap-gtc.sh stable|dev|both
set -euo pipefail

channel="${1:?usage: bootstrap-gtc.sh stable|dev|both}"

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "::error::cargo not found. Install Rust 1.95.0 first." >&2
    exit 1
  fi
  if ! rustup target list --installed | grep -q wasm32-wasip2; then
    rustup target add wasm32-wasip2
  fi
}

install_stable() {
  echo "[bootstrap] installing stable gtc via cargo binstall"
  if ! command -v cargo-binstall >/dev/null 2>&1; then
    cargo install cargo-binstall --locked
  fi
  cargo binstall -y gtc
  if [[ "$(realpath "$HOME/.cargo/bin/gtc-stable" 2>/dev/null || true)" != "$(realpath "$HOME/.cargo/bin/gtc")" ]]; then
    cp "$HOME/.cargo/bin/gtc" "$HOME/.cargo/bin/gtc-stable"
  fi
  "$HOME/.cargo/bin/gtc-stable" --version
}

install_dev() {
  echo "[bootstrap] installing dev gtc via cargo install --git main"
  cargo install \
    --git https://github.com/greenticai/greentic.git \
    --branch main \
    --locked \
    --bin gtc \
    --root "$HOME/.cargo" \
    gtc
  # cargo install drops the binary at $HOME/.cargo/bin/gtc — rename so it
  # coexists with stable.
  mv "$HOME/.cargo/bin/gtc" "$HOME/.cargo/bin/gtc-dev"
  "$HOME/.cargo/bin/gtc-dev" --version
}

# Stable toolchain release. Pinned to the newest release the demos actually
# pass on. TEMPORARY — remove once greenticai/greentic#289 is fixed.
#
# Measured, one release per run, everything else held constant:
#
#   1.1.2   12 passed, 0 failed   <- newest good
#   1.1.7    4 passed, 9 failed
#   1.1.10   4 passed, 9 failed
#   1.1.13   9 passed, 3 failed   (what `unpinned` resolves to today)
#
# It is not monotonic — 1.1.7/1.1.10 break more than 1.1.13 — so this is not one
# regression that landed and stuck. The window cannot be narrowed further:
# 1.1.3/1.1.4/1.1.6/1.1.11/1.1.12 are GitHub release tags with NO toolchain
# manifest in GHCR, so `gtc install --release` 404s on them.
#
# A previous attempt unpinned this, reading the `release context is not
# installed` warning as the cause. That warning is present in the runs where the
# demos PASS, so it does not correlate; unpinning only advanced the toolchain
# 1.1.2 -> 1.1.13 and moved pet-daycare from green to red.
#
# Pinning here rather than leaving the suite red is deliberate: it was red for
# five straight runs, and a second regression (pet-daycare) landed inside that
# red and went unnoticed. A permanently-red suite cannot report anything new.
# The regression itself is not lost — it is captured in #289 with a repro.
#
# Set GTC_RELEASE (or the workflow's `gtc_release` input) to override.
GTC_RELEASE="${GTC_RELEASE:-1.1.2}"

run_gtc_install() {
  local bin="$1"
  if [[ -n "${GTC_RELEASE}" ]]; then
    echo "[bootstrap] running '$bin install --force --release ${GTC_RELEASE}'"
    "$bin" install --force --release "${GTC_RELEASE}"
  else
    echo "[bootstrap] running '$bin install --force' (unpinned — current default stable toolchain)"
    "$bin" install --force
  fi
}

# Companion-binary symlinking for the dev channel.
#
# Two scenarios are handled, depending on what `gtc-dev install` actually
# put on disk:
#
# 1. Legacy (pre binary-bifurcation): `gtc install` placed companions under
#    their canonical names (`greentic-deployer`, etc.), but `gtc-dev`'s
#    `companion_binary_for_invocation` looks them up with a `-dev` suffix.
#    Fix: symlink `<name>-dev → <name>`.
#
# 2. Post binary-bifurcation (dev lane on crates.io, ~2026-04-24): `gtc-dev
#    install` installs `<name>-dev` directly (e.g., `greentic-secrets-dev`)
#    and no canonical-name binary exists. But the Playwright fixtures spawn
#    canonical names — `gtc` (which in turn execs its own companions) and
#    `greentic-secrets` — see playwright/tests/_fixtures/gtc-demo.ts.
#    Fix: symlink `<name> → <name>-dev`.
#
# Stable is unaffected — `gtc install --channel stable` puts canonical names
# on disk and Playwright's spawn calls resolve them directly.
link_dev_companions() {
  local bin_dir="$HOME/.cargo/bin"
  local companions=(
    greentic-bundle
    greentic-component
    greentic-deployer
    greentic-dev
    greentic-flow
    greentic-gui
    greentic-mcp
    greentic-operator
    greentic-pack
    greentic-runner
    greentic-secrets
    greentic-setup
    greentic-start
  )
  for name in "${companions[@]}"; do
    if [[ -x "$bin_dir/$name" && ! -e "$bin_dir/$name-dev" ]]; then
      ln -s "$bin_dir/$name" "$bin_dir/$name-dev"
    fi
    if [[ -x "$bin_dir/$name-dev" && ! -e "$bin_dir/$name" ]]; then
      ln -s "$bin_dir/$name-dev" "$bin_dir/$name"
    fi
  done
}

# Best-effort cleanup of any prior runner before we start
pkill -f greentic-runner 2>/dev/null || true

ensure_rust

# The first `gtc-dev install` invocation installs every companion binary
# but crashes at the final `ensure_deployer_dist_pack` step (it tries to
# spawn `greentic-deployer-dev`, which does not exist yet). We let that
# first attempt fail intentionally, then create the `-dev` symlinks for
# all companions, then re-run `gtc install` — cargo binstall skips
# already-installed packages so the second run is fast and reaches the
# dist-pack step with the symlink in place.
run_gtc_install_dev() {
  local bin="$1"
  echo "[bootstrap] running '$bin install --channel dev' (first pass — companions)"
  set +e
  "$bin" install --channel dev
  set -e
  link_dev_companions
  echo "[bootstrap] running '$bin install --channel dev' (second pass — dist pack)"
  "$bin" install --channel dev
}

case "$channel" in
  stable)
    install_stable
    run_gtc_install "$HOME/.cargo/bin/gtc-stable"
    ;;
  dev)
    install_dev
    run_gtc_install_dev "$HOME/.cargo/bin/gtc-dev"
    ;;
  both)
    install_stable
    install_dev
    run_gtc_install "$HOME/.cargo/bin/gtc-stable"
    run_gtc_install_dev "$HOME/.cargo/bin/gtc-dev"
    ;;
  *)
    echo "::error::unknown channel: $channel" >&2
    exit 2
    ;;
esac

echo "[bootstrap] done"
