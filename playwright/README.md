# Playwright Demo E2E

Browser-driven nightly e2e for `greentic-demo` bundles. Sub-package of `greentic-e2e/`.

See `../docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` for design rationale and `../docs/superpowers/plans/2026-04-27-playwright-demo-e2e-pr1.md` for the PR-1 implementation plan.

## Local quickstart

```bash
cd playwright
npm ci
npx playwright install chromium
bash scripts/bootstrap-gtc.sh stable

# Headed + Inspector for one demo
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --headed --debug

# Full stable matrix locally
GTC_BIN=gtc-stable npx playwright test --project=stable

# Open the last HTML report
npx playwright show-report
```

## Layout

| Path | Purpose |
|---|---|
| `playwright.config.ts` | Projects (stable, dev), reporters, retries, artifact policy |
| `tests/_fixtures/gtc-demo.ts` | `gtcDemo` fixture: bundle download → setup → start → ready → teardown |
| `tests/_fixtures/webchat-page.ts` | `WebChat` Page Object Model |
| `tests/_fixtures/ports.ts` | Worker-isolated port allocator |
| `tests/_fixtures/demo-patches/<demo>.json` | Per-demo overlay patches that fill upstream answers gaps |
| `tests/<demo>.spec.ts` | One file per demo |
| `scripts/bootstrap-gtc.sh` | Install gtc per channel, run `gtc install` |
| `scripts/download-demo-assets.ts` | Pull bundle + answers from greentic-demo release |

## Channel matrix

`stable` = `cargo binstall gtc` (latest published).
`dev` = `cargo install --git https://github.com/greenticai/greentic --branch main --locked`.

Set `GTC_CHANNEL=stable|dev` and `GTC_BIN=gtc-stable|gtc-dev` to switch.

## Adding a new demo

1. Confirm the demo has create + setup answers files in `greentic-demo` releases.
2. Create `tests/<demo-name>.spec.ts` following the `helpdesk-itsm.spec.ts` pattern.
3. Run locally; iterate `tests/_fixtures/demo-patches/<demo>.json` if `gtc setup --non-interactive` reports missing fields.
4. Push and trigger `gh workflow run demo-playwright.yml -f demo_filter=<demo-name>` (after PR is open).

## Failure triage

1. Check the GHA run summary for which matrix cell failed.
2. Download the `playwright-failures-<label>` artifact.
3. `npx playwright show-trace test-results/<failing-test>/trace.zip`.
4. Inspect the gtc log in the same artifact for category-B (lifecycle) failures.

## Out of scope

This sub-package covers WebChat browser-driven demo testing only. Provider-specific HTTP ingress lives in `provider-e2e.yml`. Cloud deploy lives in `cloud-demo-e2e.yml`. Designer/Admin UI lives in their respective repos.
