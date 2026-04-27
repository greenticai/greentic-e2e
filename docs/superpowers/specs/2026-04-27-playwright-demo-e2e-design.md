# Playwright Demo E2E — Design

- **Status:** draft, awaiting approval
- **Author:** Bima Pangestu
- **Date:** 2026-04-27
- **Scope:** `greentic-e2e/` repository
- **Related work this design intentionally does NOT cover:** broader `all messengers / all events / all components / observer / control` e2e expansion (shared bucket with Vahe Grishkyan and Osoro Bironga), stable channel versioning bug (Vlad Dobromyslov), gtc-side fixes from Maarten (separate verification runbook).

---

## 1. Background

On 2026-04-26 evening (CET) Maarten Ectors raised a P0: Paul at 3Point.ai cannot get the simplest `greentic-demo` to run. 3Point is a strategic sponsor; demo reliability is now a quality-over-features priority across the platform.

The current `greentic-e2e/` suite covers `gtc install`, the wizard apply/validate flow, provider HTTP ingress, the cloud-deploy demo at the HTTP layer, and a WebChat passthrough HTTP probe. None of those run a real demo end-to-end through a browser. A regression in WebChat rendering, gtc startup ordering, bundle-loading semantics, or remote-asset resolution can ship to stable without nightly catching it. That is the gap this design closes.

Maarten's specific assignment to Bima is twofold:
1. Verify the four fixes Maarten pushed on 2026-04-27 (covered by a separate verification runbook, not this spec).
2. Add Playwright e2e tests for demos, running nightly against both `-dev` and `main` channels.

This document covers item (2).

## 2. Goals and non-goals

### 2.1 Goals

- Nightly browser-driven verification that public Greentic demos load, accept user input via WebChat, and produce a non-error reply.
- Coverage of all interactive demos published in `greentic-demo` releases (13 demos identified at v0.1.61: 12 confirmed interactive plus 1 conditional — `cards-demo` — pending §13.4 confirmation).
- Matrix execution against two channels of `gtc`: `stable` (the published `cargo binstall gtc` artifact) and `dev` (a fresh `cargo install --git main` build).
- Failure surfaces a Slack-actionable signal with a Playwright trace, screenshots, video, and gtc lifecycle logs attached.
- Local developer loop: `npx playwright test <demo> --headed --debug` works without CI involvement.

### 2.2 Non-goals

- Multi-channel testing (Slack, Teams, Telegram, Webex, WhatsApp via real platform APIs) — handled by the existing `provider-e2e.yml` and the broader e2e expansion shared with Vahe and Osoro.
- Designer UI testing — out-of-scope; if needed it belongs in `greentic-designer/`.
- Visual regression (pixel-diff).
- Accessibility audits.
- Load and performance testing.
- i18n smoke (assertion against non-English replies).
- Replacing `cloud-demo-e2e.yml` — that workflow stays HTTP-level for the `cloud-deploy-demo` cloud-creds path; Playwright will not duplicate it.
- gtc-side fixes (Maarten pushed `greentic 1.0.11`, `greentic-setup 0.5.2`, `greentic-pack` `bddce14`, `greentic-demo` asset corrections) — verified out-of-band via the existing runbook.

## 3. Demo catalog (target coverage)

Enumerated from `greentic-demo` release `v0.1.61` (`gh release view v0.1.61 --repo greenticai/greentic-demo`). Tiering drives Phase 1 rollout order and assertion strategy.

### 3.1 Tier 1 — headline, no secrets

| Demo | Notes |
|------|-------|
| `helpdesk-itsm` | The exact case Paul could not run. PR-1 ships this one. |
| `quickstart` | Documented happy-path starter. |

### 3.2 Tier 2 — industry, no secrets

| Demo | Notes |
|------|-------|
| `hr-onboarding` | Likely card-driven. |
| `incident-demo` | Industry vertical. |
| `sales-crm` | Industry vertical. |
| `supply-chain` | Industry vertical. |
| `telco-x-demo` | Industry vertical. |
| `redbutton` | Card-and-button demo. |
| `cards-demo` | Adaptive Card showcase (asset coverage to be confirmed during PR-2 — release contains only `cards-demo.gtpack`, no answers files). |

### 3.3 Tier 3 — needs upstream secrets, skip-on-missing

| Demo | Required secret | Notes |
|------|-----------------|-------|
| `deep-research-demo` | LLM API key (`OPENAI_API_KEY` or `ANTHROPIC_API_KEY`) | Structural assertions only. |
| `greentic-ai` | LLM API key | Structural assertions only. |
| `github-mcp` | `GITHUB_TOKEN_FOR_DEMO` | Structural + tool-call indicator. |
| `weather-mcp-demo` | `WEATHER_API_KEY` (TBD exact env var) | Structural + tool-call indicator. |

### 3.4 Excluded from Playwright coverage

- `quickstart-event` — webhook-triggered, no chat surface. Out of scope; HTTP-only coverage if ever needed.
- `cloud-deploy-demo` — already covered by `cloud-demo-e2e.yml` HTTP test; cloud creds are expensive to consume in two workflows.

## 4. Architecture

### 4.1 Approach: Playwright-driven lifecycle

The Playwright TypeScript suite owns the per-test demo lifecycle through a custom fixture (`gtcDemo`). A thin bash bootstrap installs the right `gtc` binary at job start; everything else (bundle download, setup, start, ready-wait, browser interaction, teardown, log capture) runs in TypeScript through Playwright fixtures.

Rationale for choosing this over a bash-glue approach:

- Scales to 30+ demos with parallel Playwright workers.
- Cross-platform (Linux + macOS + future Windows) without bash-quoting friction.
- Aligns with Playwright ecosystem (UI mode, trace viewer, VS Code integration assume TS-driven setup).
- Local developer iteration via `npx playwright test --headed --debug` is fast (no per-iteration `gtc install`).

The trade-off accepted: PR-1 takes roughly one extra day relative to a pure-bash equivalent, in exchange for substantially lower maintenance cost across the suite's lifetime.

### 4.2 Repository layout

The suite lives as a self-contained sub-package inside `greentic-e2e/` so its Node toolchain does not bleed into the bash-based provider-e2e and cloud-demo workflows.

```
greentic-e2e/
  playwright/                          NEW
    package.json
    package-lock.json
    tsconfig.json
    playwright.config.ts
    README.md
    tests/
      _fixtures/
        gtc-demo.ts                    # Playwright test extension with the gtcDemo fixture
        webchat-page.ts                # Page Object Model for /v1/web/webchat/<demo>/
      helpdesk-itsm.spec.ts            # Phase 0 (PR-1)
      quickstart.spec.ts               # Phase 1 (PR-2)
      ...                              # Phase 1 fan-out, one file per demo
    scripts/
      bootstrap-gtc.sh                 # install gtc (stable | dev)
      download-demo-assets.ts          # pull greentic-demo release assets into tmp/
  .github/workflows/
    demo-playwright.yml                NEW
  (existing files untouched)
```

### 4.3 Channel matrix

`-dev` vs `main` is interpreted as a release-channel matrix:

| Project (Playwright `projects[]`) | gtc binary | Source |
|-----------------------------------|------------|--------|
| `stable` | `gtc-stable` | `cargo binstall gtc` (latest published) |
| `dev` | `gtc-dev` | `cargo install --git https://github.com/greenticai/greentic.git --branch main --locked --bin gtc gtc` (renamed to `gtc-dev`) |

If Maarten's intent turns out to be different (for example tenant-name `dev` vs `main`, or branch artifact rather than release channel), the projects list is the only place that needs to change — fixtures and specs stay channel-agnostic.

### 4.4 Execution flow

```
[GHA job]
  bootstrap-gtc.sh ${channel}
  npm ci
  npx playwright install --with-deps chromium
  npx playwright test --project=${channel}
    └─ per spec file, parallelized across workers:
         fixture gtcDemo({ name }) =>
           - resolve worker-isolated port
           - download create-answers + setup-answers from greentic-demo release (cached per worker)
           - gtc wizard --answers <create-answers.json>             (materializes bundle dir)
           - load + overlay tests/_fixtures/demo-patches/<demo>.json on setup-answers
           - gtc setup --non-interactive <bundle> --answers <patched-setup.json>
           - greentic-runner --port ${port} --bindings <bundle>/resolved   (background)
           - poll /readyz until 200 or timeout (60s)
           - yield { demoUrl, gtcLogs, team } to test
         ... browser-driven assertions ...
         fixture teardown:
           - SIGTERM runner, 5s grace, SIGKILL
           - on test failure: attach runner log, screenshot, trace, video
```

The fixture intentionally bypasses `gtc start`/`greentic-start start` and calls `greentic-runner` directly because `gtc start` does not expose a `--port` flag (see §13.5). `greentic-runner --port <N>` is the canonical port mechanism. We lose the cloudflared/ngrok wiring that `greentic-start` does, which is fine for nightly e2e (those are off by design).

## 5. `gtcDemo` fixture

### 5.1 Contract

```ts
type GtcDemo = {
  name: string;       // demo key, e.g. "helpdesk-itsm"
  team: string;       // setup tenant team, default "default"
  tenant: string;     // setup tenant, default "demo"
  port: number;
  demoUrl: string;    // http://127.0.0.1:<port>/v1/web/webchat/<team>/
  bundleDir: string;
  logFile: string;
};

type DemoOptions = {
  name: string;
  team?: string;                          // default "default" — matches greentic-runner output
  tenant?: string;                        // default "demo"
  setupAnswers?: Record<string, unknown>; // override the patched release answers
  envOverrides?: Record<string, string>;
  skipIfMissingSecrets?: string[];
};

export const test = base.extend<{ gtcDemo: (opts: DemoOptions) => Promise<GtcDemo> }>({ /* … */ });
```

**`demoUrl` formula.** The runner exposes WebChat at `/v1/web/webchat/<team>/`, where `<team>` is the team configured during setup (default `default`). Confirmed empirically against `helpdesk-itsm` on 2026-04-27 — runner output: `Routes: .../v1/web/webchat/default/`. The URL is **per-team**, not per-demo, because multiple demos served from one runner share the same WebChat route.

### 5.2 Implementation notes

- **Port allocation:** deterministic — `8080 + workerIndex * 100 + perFixtureIndex`. Reproducible debugging, no port-discovery race, 100 ports reserved per worker.
- **Bundle download cache:** `tmp/<workerIndex>/<demo>/`, reused within a single run. Release assets are immutable per tag, so caching is safe and saves 12+ downloads per nightly.
- **gtc binary selection:** `process.env.GTC_BIN`, set per Playwright project. The bootstrap script always renames the dev build to `gtc-dev` to allow both binaries to coexist in `~/.cargo/bin/`.
- **Failure log capture:** `testInfo.attach()` only on `failed` or `timedOut` status — pass-case artifacts stay quiet.
- **Setup-answers source:** default to the release's `<demo>-setup-answers.json` (mirroring Paul's exact reproduction); `setupAnswers` arg lets a specific test inject overrides for secrets without forking files.
- **Concurrent demos in one test:** supported via the factory pattern, even if Phase 0 and Phase 1 specs only allocate one demo per test.
- **Cleanup:** SIGTERM → 5s grace → SIGKILL prevents leaked processes between tests; `bootstrap-gtc.sh` also runs `pkill -f greentic-runner || true` at job start as a belt-and-braces.

### 5.3 Failure modes addressed by the fixture

| Failure | Fixture behavior |
|---------|------------------|
| `greentic-runner` crashes during startup | `waitForReady` timeout fires; fixture throws; test marked failed; runner log attached. |
| Port already in use | Bootstrap precheck via `lsof`; deterministic port range avoids collision under normal CI conditions. |
| Bundle download 404 (missing release asset) | `ensureBundleCached` fails fast with the exact asset URL — diagnoses regressions like Maarten's "all gtpacks were uploaded to release" issue. |
| Hung gtc process from prior test | Teardown SIGKILL after 5s grace; bootstrap also kills any lingering `greentic-runner`. |
| Flaky network from greentic-demo CDN | Playwright config `retries: process.env.CI ? 2 : 0` covers fixture errors. Test-assertion failures do not retry — they retain regression signal. |

## 6. Page Object Model and assertion strategy

### 6.1 `WebChat` POM

```ts
class WebChat {
  open(): Promise<void>;
  send(text: string): Promise<void>;
  awaitReply(opts?: { timeoutMs?: number; minLength?: number }): Promise<string>;
  awaitCardWithText(matcher: RegExp | string, timeoutMs?: number): Promise<Locator>;
  clickCardAction(label: string | RegExp): Promise<void>;
}
```

Locators favor accessible-first selectors (`getByRole`, `getByText`) and fall back to attribute selectors (`[data-testid="message-list"]`, `[role="log"]`, `.ac-textBlock`) only where the WebChat HTML does not expose accessible affordances. The exact selectors above are tentative and assume a DirectLine-style WebChat; the first task in PR-1 is to inspect the real `/v1/web/webchat/helpdesk-itsm/` page and confirm or refine them.

### 6.2 Assertion tiers

| Tier | Demos | Assertions |
|------|-------|------------|
| Smoke (Phase 0) | Any | Page loads, input interactive, send produces a reply ≥ 10 chars within 30s, no `/error|exception|panic|stack trace/i` markers. |
| Functional (Phase 1, deterministic demos) | Tier 1 + Tier 2 | Reply matches a demo-specific intent regex (helpdesk-itsm: `/ticket|issue|printer|created/i`, etc.). For card-driven flows, assert specific card title or button presence. |
| Structural (Phase 1, LLM-driven demos) | Tier 3 | Reply ≥ 50 chars, completed within 90s, no error markers. For tool-using demos, assert a tool-call indicator (loading state or partial response stream) appeared. |

Hard rules:

- Never assert exact bot text. Even deterministic demos use templated copy.
- Never use `page.waitForTimeout(N)` outside debugging. Use `expect.poll` or locator auto-waiting.
- Always include a negative assertion against error markers — catches 500s rendered as bot messages.
- For multi-turn flows, assert per turn rather than bundling at the end.

### 6.3 Why tiered assertions fit Greentic

The tier split mirrors Greentic's deterministic-by-default / AI-where-it-helps philosophy. Failures map cleanly to "is this a Greentic regression or an upstream-model issue?" without mixing the two signals. Multilingual coverage is deferred — tests are English-input, English-output.

## 7. GitHub Actions workflow

### 7.1 `.github/workflows/demo-playwright.yml`

- **Trigger:** `schedule: cron 30 3 * * *` (03:30 UTC, after `nightly-e2e` 00:00 and `cloud-demo-e2e` 02:00) plus `workflow_dispatch` with optional `gtc_channel` and `demos` filter inputs.
- **Permissions:** `contents: read`.
- **Concurrency:** group on workflow + ref, `cancel-in-progress: false` to mirror existing nightly patterns.

### 7.2 Matrix

Three cells in PR-1, one cell added in PR-2 if PR-1 is stable:

| Label | Runner | Channel |
|-------|--------|---------|
| `stable / linux` | `ubuntu-24.04` | stable |
| `dev / linux` | `ubuntu-24.04` | dev |
| `stable / macos` | `macos-15` | stable |
| `dev / macos` (PR-2 only, conditional) | `macos-15` | dev |

`fail-fast: false` so per-cell failures report independently.

### 7.3 Steps

1. Checkout.
2. Bootstrap Rust 1.95 + `wasm32-wasip2` target.
3. Run `playwright/scripts/bootstrap-gtc.sh ${channel}` to install the relevant gtc binary; this also exercises `gtc install` end-to-end (which itself covers Maarten's Fix 1 about `mksquashfs` / `cargo-component` / `wasm32-wasip2` auto-install).
4. Install `squashfs-tools` and `jq` on Linux runners.
5. `actions/setup-node@v4` with `node-version: 20` and npm cache keyed off `playwright/package-lock.json`.
6. `npm ci` in `playwright/`.
7. `npx playwright install --with-deps chromium`.
8. `npx playwright test --project=${channel}` with secrets and `GTC_BIN` exported.
9. Always upload `playwright-report/` artifact (retention 14 days).
10. On failure, additionally upload `test-results/` (traces, videos, screenshots) and `tmp/**/gtc-*.log` (retention 14 days).

### 7.4 Secrets

| Secret | Demos | Behavior if missing |
|--------|-------|---------------------|
| `GITHUB_TOKEN_FOR_DEMO` | `github-mcp` | `test.skip()` in fixture, no Slack alert. |
| `OPENAI_API_KEY` | `greentic-ai`, `deep-research-demo` (and any future LLM demo) | `test.skip()`. |
| `ANTHROPIC_API_KEY` | LLM demos using Anthropic | `test.skip()`. |
| `WEATHER_API_KEY` | `weather-mcp-demo` (exact env var TBD during PR-2c) | `test.skip()`. |

Pattern follows `provider-e2e.yml` PR #35 ("skip matrix entries with missing secrets, not fail"). The existing `notify-scheduled-failures.yml` catch-all Slack notifier handles failures without additional wiring.

### 7.5 Time budget

- Estimate: up to 13 demos × ~3 min worst-case ÷ 4 Playwright workers ≈ 10 min ideal per cell.
- `timeout-minutes: 60` in PR-1 for headroom; tighten to 40 in PR-2d once empiric run-time is stable below 30 min.
- Total CI cost ≈ 45 runner-minutes per nightly across 3 cells, comfortably below the existing `provider-e2e.yml` (~180 min × 6 cells).

## 8. Phase split and acceptance criteria

### 8.1 Phase 0 — PR-1 walking skeleton

**Deliverables:**

- `playwright/` sub-package: `package.json`, lockfile, `tsconfig.json`, `playwright.config.ts`, README, `.gitignore`.
- `gtcDemo` fixture and `WebChat` POM in `tests/_fixtures/`.
- `bootstrap-gtc.sh` and `download-demo-assets.ts` in `scripts/`.
- One spec file: `helpdesk-itsm.spec.ts` (smoke + minimal functional).
- `.github/workflows/demo-playwright.yml`.
- README and root `CLAUDE.md` updates pointing at `playwright/`.

**Acceptance criteria:**

- `cd playwright && npm test` passes locally on Linux and macOS.
- GHA `stable / linux` cell green for `helpdesk-itsm`.
- Trace, video, screenshot, gtc-log artifacts upload as designed (verified by intentionally breaking the spec and reverting).
- Slack notifier fires on simulated failure.
- `dev / linux` cell either green or has a documented gap (likely tagging `@vlad` if `cargo install --git main` build breaks because of the versioning regression).

**Phase 0 explicit exclusions:** other 12 demos, Adaptive Card flows, multi-turn conversations, macOS dev cell, Firefox/WebKit, i18n, response-time SLOs.

### 8.2 Phase 1 — PR-2 demo catalog fan-out

Additive to PR-1. Optionally split into sub-PRs for faster review:

- **PR-2a** — Tier 1 (`quickstart`) and Tier 2 deterministic demos.
- **PR-2b** — card-driven demos (`redbutton`, `cards-demo`, `hr-onboarding` card flows).
- **PR-2c** — Tier 3 (`deep-research-demo`, `greentic-ai`, `github-mcp`, `weather-mcp-demo`).
- **PR-2d** — workflow polish (matrix expand to `dev / macos`, timeout tighten, custom GHA summary reporter).

**Cumulative acceptance criteria after PR-2:**

- All 12 confirmed in-scope demos have either green specs or documented skip reasons (plus `cards-demo` if §13.4 confirms it is runnable).
- Nightly average wall-clock under 25 min per matrix cell.
- Flake rate under 2% over 7 consecutive nightlies.
- Each demo's failure surfaces a Slack-actionable signal with trace, screenshot, video, and gtc log links.

### 8.3 Indicative timeline

```
Day 0      PR-1 draft → manual local test → CI green → merge
Day 1-2    Verify-fixes runbook close-out (parallel, separate work)
Day 3      PR-2a merge
Day 4      PR-2b merge
Day 5-6    PR-2c merge
Day 7      PR-2d merge
Day 7-8    First "all green for 7 nights" milestone → report to Maarten
```

## 9. Failure handling

### 9.1 Failure categories

| Category | Trigger | Surfacing | Owner |
|----------|---------|-----------|-------|
| A. Test infra error | npm install, browser download, runner health | Workflow run failed | Bima / maintainers |
| B. gtc lifecycle error | `bootstrap-gtc.sh` or `gtcDemo` fixture | Test failed; gtc log + bootstrap log attached | gtc / setup / pack repo owners |
| C. Test assertion failure | Inside spec | Test failed; screenshot, video, trace, gtc log attached | Demo owner; Bima triages |
| D. Skipped (missing secret) | `test.skip()` in fixture | Marked skipped in summary; no Slack alert | Informational only |
| E. Flaky (passed on retry) | Playwright auto-retry | Listed as flaky in HTML report; no workflow fail | Bima weekly review; quarantine after 3 flakes/week |

### 9.2 Artifacts on failure

```
playwright/
  test-results/<test>/
    trace.zip        # `npx playwright show-trace trace.zip`
    video.webm
    test-failed-1.png
    gtc-log-<demo>.txt
  playwright-report/
    index.html       # Always uploaded (success + fail)
```

### 9.3 GHA summary

A markdown table per nightly listing each demo × matrix cell with pass/fail/skip. Default Playwright reporter in PR-1; custom `gha-summary-reporter.ts` writing to `$GITHUB_STEP_SUMMARY` is added in PR-2d.

## 10. Rollout and rollback

### 10.1 Rollout (post-merge)

- **Day 0-2:** Bima monitors two consecutive nightlies. Two consecutive same-reason failures trigger rollback. One flake → bump retries from 2 to 3 temporarily and root-cause.
- **Day 3-7:** Each PR-2 sub-PR requires one successful manual `workflow_dispatch` run before merge.
- **Day 7-14:** Steady state. Weekly Monday review of HTML reports for flakes. Maarten receives only red Slack notifications; green nights stay silent.

### 10.2 Escalation triggers

- Three consecutive nightly fails in category B → escalate to Maarten and Vlad as a possible stable-channel regression.
- Same demo flaky 5+ times in 7 days → quarantine via `test.fixme()` and file an issue against `greentic-demo` or the relevant component repo with the trace artifact attached.

### 10.3 Rollback

- Workflow disable: `gh workflow disable demo-playwright.yml --repo greenticai/greentic-e2e`. The workflow file stays in the repo and can be re-enabled with `gh workflow enable`.
- File-level rollback: revert the merge commit. All deliverables live under `playwright/` plus one workflow file, so blast radius is zero — no existing provider-e2e, cloud-demo, or nightly-e2e workflow is touched.

## 11. Local developer workflow

```bash
cd ~/Works/greentic/greentic-e2e/playwright
npm ci
npx playwright install chromium

# Install gtc locally
bash scripts/bootstrap-gtc.sh stable

# Run one demo, headed, with the Playwright Inspector
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --headed --debug

# Run all specs for a given channel
GTC_BIN=gtc-stable npx playwright test --project=stable

# Open the last HTML report
npx playwright show-report
```

`--debug` opens the Playwright Inspector — step through actions, edit selectors live. This is the primary tool for the first PR-1 task: locking the WebChat POM selectors against the real DOM.

## 12. Maintenance ownership

| Concern | Owner |
|---------|-------|
| Playwright fixture, POM, workflow | Bima |
| Per-demo specs | Bima (Phase 1); handoff to demo author when one is identified |
| Flaky test triage | Bima weekly |
| Adding a new demo when `greentic-demo` releases new bundle | Whoever publishes the demo, following CONTRIBUTING |
| gtc-side fixes (Fix 1-5) | Owner repos: `greentic`, `greentic-setup`, `greentic-pack`, `greentic-demo` — not Bima |
| `notify-scheduled-failures.yml` | Existing owner — not touched by this work |

## 13. Open questions and assumptions

Updated 2026-04-27 with PR-1 preflight findings.

1. **WebChat HTML structure.** POM selectors in §6.1 are tentative. PR-1 first task is to inspect `/v1/web/webchat/default/` in a real browser and confirm `getByRole`, `data-testid`, `.ac-textBlock`, typing-indicator, and bot-message selectors. Adjust the POM before locking.
2. **Channel interpretation.** This design assumes `-dev` = `cargo install --git main` and `main` (in Maarten's wording) = `cargo binstall gtc` published stable. Awaiting Slack confirmation from Maarten; if wrong, only the matrix in §4.3 and `bootstrap-gtc.sh` change.
3. **`weather-mcp-demo` secret name.** TBD during PR-2c — confirm against the demo's bundle answers file.
4. **`cards-demo` testability.** The release v0.1.61 includes only `cards-demo.gtpack` (no answers files). Confirm during PR-2b whether this is a runnable demo or a packaging artifact only; if the latter, drop it from the catalog.
5. **~~`gtc start --port` flag.~~ RESOLVED 2026-04-27.** `gtc start` does NOT expose a `--port` flag (delegates to `greentic-start start` which only has `--admin-port`). The fixture must call `greentic-runner --port <N> --bindings <bundleDir>/resolved` directly to enable parallel Playwright workers on isolated ports. `greentic-runner --port` is documented and stable. Trade-off accepted: skipping `greentic-start` means we don't exercise its cloudflared/ngrok/secrets init for nightly tests, which is acceptable since nightly already uses `--cloudflared off --ngrok off`.
6. **Bundle directory layout.** The fixture uses `gtc wizard --answers <create.json>` to materialize the bundle directory (confirmed working with remote URLs against Maarten's Fix 5), then `gtc setup --non-interactive <bundle> --answers <patched-setup.json>` for setup, then `greentic-runner --port <N> --bindings <bundle>/resolved` for start.
7. **Upstream answers JSON incomplete (NEW finding 2026-04-27).** `helpdesk-itsm-setup-answers.json` from `greentic-demo` v0.1.61 has empty strings and missing keys for required fields like `messaging-slack.public_base_url`, `messaging-slack.slack_signing_secret`, etc. Maarten's Fix 2 (`greentic-setup --non-interactive`) correctly fails on these — the actual root cause Paul could not run the demo is upstream answers JSON, not just the remote-invocation regression Maarten fixed. Fixture mitigation: per-demo overlay patches in `tests/_fixtures/demo-patches/<demo>.json` augment the upstream JSON with safe placeholder values for fields that are not security-sensitive (URLs, IDs) and use real env-var-backed values for genuine secrets. Upstream tracking: greentic-demo issue to be filed for proper fix (sanitize the answers JSON or drop slack/teams/webex from helpdesk-itsm bundle composition).
8. **`gtc setup --no-ui` vs `--non-interactive` (NEW 2026-04-27).** The existing `--no-ui` flag still requires a TTY for stdin prompts (per `greentic-setup --help`: "stdin prompts may still be used"). The proper non-interactive flag is `--non-interactive` ("Strict non-interactive mode: no prompts, fail if answers incomplete") introduced by Maarten's Fix 2 in `greentic-setup 0.5.2`. **The fixture and CI workflow must use `--non-interactive`, not `--no-ui`.**

## 14. References

- `greentic/README.md` — overall product context and the three-step demo flow.
- `greentic/docs/00-start-here.md` — canonical-source-order policy.
- `greentic-e2e/CLAUDE.md` — existing repo conventions (provider-e2e, cloud-demo-e2e, webchat-passthrough patterns).
- `greentic-e2e/.github/workflows/nightly-e2e.yml` — bootstrap and toolchain pattern reused.
- `greentic-e2e/.github/workflows/provider-e2e.yml` PR #35 — skip-on-missing-secret pattern adopted by §7.4.
- `greentic-e2e/.github/workflows/notify-scheduled-failures.yml` — Slack notifier reused without modification.
- `greentic-demo` release `v0.1.61` — demo asset enumeration for §3.
