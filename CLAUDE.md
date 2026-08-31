# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

End-to-end tests for the Greentic CLI (`gtc`). This repo contains **no Rust code** — tests are pure Bash scripts, Python (pty-based wizard drivers), and TypeScript (Playwright). There is no `Cargo.toml` or `rust-toolchain.toml`.

Twelve workflows run nightly, on push/PR, or on demand via GitHub Actions:

1. **Nightly Install/Wizard** (`nightly-e2e.yml`, 00:00 UTC) - Tests `gtc install`, `gtc doctor`, and `gtc wizard` across 6 platform/arch combos (Linux x64/arm64, macOS arm64/x64, Windows x64/arm64). Uses `expect` scripts for interactive wizard testing.

   **`Run gtc tenant install` soft-skips a fixed list of upstream release-artifact breakages** — things this repo cannot fix, where a red nightly reports someone else's pipeline. Each entry names one exact signature and is removed when that artifact is fixed; the step still emits a `::warning::` naming which one matched, so a muted breakage stays visible in the run summary. Muting is not solving: the greentic-component entry covers a bug that breaks real Windows users of `gtc install --tenant`, not just CI (its `*-pc-windows-msvc.zip` assets are POSIX tar archives — `file` says so, and the `ustar` magic sits at offset 257). The classifier is tested (`scripts/test_nightly_tenant_softskip.sh`), including that it does NOT skip an unrelated failure: the greentic-component entry requires **two** signatures, because the extract failure alone is something cargo-binstall recovers from routinely and matching it by itself would mute any later failure in the same run.
2. **Provider E2E** (`provider-e2e.yml`, 00:30 UTC) - Full provider lifecycle: bundle creation, setup, start, HTTP ingress verification, and shutdown. Tests all messaging and event providers.
3. **Cloud Demo E2E** (`cloud-demo-e2e.yml`, 02:00 UTC) - Cloud demo lifecycle: `gtc wizard`, `gtc setup --non-interactive`, `gtc start --target <aws|azure|gcp>`, web UI verification, optional admin tunnel verification, and `gtc stop --destroy`.
4. **Store Dual-Publish E2E** (`store-dual-publish-e2e.yml`, 01:30 UTC) - Store agentic-worker lifecycle `publish -> install -> run` against real Postgres + MinIO + the store container. Designer side is simulated via curl; verifies the publish/list/detail/artifact/run API contracts, the install-back byte-equality invariant, and the run-from-store admin hand-off. SKIPS (not fails) when the GHCR store image is not pullable.
5. **Telemetry E2E** (`telemetry-e2e.yml`, 01:00 UTC) - Boots a file-export OpenTelemetry Collector, starts a dummy-provider bundle with `TELEMETRY_EXPORT`/`OTLP_ENDPOINT` pointed at it, drives traffic, and asserts the collector's JSON dump contains OTLP **logs** for the configured `service.name`. Requires Docker.
6. **WebChat Passthrough E2E** (`webchat-passthrough-e2e.yml`, 01:00 UTC) - Regression guard for the WebChat DirectLine envelope passthrough contract (attachments / channelData / entities). Runs the full stack against a minimal probe pack. Note: shares the 01:00 UTC slot with Telemetry E2E.
7. **Demo Playwright E2E** (`demo-playwright.yml`, 03:30 UTC) - Browser-driven demo site tests via Playwright. See `playwright/` sub-package.
8. **Notify Scheduled Failures** (`notify-scheduled-failures.yml`) - Alerts on nightly workflow failures.
9. **CodeQL** (`codeql.yml`) - GitHub code scanning.
10. **Shell unit tests** (`shell-tests.yml`, on push/PR) - Bash tests for the shared toolchain bootstrap (`.github/actions/setup-greentic`). Fast, no secrets, no toolchain; the only check that gates a PR here. See "CI toolchain bootstrap" below.
11. **Agentic Worker E2E** (`agentic-e2e.yml`, 01:15 UTC) - Regression guard for the agentic worker (`dw.agent`): boots the tavily agentic demo bundle, drives one Plan-Act-Observe turn over the WebChat DirectLine rail, and asserts the worker returns a real reply. Needs only an LLM key (the `DEEPSEEK_KEY` secret); no Redis — `dw.agent` falls back to in-memory state when `GREENTIC_AW_REDIS_URL` is unset.
12. **Regression Guards E2E** (`regression-guards-e2e.yml`, 00:45 UTC) - Track-A guards for the July 2026 binary incident; three independent jobs (`fail-fast: false`), each pinned to a shipped fix the prior suite missed. (a) **type-only-routing** (greentic-runner #611): a probe pack with two same-`messaging`-type flows (`main` untagged, `internal_helper` tagged `internal`) must resolve a type-only ingress to the entry flow, not bail "flow type X is ambiguous; pack_id is required". (b) **tenant-binding** (greentic-setup #232): `gtc setup env-deploy <archive> --tenant acme` must stamp `route_binding.tenant_selector.tenant=acme` (team `default`, path_prefixes `["/"]`, hosts `[]`) into `~/.greentic/environments/local/environment.json`; pre-fix the key was absent. (c) **webchat-reply-parity** (greentic-start #438): starting the ARCHIVE (`gtc start <archive.gtbundle>`) takes the env/revision serve arm — the guard asserts the log shows that arm AND that a rich reply (adaptive-card attachment + channelData + entities) survives instead of collapsing to the text-only placeholder. The legacy `--bundle` dir arm (which `webchat-passthrough-e2e.yml` exercises) never regressed here, so this drives the archive/env arm specifically. No secrets needed beyond the toolchain.


## Running Tests

### Local Provider Tests

```bash
# Dummy providers only (no credentials needed)
./scripts/run_provider_e2e.sh

# AWS cloud demo lifecycle
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
./scripts/run_cloud_demo_e2e.sh

# Azure cloud demo smoke
export ARM_SUBSCRIPTION_ID='...'
export ARM_TENANT_ID='...'
export ARM_CLIENT_ID='...'
export ARM_CLIENT_SECRET='...'
export GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_KEY_VAULT_ID='...'
export GREENTIC_DEPLOY_BUNDLE_SOURCE='https://github.com/greenticai/greentic-demo/releases/latest/download/cloud-deploy-demo.gtbundle'

# GCP cloud demo smoke
export GOOGLE_APPLICATION_CREDENTIALS='/path/to/gcp-service-account.json'
export GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_PROJECT_ID='x-plateau-483512-p6'
export GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_REGION='us-central1'
export GREENTIC_DEPLOY_BUNDLE_SOURCE='https://github.com/greenticai/greentic-demo/releases/latest/download/cloud-deploy-demo.gtbundle'
./scripts/run_cloud_demo_e2e.sh --target gcp

# Optional overrides
export AWS_REGION='eu-north-1'
export AWS_DEFAULT_REGION='eu-north-1'
export GREENTIC_DEPLOY_TERRAFORM_VAR_REMOTE_STATE_BACKEND='s3'

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

### CI toolchain bootstrap

All workflows share `.github/actions/setup-greentic` (Rust pin, cargo-binstall with authenticated GitHub API lookups, gtc CLI, `gtc install --release <pin> --install-binaries-only`). The pinned Greentic toolchain release lives in that action's `gtc-release` default (and is mirrored in `nightly-e2e.yml`'s `GTC_RELEASE` env and `playwright/scripts/bootstrap-gtc.sh`) — bump those together to roll every workflow forward.

**Every network fetch in that action retries, and none of them pipe a download into a shell.** Both rules live in `.github/actions/setup-greentic/lib/net.sh` (`gt_fetch` / `gt_retry`); a new step that reaches the network belongs behind one of them.

This is a shared single point of failure, and it does not fail in a way that names itself. Run 33363027898 lost `tenant-binding` 53ms into `Install cargo-binstall` on one `curl: (35) Recv failure: Connection reset by peer` — the two sibling matrix jobs pulled the same url seconds either side and passed, so the url was fine; the step simply had no second attempt. It surfaced as "the tenant-binding guard is failing", which is the wrong place to look. Note the asymmetry that let it survive: `gtc install` in that same action already retried, and cargo-binstall's own installer fetches its tarball with `curl --retry 10`. Both ends of the chain retried. Only our fetch of the installer did not.

Fetching to a file rather than `| bash` is the other half, and it guards a worse failure than the one observed: a reset *mid-transfer* hands the shell a truncated installer, which runs, half-installs, and fails later somewhere with no connection to the network blip. A pipe cannot inspect what it is about to execute.

**The Rust pin is load-bearing on Windows only, and must clear its dependency
MSRV.** This repo ships no Rust code, so `rust-version` exists for exactly one
job: source-building a CLI when no prebuilt artifact is usable — in practice the
Windows arm of `Install cargo-binstall`. It sat at 1.95.0 while cargo-binstall
1.22.0 (2026-08-22) pulled vergen 10.0.2, MSRV 1.96.0, and **both Windows jobs
failed every night from 2026-08-23**. Linux and macOS take the prebuilt path and
never invoke rustc, so nothing else in the matrix noticed. `test_setup_greentic_action.sh`
now holds a floor (`MIN_RUST`); raise it and the pin together when a build hits a
higher MSRV.

Bumping the pin does not disturb the wasm fixtures:
`fixtures/packs/*/components/bug3-test/rust-toolchain.toml` pins its own channel
AND declares its own `targets`, so rustup provisions that toolchain plus
wasm32-wasip2 on demand — which is why the guard workflows build those
components with `wasm-target: 'false'`.

Tests (`.github/workflows/shell-tests.yml`, on every PR — the only PR gate in this repo, since the e2e suites are nightly and need a toolchain):

```bash
bash scripts/test_setup_greentic_net.sh          # gt_fetch / gt_retry, stubbed curl
bash scripts/test_setup_greentic_action.sh       # the action's real step bodies + the MSRV floor
bash scripts/test_nightly_tenant_softskip.sh     # the tenant-install soft-skip classifier
```

The second one extracts each step's `run:` block out of `action.yml` and executes it against a stubbed, reset-injecting `curl`. That is deliberate rather than redundant: a step that forgets to source the lib, or calls `curl` directly, passes the unit tests and still dies on the first reset. Both suites are verified against the pre-fix action — all five wiring tests fail on it, with the original error text.

**Binaries only, deliberately.** The unflagged `gtc install` also prefetches every pack and component in the pinned release — 92 ghcr.io blob pulls for 1.1.2 — in one all-or-nothing loop whose skip-list (the release index) is only written after the loop fully succeeds. A single transient blob error therefore fails the job, and the action's retry redoes all 92 pulls. No workflow reads that prefetch: fixtures name their packs by explicit `oci://ghcr.io/...:latest` reference and cache them workspace-local, while the release index only maps the `:stable` channel tag. `nightly-e2e.yml` is where the full `gtc install` is exercised — it passes `install-toolchain: false` here and runs the unflagged install itself.

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
gtc wizard -> gtc setup --non-interactive -> gtc start <bundle_dir> --target <aws|azure|gcp>
-> GET /readyz -> GET /v1/web/webchat/demo/
-> optional gtc admin tunnel --target aws -> GET /admin/v1/health
-> add/remove admin CN -> gtc stop --destroy
```

Nightly/manual workflow keeps admin checks opt-in until the released `gtc` artifact includes `gtc admin tunnel`.
For local runs only `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are required unless you want to override the default region/backend values.
For Azure smoke runs, `azure_location=westeurope` and `remote_state_backend=azurerm` are defaulted; you still need ARM credentials, `GREENTIC_DEPLOY_TERRAFORM_VAR_AZURE_KEY_VAULT_ID`, and `GREENTIC_DEPLOY_BUNDLE_SOURCE`.
For GCP smoke runs, `gcp_region=us-central1` and `remote_state_backend=gcs` are defaulted; you still need `GOOGLE_APPLICATION_CREDENTIALS`, `GREENTIC_DEPLOY_TERRAFORM_VAR_GCP_PROJECT_ID`, and `GREENTIC_DEPLOY_BUNDLE_SOURCE`.

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

**The top-level key must equal the pack's manifest `pack_id`, exactly.** `gtc setup` looks the
pack up by exact string match on that key; a mismatch means it finds no pack and aborts with a
B12a error whose text ("the pack ships no classifiable setup metadata") is misleading — the pack
metadata is fine, the key just didn't match. The two families do not use the same convention:

| Family | `pack_id` convention | Example |
|--------|----------------------|---------|
| Messaging | short name | `messaging-telegram` |
| Events | dotted | `greentic.events.webhook`, `greentic.events.provider.dummy` |

Confirm a pack's id before adding a fixture — `grep pack_id` in the provider repo's
`packs/<name>/pack.yaml` (`greentic-messaging-providers` / `greentic-events-providers`).

**Bundles** (`fixtures/bundles/`) - bundle YAML consumed by provider/passthrough tests.

**Packs** (`fixtures/packs/`) - pre-built pack directories (`demo-app-pack`, `webchat-passthrough-probe`) used as test inputs.

**Wizard answers** (`fixtures/wizard-answers/`) - pre-baked JSON answer files for non-interactive replay (distinct from the `wizard/` templates below).

**Store dual-publish** (`fixtures/store-dual-publish/`) - vendored `manifest.cbor` + README for the store lifecycle test.

**Telemetry** (`fixtures/telemetry/`) - OpenTelemetry Collector config (`otel-collector-file-export.yaml`) for the telemetry E2E.

**Wizard fixtures** (`fixtures/wizard/`) - scripts that drive interactive wizard tests:
- `e2e.env` - shared wizard input variables (pack ID, bundle name)
- `traversal.py` / `traversal.expect` - interactive wizard traversal (Python pty driver + legacy expect)
- `emit_answers.py` / `emit_answers.expect` - tests `gtc wizard --emit-answers`
- `replay-answers.template.json` - template with `__PLACEHOLDER__` tokens replaced at runtime
- `bundle_complex.template.json` - complex bundle wizard answer template
- `pack_flow_plan.template.json` - pack/flow plan wizard answer template

### Bundle Config

Bundles are YAML files (`fixtures/bundles/e2e-provider-bundle.yaml`) that declare providers as arrays:
```yaml
providers:
  messaging:
    - provider: messaging-dummy
      enabled: true
      config:
        channel_id: e2e-test-channel
  events:
    - provider: events-dummy
      enabled: true
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
| `messaging-slack` | `SLACK_BOT_TOKEN`, `SLACK_APP_ID`, `SLACK_CONFIGURATION_REFRESH_TOKEN` |
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
- `scripts/run_cloud_demo_e2e.sh` - Cloud demo lifecycle harness for AWS, Azure, and GCP. Verifies published `greentic-demo` release assets, web UI route, and optional admin tunnel flow for AWS only.
  Defaults: AWS `AWS_REGION/AWS_DEFAULT_REGION=eu-north-1`, AWS backend `s3`, Azure location `westeurope`, Azure backend `azurerm`, GCP region `us-central1`, GCP backend `gcs`.
- `scripts/run_telemetry_e2e.sh` - Telemetry OTLP harness. Boots `fixtures/telemetry/otel-collector-file-export.yaml` in Docker, starts a dummy bundle with `TELEMETRY_EXPORT`/`OTLP_ENDPOINT`, asserts `resourceLogs` + `service.name` in the dump. Collector publishes on host `:14317`/`:14318` and the gateway on `:18080` to avoid colliding with a local demo/collector. Cleanup is scoped to the run's own `greentic-start` (matched by temp dir), so it won't kill an unrelated demo server.
- `scripts/run_store_dual_publish_e2e.sh` - Store agentic-worker `publish -> install -> run` lifecycle. Spins up a throwaway docker network + Postgres + MinIO + the store image, plus a python3-stdlib mock admin registry (reachable via container DNS name on the shared docker network). Asserts the publish no-repack sha invariant, install-back byte-equality, run-from-store admin hand-off (one PUT, namespaced agent id), and the byo-required 409. Vendors a pre-built `fixtures/store-dual-publish/manifest.cbor` (the run endpoint decodes it with greentic-types; see that fixture's generation note below). SKIPS when the store image is not pullable.
- `scripts/run_webchat_passthrough_e2e.sh` - WebChat DirectLine passthrough regression harness. Uses the `fixtures/packs/webchat-passthrough-probe` pack. Starts the bundle DIRECTORY → the legacy `--bundle` arm.
- `scripts/run_type_only_routing_e2e.sh` - Track-A guard for greentic-runner #611. Uses `fixtures/packs/type-only-routing-probe` (two same-type flows: `main` entry, `internal_helper` internal). Drives a type-only WebChat ingress and asserts a bot reply arrives, the runtime never logged the ambiguity bail, and `internal_helper` never won the route. Env: `PORT`, `WORK_DIR_BASE`, `SKIP_BUILD`, `KEEP_BUNDLE`.
- `scripts/run_tenant_binding_e2e.sh` - Track-A guard for greentic-setup #232. Reuses the type-only-routing probe's `.gtbundle`, runs `gtc setup env-deploy <archive> --tenant <TENANT>` (default `acme`) under an isolated HOME, and asserts `~/.greentic/environments/local/environment.json` `.bundles[].route_binding` names the tenant with the required shape (team `default`, path_prefixes `["/"]`, hosts `[]`). No runtime boot. Env: `TENANT`, `WORK_DIR_BASE`, `SKIP_BUILD`, `KEEP_BUNDLE`. Note: must env-deploy the `.gtbundle` archive under `dist/`, not the bundle directory (packing the dir yields a tree with no `bundle-manifest.json`).
- `scripts/run_webchat_reply_parity_e2e.sh` - Track-A guard for greentic-start #438. Reuses the `webchat-passthrough-probe` pack UNCHANGED but starts the ARCHIVE (`gtc start <archive.gtbundle>`) → the env/revision serve arm, seeding webchat secrets into the shared env store (`~/.greentic/environments/<env>/.greentic/dev/.dev.secrets.env`). Asserts the runtime took the env/revision arm (log: "revision ingress listening" / "serving N revision(s)") AND the rich reply (adaptive-card attachment + channelData + entities) survives. Env: `PORT`, `WORK_DIR_BASE`, `SKIP_BUILD`, `KEEP_BUNDLE`.
- `scripts/run_agentic_e2e.sh` - Agentic worker (`dw.agent`) e2e. Fetches/uses the tavily agentic bundle, runs `gtc setup` + `gtc start`, drives one turn over the WebChat DirectLine rail (token → conversation → message → poll; reply may be plain text or an Adaptive Card), and asserts a non-empty reply. Env: `GREENTIC_LLM_API_KEY` (required — mapped from `DEEPSEEK_KEY` in CI), `TAVILY_API_KEY` (optional), `GREENTIC_AGENTIC_BUNDLE_SOURCE`, `GREENTIC_AGENT_TENANT`, `GREENTIC_AGENT_PROMPT`. No Redis. Cleanup trap kills `greentic-runner`.
- `ci/run_actions.sh` - Runs nightly workflow locally via [nektos/act](https://github.com/nektos/act). Auto-installs `act` to `.bin/`. Resolves Docker host for both macOS (Docker Desktop) and Linux.

## Playwright sub-package

Browser-driven demo e2e lives under `playwright/`. See `playwright/README.md` for local dev workflow and `docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` for design.

`docs/superpowers/` contains implementation plans (`plans/`) and design specs (`specs/`) for major e2e test additions.
