#!/usr/bin/env bash
# playwright/scripts/bootstrap-gtc.sh
# Install gtc per channel for the Playwright e2e suite.
# Usage: bootstrap-gtc.sh stable|dev|both
#
# The "stable" channel pins to a specific toolchain release via
# `gtc install --force --release ${GTC_RELEASE}`. We can't rely on the
# stable cargo binstall channel alone because the underlying toolchain
# release context can drift behind the binary version.
set -euo pipefail

channel="${1:?usage: bootstrap-gtc.sh stable|dev|both}"
GTC_RELEASE="${GTC_RELEASE:-1.0.17}"

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

run_gtc_install() {
  local bin="$1"
  echo "[bootstrap] running '$bin install --force --release $GTC_RELEASE'"
  "$bin" install --force --release "$GTC_RELEASE"
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
#    canonical names (`greentic-secrets`, `greentic-start`) — see
#    playwright/tests/_fixtures/gtc-demo.ts.
#    Fix: symlink `<name> → <name>-dev`.
#
# Stable is unaffected — `gtc install --release` puts canonical names on
# disk and Playwright's spawn calls resolve them directly.
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
  echo "[bootstrap] running '$bin install' (first pass — companions)"
  set +e
  "$bin" install
  set -e
  link_dev_companions
  echo "[bootstrap] running '$bin install' (second pass — dist pack)"
  "$bin" install
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
