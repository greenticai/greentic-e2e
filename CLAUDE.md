# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

End-to-end tests for the Greentic CLI (`gtc`) covering:
1. **Nightly Tests** - Installation and initialization across platforms
2. **Provider E2E Tests** - Full lifecycle for all messaging and event providers

## Quick Start

```bash
# Run dummy provider tests locally (no credentials needed)
./scripts/run_provider_e2e.sh

# Run with specific provider
./scripts/run_provider_e2e.sh --scope messaging --verbose
```

## Running Tests

### Local Provider Tests

```bash
# Full test (dummy providers only)
./scripts/run_provider_e2e.sh

# Options
./scripts/run_provider_e2e.sh --scope messaging    # messaging only
./scripts/run_provider_e2e.sh --scope events       # events only
./scripts/run_provider_e2e.sh --skip-wizard        # skip wizard step
./scripts/run_provider_e2e.sh --skip-setup         # skip setup step
./scripts/run_provider_e2e.sh --keep-running       # don't stop services
./scripts/run_provider_e2e.sh --bundle /path       # use existing bundle
./scripts/run_provider_e2e.sh --verbose            # verbose output
```

### Nightly Tests (with Docker/Act)

```bash
# Prerequisites: Docker + .secrets file
./ci/run_actions.sh
ACT_MATRIX_ARCH=arm64 ./ci/run_actions.sh
```

## Repository Structure

```
.github/workflows/
  nightly-e2e.yml           # Installation tests (midnight UTC)
  provider-e2e.yml          # Provider lifecycle tests (00:30 UTC)

scripts/
  run_provider_e2e.sh       # Local provider test runner

fixtures/
  setup-answers/            # Setup answers for each provider
    messaging-telegram.json
    messaging-slack.json
    messaging-teams.json
    messaging-webex.json
    messaging-whatsapp.json
    messaging-email.json
    messaging-webchat.json
    messaging-dummy.json
    events-webhook.json
    events-timer.json
    events-email-sendgrid.json
    events-sms-twilio.json
    events-dummy.json
    all-messaging.json      # Combined messaging
    all-events.json         # Combined events
    all-providers.json      # All providers

ci/
  run_actions.sh            # Local nightly test runner
```

## Provider Configuration

### Messaging Providers

| Provider | Required Secrets | Setup Complexity |
|----------|------------------|------------------|
| `messaging-dummy` | None | Low |
| `messaging-telegram` | `TELEGRAM_BOT_TOKEN` | Low |
| `messaging-slack` | `SLACK_BOT_TOKEN`, `SLACK_APP_ID` | Medium |
| `messaging-teams` | `MS_BOT_APP_ID`, `MS_BOT_APP_PASSWORD` | Medium |
| `messaging-webex` | `WEBEX_BOT_TOKEN` | Low |
| `messaging-whatsapp` | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_VERIFY_TOKEN` | High |
| `messaging-email` | `GRAPH_TENANT_ID`, `MS_GRAPH_CLIENT_ID`, `MS_GRAPH_CLIENT_SECRET` | High |
| `messaging-webchat-gui` | `WEBCHAT_JWT_SIGNING_KEY` | Medium |

### Event Providers

| Provider | Required Secrets | Setup Complexity |
|----------|------------------|------------------|
| `events-dummy` | None | Low |
| `events-webhook` | None | Low |
| `events-timer` | None | Low |
| `events-email-sendgrid` | `SENDGRID_API_KEY` | Medium |
| `events-sms-twilio` | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` | Medium |

## Test Flow

```
gtc wizard → gtc setup --answers → gtc start → verify → stop
```

Each provider test validates:
1. Bundle creation (with provider pack reference)
2. Provider setup (using answers file)
3. Service startup (with `--cloudflared off --ngrok off`)
4. Service verification (PID files, log indicators)
5. Graceful shutdown

## Secrets Setup

### GitHub Actions

Add these secrets to your repository:

```
# General
PUBLIC_BASE_URL           # Set dynamically by ngrok
NGROK_AUTHTOKEN           # ngrok auth token

# Telegram
TELEGRAM_BOT_TOKEN

# Slack
SLACK_BOT_TOKEN
SLACK_APP_ID
SLACK_CONFIGURATION_TOKEN

# Teams
MS_BOT_APP_ID
MS_BOT_APP_PASSWORD

# Webex
WEBEX_BOT_TOKEN

# WhatsApp
WHATSAPP_PHONE_NUMBER_ID
WHATSAPP_TOKEN
WHATSAPP_VERIFY_TOKEN

# Email
EMAIL_FROM_ADDRESS
GRAPH_TENANT_ID
MS_GRAPH_CLIENT_ID
MS_GRAPH_CLIENT_SECRET

# WebChat
WEBCHAT_JWT_SIGNING_KEY

# SendGrid
SENDGRID_API_KEY
SENDGRID_FROM_EMAIL

# Twilio
TWILIO_ACCOUNT_SID
TWILIO_AUTH_TOKEN
TWILIO_FROM_NUMBER
```

### Local Testing

Copy `.secrets-providers.example` to `.secrets-providers` and fill in values:

```bash
cp .secrets-providers.example .secrets-providers
# Edit .secrets-providers with your credentials
```

## GTC Commands Tested

| Command | Purpose |
|---------|---------|
| `gtc install` | Install public tools |
| `gtc install --tenant` | Install tenant tools |
| `gtc doctor` | Health check |
| `gtc wizard` | Create bundles |
| `gtc wizard --emit-answers` | Export wizard answers |
| `gtc wizard apply --answers` | Apply saved answers |
| `gtc setup --answers` | Configure providers |
| `gtc start` | Start runtime services |

## CI/CD

| Workflow | Schedule | Scope |
|----------|----------|-------|
| `nightly-e2e.yml` | 00:00 UTC | Installation + wizard |
| `provider-e2e.yml` | 00:30 UTC | Provider lifecycle |

### Manual Trigger

```yaml
# provider-e2e.yml inputs:
gtc_version: latest | x.y.z
provider_scope: dummy | messaging | events | all
```

## Adding New Provider Tests

1. Create fixture: `fixtures/setup-answers/<provider>.json`
2. Add to workflow matrix in `provider-e2e.yml`
3. Add required secrets check
4. Update `.secrets-providers.example`

Example fixture format:
```json
{
  "<provider-name>": {
    "enabled": true,
    "public_base_url": "${PUBLIC_BASE_URL}",
    "secret_field": "${SECRET_ENV_VAR}"
  }
}
```

## Troubleshooting

### Services fail to start
- Check `~/.greentic/state/` for PID files
- Check logs in test output
- Verify gtc version: `gtc --version`

### Setup fails
- Verify secrets are set correctly
- Check answers file format matches provider schema
- Run `gtc setup --help` for available options

### Missing provider pack
- Run `gtc install` to ensure packs are available
- Check OCI registry connectivity
