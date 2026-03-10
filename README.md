# greentic-e2e

Nightly End-to-End tests for the Greentic CLI (`gtc`).

## Purpose
This repository automates the validation of `gtc` installation and initialization across several platforms:
- Linux (x64 and ARM64)
- macOS (Apple Silicon)
- Windows (x64)

## Key Tests
1.  **Installation**: Verifies `cargo binstall` of `greentic-dev`.
2.  **Tool Sync**: Runs `gtc install tools --latest` to ensure all delegated tools (flow, pack, runner, etc.) are available.
3.  **Tenant Setup**: Tests `gtc install --tenant` for isolated environment initialization.
4.  **Artifact Verification**: Checks if libraries, commercial components, and documentation are correctly placed in the `~/.greentic` directory.

## Maintenance
The workflow runs automatically every night at midnight. It can also be triggered manually via the "Actions" tab.