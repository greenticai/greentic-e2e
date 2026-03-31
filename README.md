# greentic-e2e

Nightly End-to-End tests for the Greentic CLI (`gtc`).

## Purpose
This repository automates the validation of `gtc` installation and initialization across several platforms:
- Linux (x64 and ARM64)
- macOS 15 (Apple Silicon and Intel)
- Windows (x64 and ARM64)

## Key Tests
1.  **Installation**: Verifies `cargo binstall` of `greentic-dev`.
2.  **Tool Sync**: Runs `gtc install tools --latest` to ensure all delegated tools (flow, pack, runner, etc.) are available.
3.  **Tenant Setup**: Tests `gtc install --tenant` for isolated environment initialization, using the credential flag supported by the installed `gtc` version. This step is required and fails the job if the tenant token is missing or invalid.
4.  **Artifact Verification**: Checks if libraries, commercial components, and documentation are correctly placed in the `~/.greentic` directory.
5.  **Provider Lifecycle**: Verifies `wizard -> setup -> start -> ingress -> stop` for provider bundles.
6.  **Cloud Demo Lifecycle**: Work in progress harness for `wizard -> setup -> start --target aws -> web UI -> admin tunnel -> stop --destroy`.

## Local Scripts

Provider lifecycle:
```bash
./scripts/run_provider_e2e.sh
```

AWS cloud demo lifecycle:
```bash
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
./scripts/run_cloud_demo_e2e.sh --release-version v0.1.24
```

Optional overrides:
```bash
export AWS_REGION='eu-north-1'
export AWS_DEFAULT_REGION='eu-north-1'
export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND='s3'
```

Defaults:
- AWS region defaults to `eu-north-1`
- Terraform remote state backend defaults to `s3`
- Only `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are required exports for the local script unless you want to override those defaults.

GitHub Actions:
- `Nightly e2e gtc install/wizard`
- `Provider E2E Tests`
- `Cloud Demo E2E` for the AWS demo lifecycle

Notes:
- `Cloud Demo E2E` runs web UI validation by default.
- Admin tunnel checks are opt-in in GitHub Actions until the released `gtc` line includes `gtc admin tunnel`.

## Maintenance
The workflow runs automatically every night at midnight. It can also be triggered manually via the "Actions" tab.
