# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

End-to-end tests for the Greentic CLI (`gtc`). Two test suites run nightly via GitHub Actions:

1. **Nightly Install/Wizard** (`nightly-e2e.yml`, 00:00 UTC) - Tests `gtc install`, `gtc doctor`, and `gtc wizard` across 6 platform/arch combos (Linux x64/arm64, macOS arm64/x64, Windows x64/arm64). Uses `expect` scripts for interactive wizard testing.
2. **Provider E2E** (`provider-e2e.yml`, 00:30 UTC) - Full provider lifecycle: bundle creation, setup, start, HTTP ingress verification, and shutdown. Tests all messaging and event providers.
3. **Cloud Demo E2E** (`cloud-demo-e2e.yml`, 02:00 UTC) - AWS demo lifecycle: `gtc wizard`, `gtc setup`, `gtc start --target aws`, web UI verification, optional admin tunnel verification, and `gtc stop --destroy`.

## Running Tests

### Local Provider Tests

```bash
# Dummy providers only (no credentials needed)
./scripts/run_provider_e2e.sh

# AWS cloud demo lifecycle
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
AWS_REGION=eu-north-1 \
AWS_DEFAULT_REGION=eu-north-1 \
./scripts/run_cloud_demo_e2e.sh --release-version v0.1.24

# Specific scope
./scripts/run_provider_e2e.sh --scope messaging
./scripts/run_provider_e2e.sh --scope events
./scripts/run_provider_e2e.sh --scope all

# Single provider
./scripts/run_provider_e2e.sh --provider messaging-telegram

# Other options
./scripts/run_provider_e2e.sh --skip-setup          # skip gtc setup step
./scripts/run_provider_e2e.sh --skip-start          # skip gtc start + ingress tests
./scripts/run_provider_e2e.sh --keep-running         # don't stop services after test
./scripts/run_provider_e2e.sh --bundle /path          # use existing bundle directory
./scripts/run_provider_e2e.sh --dry-run              # validate without running gtc
./scripts/run_provider_e2e.sh --verbose              # verbose output
```

Requires `gtc` CLI installed (`cargo binstall gtc`). For providers with secrets, copy `.secrets-provider.example` to `.secrets-provider` and fill in values.

### Nightly Tests Locally (Docker/Act)

```bash
# Prerequisites: Docker + .secrets-provider with GREENTIC_TENANT_TOKEN
./ci/run_actions.sh
ACT_MATRIX_ARCH=arm64 ./ci/run_actions.sh
```

## Architecture

### Test Flow

```
gtc wizard -> gtc setup --answers <file> <bundle_dir> -> gtc start <bundle_dir> --cloudflared off --ngrok off -> HTTP ingress test -> stop
```

Cloud demo flow under development:

```
gtc wizard -> gtc setup -> gtc start <bundle_dir> --target aws
-> GET /readyz -> GET /v1/web/webchat/demo/
-> gtc admin tunnel --target aws -> GET /admin/v1/health
-> add/remove admin CN -> gtc stop --destroy
```

Nightly/manual workflow keeps admin checks opt-in until the released `gtc` artifact includes `gtc admin tunnel`.

Provider tests accept 2xx-4xx HTTP responses as passing (provider processed the request). Only 5xx or connection failures count as errors.

### Fixture System

**Setup answers** (`fixtures/setup-answers/<provider>.json`) - JSON files with provider config. Environment variables are substituted at runtime using `envsubst`. Example:
```json
{
  "messaging-telegram": {
    "enabled": true,
    "telegram_bot_token": "${TELEGRAM_BOT_TOKEN}"
  }
}
```

The local test runner merges multiple fixture files via a Python script when testing multiple providers.

**Wizard fixtures** (`fixtures/wizard/`) - `expect` scripts that drive interactive wizard tests:
- `e2e.env` - shared wizard input variables (pack ID, bundle name)
- `traversal.expect` - interactive wizard traversal test
- `emit_answers.expect` - tests `gtc wizard --emit-answers`
- `replay-answers.template.json` - template with `__PLACEHOLDER__` tokens replaced at runtime

### Bundle Config

Bundles are YAML files (`greentic.demo.yaml`) that declare providers with OCI pack references:
```yaml
providers:
  messaging:
    messaging-dummy:
      pack: "oci://ghcr.io/greentic-biz/packs/messaging-dummy:latest"
  events:
    events-dummy:
      pack: "oci://ghcr.io/greentic-biz/packs/events-dummy:latest"
```

### HTTP Ingress Endpoints

Services listen on `http://127.0.0.1:8080`. Ingress pattern:
- Messaging: `POST /v1/messaging/ingress/<provider>/demo/default`
- Events: `POST /v1/events/ingress/<provider>/demo/default`

Exception: `events-timer` has no HTTP ingress (schedule-based); verified via log inspection.

### Providers

| Provider | Secrets Required |
|----------|-----------------|
| `messaging-dummy` | None |
| `messaging-telegram` | `TELEGRAM_BOT_TOKEN` |
| `messaging-slack` | `SLACK_BOT_TOKEN`, `SLACK_APP_ID` |
| `messaging-teams` | `MS_BOT_APP_ID`, `MS_BOT_APP_PASSWORD` |
| `messaging-webex` | `WEBEX_BOT_TOKEN` |
| `messaging-whatsapp` | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` |
| `messaging-email` | `MS_GRAPH_CLIENT_ID`, `MS_GRAPH_CLIENT_SECRET`, `GRAPH_TENANT_ID` |
| `messaging-webchat-gui` | `WEBCHAT_JWT_SIGNING_KEY` |
| `events-dummy` | None |
| `events-webhook` | None |
| `events-timer` | None |
| `events-email-sendgrid` | `SENDGRID_API_KEY` |
| `events-sms-twilio` | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` |

Full list of all secret env vars is in `.secrets-provider.example`.

## Adding a New Provider Test

1. Create `fixtures/setup-answers/<provider>.json` (use `${ENV_VAR}` for secrets)
2. Add provider to the workflow matrix in `provider-e2e.yml`
3. Add secrets check in the workflow's "Check required secrets" step
4. Add test payload in `get_test_payload()` in `scripts/run_provider_e2e.sh`
5. Update `.secrets-provider.example` with any new env vars

## Key Scripts

- `scripts/run_provider_e2e.sh` - Main local test runner. Uses Perl for cross-platform timeout handling. Cleanup trap kills `greentic-runner` and `nats-server` processes.
- `scripts/run_cloud_demo_e2e.sh` - AWS cloud demo lifecycle harness. Verifies published `greentic-demo` release assets, web UI route, and optional admin tunnel flow.
- `ci/run_actions.sh` - Runs nightly workflow locally via [nektos/act](https://github.com/nektos/act). Auto-installs `act` to `.bin/`. Resolves Docker host for both macOS (Docker Desktop) and Linux.
