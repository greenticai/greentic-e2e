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

# Workaround for greentic-repo bug: when invoked as `gtc-dev`, the gtc
# binary rewrites companion binary names to a `-dev` suffix (see
# `companion_binary_for_invocation` in greentic/src/bin/gtc/process.rs).
# But `gtc install` installs companions with their canonical names
# (`greentic-deployer`, not `greentic-deployer-dev`), so the post-install
# `ensure_deployer_dist_pack` step fails with ENOENT when it tries to
# spawn `greentic-deployer-dev`. Symlink the canonical names to
# `<name>-dev` so the dev gtc resolves them. Stable is unaffected.
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
