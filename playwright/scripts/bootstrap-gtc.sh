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

run_gtc_install() {
  local bin="$1"
  echo "[bootstrap] running '$bin install' (also exercises Maarten's Fix 1)"
  "$bin" install
}

# Best-effort cleanup of any prior runner before we start
pkill -f greentic-runner 2>/dev/null || true

ensure_rust

case "$channel" in
  stable)
    install_stable
    run_gtc_install "$HOME/.cargo/bin/gtc-stable"
    ;;
  dev)
    install_dev
    run_gtc_install "$HOME/.cargo/bin/gtc-dev"
    ;;
  both)
    install_stable
    install_dev
    run_gtc_install "$HOME/.cargo/bin/gtc-stable"
    run_gtc_install "$HOME/.cargo/bin/gtc-dev"
    ;;
  *)
    echo "::error::unknown channel: $channel" >&2
    exit 2
    ;;
esac

echo "[bootstrap] done"
