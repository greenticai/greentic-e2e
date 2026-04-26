# Playwright Demo E2E — PR-1 (Walking Skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a self-contained Playwright sub-package inside `greentic-e2e/` that drives one demo (`helpdesk-itsm`) end-to-end through a real browser on the `stable / linux` GHA matrix cell, with the lifecycle fixture, POM, bootstrap script, workflow, and artifact-on-failure plumbing all in place to extend in PR-2.

**Architecture:** Playwright-driven lifecycle (TS fixtures own `gtc setup`/`start`/teardown), bash bootstrap installs `gtc` per channel, sub-package isolates Node tooling from existing bash workflows. See `docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` for the design — every task here implements one section of that spec.

**Tech Stack:** TypeScript 5, Node 20, `@playwright/test` 1.49+, GitHub Actions, bash 4+, gtc 1.0.11+.

---

## Spec → task crosswalk (so reviewers can verify coverage)

| Spec section | Task(s) |
|---|---|
| §3 Demo catalog | Task 1 (preflight only — implementation = PR-2) |
| §4.1–4.2 Architecture & layout | Task 2 |
| §4.3 Channel matrix | Task 3, Task 10 |
| §4.4 Execution flow | Task 6, Task 10 |
| §5 `gtcDemo` fixture | Task 4, Task 5, Task 6 |
| §6 POM + assertion strategy | Task 7, Task 8 |
| §7 GHA workflow | Task 10 |
| §8.1 PR-1 acceptance criteria | Task 9, Task 11 |
| §9 Failure handling | Task 6, Task 10, Task 11 |
| §10 Rollout | Task 11 |
| §11 Local dev workflow | Task 9, Task 12 |
| §13 Open questions | Task 1 |

---

## File map (everything PR-1 will create or modify)

| Path | Purpose | Task |
|---|---|---|
| `playwright/package.json` | Sub-package manifest, `@playwright/test` dep, scripts | 2 |
| `playwright/package-lock.json` | npm lockfile (generated) | 2 |
| `playwright/tsconfig.json` | TypeScript config, strict mode | 2 |
| `playwright/.gitignore` | Ignore `node_modules/`, `tmp/`, `test-results/`, `playwright-report/` | 2 |
| `playwright/playwright.config.ts` | Projects (stable, dev), reporters, timeouts, retries | 2 |
| `playwright/README.md` | Local dev quickstart, layout overview | 12 |
| `playwright/scripts/bootstrap-gtc.sh` | Install gtc binary per channel + run `gtc install` | 3 |
| `playwright/scripts/download-demo-assets.ts` | Pull bundle + answers from greentic-demo release | 5 |
| `playwright/tests/_fixtures/ports.ts` | Deterministic worker-isolated port allocator | 4 |
| `playwright/tests/_fixtures/ports.test.ts` | Unit test for port allocator | 4 |
| `playwright/tests/_fixtures/gtc-demo.ts` | The `gtcDemo` Playwright fixture | 6 |
| `playwright/tests/_fixtures/webchat-page.ts` | `WebChat` Page Object Model | 7 |
| `playwright/tests/helpdesk-itsm.spec.ts` | Phase 0 spec | 8 |
| `.github/workflows/demo-playwright.yml` | Nightly + workflow_dispatch | 10 |
| `CLAUDE.md` (greentic-e2e root) | Pointer at `playwright/` sub-package | 12 |
| `docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` | Status flip: draft → approved (only after PR-1 merges) | 12 |

---

## Branching

PR-1 implementation work happens on `feat/playwright-demo-e2e-pr1` branched off `main`. The spec PR (`docs/playwright-demo-e2e-spec`, PR #39) stays separate so the design review doesn't tangle with implementation review.

```bash
cd ~/Works/greentic/greentic-e2e
git fetch origin
git checkout main
git pull --ff-only origin main
git checkout -b feat/playwright-demo-e2e-pr1
```

---

## Task 1: Resolve preflight unknowns (no code)

**Files:** none (notes captured in PR description and any spec deltas)

**Why this is Task 1:** The spec §13 lists six open questions that affect concrete implementation choices in later tasks. Resolving them upfront prevents rework. None of these require write access — all are local inspection or Slack confirmation.

- [ ] **Step 1: Confirm `gtc start --port` flag exists**

```bash
which gtc || cargo binstall -y gtc
gtc start --help 2>&1 | grep -E '\-\-port|GREENTIC_PORT'
```

Expected: a flag matching `--port <PORT>` or an env var `GREENTIC_PORT`. Note which one. The fixture in Task 6 uses whichever exists.

- [ ] **Step 2: Confirm bundle artifact selection (gtbundle vs gtpack) for `gtc setup`**

```bash
gtc setup --help 2>&1 | grep -A2 -E 'bundle|pack'
gtc wizard --help 2>&1 | head -30
```

Expected: clarity on which file `gtc setup` consumes. Cross-check `cloud-demo-e2e.yml` and `provider-e2e.yml` patterns in this repo to see which artifact they pass.

- [ ] **Step 3: Inspect WebChat DOM for `helpdesk-itsm`**

```bash
mkdir -p /tmp/webchat-inspect && cd /tmp/webchat-inspect
gtc wizard --answers https://github.com/greenticai/greentic-demo/releases/latest/download/helpdesk-itsm-create-answers.json
gtc setup --no-ui ./helpdesk-itsm-demo-bundle \
  --answers https://github.com/greenticai/greentic-demo/releases/latest/download/helpdesk-itsm-setup-answers.json
gtc start ./helpdesk-itsm-demo-bundle &
GTC_PID=$!
sleep 10
curl -s http://127.0.0.1:8080/readyz && echo " OK"
# Open in browser:
xdg-open http://127.0.0.1:8080/v1/web/webchat/helpdesk-itsm/ 2>/dev/null \
  || open http://127.0.0.1:8080/v1/web/webchat/helpdesk-itsm/
```

In DevTools, capture for the input field, send button, message-list container, bot message wrapper, and typing indicator (if any):
- accessible role (`getByRole('textbox')` etc.)
- accessible name
- `data-testid` attribute (if present)
- class names (last resort)

Write findings as a comment in the PR description so Task 7's POM uses real selectors. After capture:

```bash
kill $GTC_PID 2>/dev/null
```

- [ ] **Step 4: Confirm channel interpretation with Maarten**

Post in the Slack thread (reply to the original 12:54 AM message):

> Bima: confirming `-dev` vs `main` interpretation for the Playwright nightly. Plan: `stable` cell = `cargo binstall gtc` (latest published), `dev` cell = `cargo install --git https://github.com/greenticai/greentic --branch main --locked`. Sound right, or did you mean something else (tenant name, branch artifact, gtc dev subcommand)?

Wait for confirmation before Task 10 (workflow). If silence after 12h, proceed with the spec assumption — it's documented and trivial to flip via `playwright.config.ts` projects[] later.

- [ ] **Step 5: Decide on `weather-mcp-demo` and `cards-demo` (out of PR-1 scope, but record findings)**

```bash
gh release view v0.1.61 --repo greenticai/greentic-demo --json assets \
  | jq '[.assets[].name | select(contains("weather") or contains("cards"))]'
cat /tmp/webchat-inspect/helpdesk-itsm-demo-bundle/bundle.yaml 2>/dev/null \
  | grep -E 'secrets|env' | head -20
```

Note any secret env-var names exposed by demos for PR-2c reference. Not blocking for PR-1.

- [ ] **Step 6: Commit empty placeholder if anything required spec edits**

If Steps 1–5 surfaced corrections to spec §13 (e.g. flag name turned out to be `--listen-addr` not `--port`), edit the spec on this branch to reflect reality:

```bash
# Only if spec needs adjustment
$EDITOR docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md
git add docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md
git commit -m "docs(playwright): correct §13 preflight findings"
```

If no edits needed, skip. **Never** push the spec edit to PR #39's branch — keep it on the implementation branch and reviewers see both updates together.

---

## Task 2: Scaffold the `playwright/` sub-package

**Files:**
- Create: `playwright/package.json`
- Create: `playwright/package-lock.json` (generated by `npm install`)
- Create: `playwright/tsconfig.json`
- Create: `playwright/.gitignore`
- Create: `playwright/playwright.config.ts`

- [ ] **Step 1: Create directory and `package.json`**

```bash
mkdir -p playwright/tests/_fixtures playwright/scripts
cd playwright
```

```json
// playwright/package.json
{
  "name": "@greentic/demo-e2e-playwright",
  "private": true,
  "version": "0.1.0",
  "description": "Browser-driven e2e for greentic-demo bundles",
  "type": "module",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "test": "playwright test",
    "test:stable": "GTC_BIN=gtc-stable playwright test --project=stable",
    "test:dev": "GTC_BIN=gtc-dev playwright test --project=dev",
    "test:debug": "GTC_BIN=gtc-stable playwright test --project=stable --headed --debug",
    "show-report": "playwright show-report"
  },
  "devDependencies": {
    "@playwright/test": "^1.49.0",
    "@types/node": "^20.14.0",
    "typescript": "^5.5.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
// playwright/tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "types": ["node"]
  },
  "include": ["tests/**/*.ts", "scripts/**/*.ts", "playwright.config.ts"]
}
```

- [ ] **Step 3: Create `.gitignore`**

```gitignore
# playwright/.gitignore
node_modules/
test-results/
playwright-report/
playwright/.cache/
tmp/
*.local.ts
```

- [ ] **Step 4: Create `playwright.config.ts`**

```ts
// playwright/playwright.config.ts
import { defineConfig } from "@playwright/test";

const channel = (process.env.GTC_CHANNEL ?? "stable") as "stable" | "dev";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 4 : undefined,
  reporter: process.env.CI
    ? [["html", { open: "never" }], ["list"], ["github"]]
    : [["html", { open: "never" }], ["list"]],
  timeout: 120_000,
  expect: { timeout: 30_000 },
  use: {
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "stable",
      use: { browserName: "chromium" },
      metadata: { gtcBin: "gtc-stable" },
    },
    {
      name: "dev",
      use: { browserName: "chromium" },
      metadata: { gtcBin: "gtc-dev" },
    },
  ],
});
```

- [ ] **Step 5: Install deps and verify Playwright works**

```bash
npm install
npx playwright install --with-deps chromium
npx playwright --version
```

Expected: version printed (`1.49.x` or higher), `chromium` browser downloaded.

- [ ] **Step 6: Verify TS strict mode catches a deliberate error**

```bash
echo 'const x: number = "string";' > /tmp/_typecheck.ts
npx tsc --noEmit --project tsconfig.json 2>&1 || echo "tsc surfaces errors as expected"
rm -f /tmp/_typecheck.ts
```

Expected: tsc exits non-zero only if the bogus file gets included; otherwise the project compiles clean (no test files yet).

- [ ] **Step 7: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/package.json playwright/package-lock.json playwright/tsconfig.json playwright/.gitignore playwright/playwright.config.ts
git commit -m "feat(playwright): scaffold sub-package with TS strict + projects[stable, dev]"
```

---

## Task 3: Implement `bootstrap-gtc.sh`

**Files:**
- Create: `playwright/scripts/bootstrap-gtc.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Make executable + shellcheck clean**

```bash
chmod +x playwright/scripts/bootstrap-gtc.sh
shellcheck playwright/scripts/bootstrap-gtc.sh || sudo apt-get install -y shellcheck && shellcheck playwright/scripts/bootstrap-gtc.sh
```

Expected: shellcheck reports no errors. If it flags `SC2086` etc., fix inline.

- [ ] **Step 3: Manually exercise on local box (skip if already on a fresh runner)**

```bash
# Test stable path; this is destructive to your local gtc — back it up first if you depend on it.
which gtc && cp "$(which gtc)" /tmp/gtc.backup || true
bash playwright/scripts/bootstrap-gtc.sh stable
which gtc-stable && gtc-stable --version
ls -la "$HOME/.cargo/bin/gtc-stable" "$HOME/.cargo/bin/gtc-dev" 2>&1 | grep -v "No such" || true
```

Expected: `gtc-stable --version` prints version; `gtc-dev` not present yet.

- [ ] **Step 4: Test the dev path (longer build, ~3 min)**

```bash
bash playwright/scripts/bootstrap-gtc.sh dev
gtc-dev --version
```

Expected: dev binary built and installed at `~/.cargo/bin/gtc-dev`.

- [ ] **Step 5: Commit**

```bash
git add playwright/scripts/bootstrap-gtc.sh
git commit -m "feat(playwright): add bootstrap-gtc.sh for stable/dev channels"
```

---

## Task 4: Implement port allocator (TDD)

**Files:**
- Create: `playwright/tests/_fixtures/ports.ts`
- Create: `playwright/tests/_fixtures/ports.test.ts`

Convention: **all test files use the `*.spec.ts` extension**, including pure-logic unit tests under `_fixtures/`. They share the Playwright test runner; pure-logic ones simply skip browser work.

- [ ] **Step 1: Write the failing test**

```ts
// playwright/tests/_fixtures/ports.spec.ts
import { test, expect } from "@playwright/test";
import { allocatePort, BASE_PORT, PORTS_PER_WORKER } from "./ports";

test.describe("allocatePort (unit)", () => {
  test("worker 0 gets the base port range", () => {
    expect(allocatePort({ workerIndex: 0, fixtureIndex: 0 })).toBe(BASE_PORT);
    expect(allocatePort({ workerIndex: 0, fixtureIndex: 1 })).toBe(BASE_PORT + 1);
  });

  test("worker N is offset by N * PORTS_PER_WORKER", () => {
    expect(allocatePort({ workerIndex: 1, fixtureIndex: 0 })).toBe(BASE_PORT + PORTS_PER_WORKER);
    expect(allocatePort({ workerIndex: 4, fixtureIndex: 3 })).toBe(BASE_PORT + 4 * PORTS_PER_WORKER + 3);
  });

  test("fixtureIndex must stay below PORTS_PER_WORKER", () => {
    expect(() =>
      allocatePort({ workerIndex: 0, fixtureIndex: PORTS_PER_WORKER }),
    ).toThrow(/fixtureIndex .* must be < PORTS_PER_WORKER/);
  });
});
```

Also update `playwright.config.ts` — remove `testIgnore: ["**/*.test.ts"]` (now obsolete).

- [ ] **Step 2: Run test, verify it fails**

```bash
cd playwright
npx playwright test tests/_fixtures/ports.spec.ts --reporter=list
```

Expected: FAIL with `Cannot find module './ports'` or similar.

- [ ] **Step 3: Implement minimal code**

```ts
// playwright/tests/_fixtures/ports.ts
export const BASE_PORT = 8080;
export const PORTS_PER_WORKER = 100;

export interface PortAllocation {
  workerIndex: number;
  fixtureIndex: number;
}

export function allocatePort({ workerIndex, fixtureIndex }: PortAllocation): number {
  if (fixtureIndex < 0 || fixtureIndex >= PORTS_PER_WORKER) {
    throw new RangeError(
      `fixtureIndex ${fixtureIndex} must be < PORTS_PER_WORKER (${PORTS_PER_WORKER})`,
    );
  }
  if (workerIndex < 0) {
    throw new RangeError(`workerIndex ${workerIndex} must be >= 0`);
  }
  return BASE_PORT + workerIndex * PORTS_PER_WORKER + fixtureIndex;
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
npx playwright test tests/_fixtures/ports.spec.ts --reporter=list
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/tests/_fixtures/ports.ts playwright/tests/_fixtures/ports.spec.ts
git commit -m "feat(playwright): deterministic worker-isolated port allocator"
```

---

## Task 5: Implement `download-demo-assets.ts` (TDD)

**Files:**
- Create: `playwright/scripts/download-demo-assets.ts`
- Create: `playwright/tests/_fixtures/download-assets.spec.ts`

- [ ] **Step 1: Write the failing test (URL-building only, no network)**

```ts
// playwright/tests/_fixtures/download-assets.spec.ts
import { test, expect } from "@playwright/test";
import { releaseAssetUrl, demoAssetNames } from "../../scripts/download-demo-assets";

test.describe("releaseAssetUrl", () => {
  test("uses /releases/latest/download for stable channel", () => {
    expect(
      releaseAssetUrl("helpdesk-itsm-setup-answers.json", { tag: "latest" }),
    ).toBe(
      "https://github.com/greenticai/greentic-demo/releases/latest/download/helpdesk-itsm-setup-answers.json",
    );
  });

  test("uses /releases/download/<tag>/ for pinned version", () => {
    expect(
      releaseAssetUrl("helpdesk-itsm-setup-answers.json", { tag: "v0.1.61" }),
    ).toBe(
      "https://github.com/greenticai/greentic-demo/releases/download/v0.1.61/helpdesk-itsm-setup-answers.json",
    );
  });
});

test.describe("demoAssetNames", () => {
  test("returns the four files for a demo with full quartet", () => {
    expect(demoAssetNames("helpdesk-itsm")).toEqual({
      createAnswers: "helpdesk-itsm-create-answers.json",
      setupAnswers: "helpdesk-itsm-setup-answers.json",
      bundle: "helpdesk-itsm-demo.gtbundle",
      pack: "helpdesk-itsm.gtpack",
    });
  });
});
```

- [ ] **Step 2: Run test, verify it fails**

```bash
cd playwright
npx playwright test tests/_fixtures/download-assets.spec.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// playwright/scripts/download-demo-assets.ts
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { createHash } from "node:crypto";

const REPO = "greenticai/greentic-demo";

export interface AssetTag {
  tag: "latest" | string;
}

export interface DemoAssetNames {
  createAnswers: string;
  setupAnswers: string;
  bundle: string;
  pack: string;
}

export function releaseAssetUrl(filename: string, { tag }: AssetTag): string {
  if (tag === "latest") {
    return `https://github.com/${REPO}/releases/latest/download/${filename}`;
  }
  return `https://github.com/${REPO}/releases/download/${tag}/${filename}`;
}

export function demoAssetNames(demoName: string): DemoAssetNames {
  return {
    createAnswers: `${demoName}-create-answers.json`,
    setupAnswers: `${demoName}-setup-answers.json`,
    bundle: `${demoName}-demo.gtbundle`,
    pack: `${demoName}.gtpack`,
  };
}

export interface DownloadOpts {
  tag?: string;
  cacheDir?: string;
  fetchImpl?: typeof fetch;
}

/** Downloads a single asset to cacheDir/<filename>; reuses cached copy if present. */
export async function ensureAsset(
  filename: string,
  opts: DownloadOpts = {},
): Promise<string> {
  const tag = opts.tag ?? "latest";
  const cacheDir = opts.cacheDir ?? join(process.cwd(), "tmp", "demo-assets", tag);
  const dest = join(cacheDir, filename);

  if (existsSync(dest)) {
    return dest;
  }

  const url = releaseAssetUrl(filename, { tag });
  const fetcher = opts.fetchImpl ?? fetch;
  const res = await fetcher(url, { redirect: "follow" });
  if (!res.ok) {
    throw new Error(`download failed: ${url} → ${res.status} ${res.statusText}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, buf);
  return dest;
}

/** Downloads the canonical setup-answers JSON for a demo and parses it. */
export async function loadSetupAnswers(
  demoName: string,
  opts: DownloadOpts = {},
): Promise<Record<string, unknown>> {
  const path = await ensureAsset(demoAssetNames(demoName).setupAnswers, opts);
  return JSON.parse(await readFile(path, "utf8"));
}

/** Returns the path to the cached bundle file (download if missing). */
export async function ensureBundle(
  demoName: string,
  opts: DownloadOpts = {},
): Promise<string> {
  return ensureAsset(demoAssetNames(demoName).bundle, opts);
}

/** Sha256 of a file — used to detect cache corruption between runs. */
export async function sha256OfFile(path: string): Promise<string> {
  const data = await readFile(path);
  return createHash("sha256").update(data).digest("hex");
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
npx playwright test tests/_fixtures/download-assets.spec.ts
```

Expected: 3 tests pass.

- [ ] **Step 5: Smoke-test the network path manually**

```bash
cd playwright
node --input-type=module -e "
  import('./scripts/download-demo-assets.ts').then(async (m) => {
    const path = await m.ensureAsset('helpdesk-itsm-setup-answers.json', { cacheDir: '/tmp/demo-cache-smoke' });
    console.log('downloaded to', path);
    const sha = await m.sha256OfFile(path);
    console.log('sha256', sha);
  });
"
```

Expected: file appears under `/tmp/demo-cache-smoke/` and a sha is printed. If `node` rejects raw TS imports, install `tsx` (`npm install --save-dev tsx`) and run `npx tsx -e "..."`.

- [ ] **Step 6: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/scripts/download-demo-assets.ts playwright/tests/_fixtures/download-assets.spec.ts
git commit -m "feat(playwright): demo asset download + cache utility"
```

---

## Task 6: Implement the `gtcDemo` fixture

**Files:**
- Create: `playwright/tests/_fixtures/gtc-demo.ts`

- [ ] **Step 1: Write the failing fixture-integration test**

The fixture itself can only be exercised end-to-end. Write the helpdesk-itsm spec stub first so we have a failing test, then build the fixture to satisfy it.

```ts
// playwright/tests/helpdesk-itsm.spec.ts (provisional — full version in Task 8)
import { test, expect } from "./_fixtures/gtc-demo";

test("helpdesk-itsm: gtcDemo fixture starts demo and exposes a reachable URL", async ({ gtcDemo }) => {
  const demo = await gtcDemo({ name: "helpdesk-itsm" });
  expect(demo.name).toBe("helpdesk-itsm");
  expect(demo.demoUrl).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/v1\/web\/webchat\/helpdesk-itsm\/$/);

  const res = await fetch(demo.demoUrl.replace(/\/v1\/web\/webchat\/.+/, "/readyz"));
  expect(res.status).toBe(200);
});
```

- [ ] **Step 2: Run, verify it fails**

```bash
cd playwright
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --reporter=list
```

Expected: FAIL — `Cannot find module './_fixtures/gtc-demo'`.

- [ ] **Step 3: Implement the fixture (full)**

```ts
// playwright/tests/_fixtures/gtc-demo.ts
import { test as base, expect, type TestInfo } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { createWriteStream, existsSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { allocatePort } from "./ports";
import {
  ensureAsset,
  demoAssetNames,
} from "../../scripts/download-demo-assets";

export interface GtcDemo {
  name: string;
  port: number;
  demoUrl: string;
  bundleDir: string;
  logFile: string;
}

export interface DemoOptions {
  name: string;
  /** Override the default release setup-answers JSON. */
  setupAnswers?: Record<string, unknown>;
  /** Extra env passed to gtc setup/start. */
  envOverrides?: Record<string, string>;
  /** Skip the test if any of these env vars are unset. */
  skipIfMissingSecrets?: string[];
  /** Pin to a specific greentic-demo release tag. Default: "latest". */
  releaseTag?: string;
}

interface RunningDemo extends GtcDemo {
  proc: ChildProcess;
}

const GTC_BIN = process.env.GTC_BIN ?? "gtc";
const REPO_TMP_BASE = join(process.cwd(), "tmp");

async function ensureBundleExtracted(
  demoName: string,
  workerIndex: number,
  releaseTag: string,
): Promise<string> {
  const cacheDir = join(REPO_TMP_BASE, `worker-${workerIndex}`, demoName);
  const bundlePath = join(cacheDir, `${demoName}-demo-bundle`);
  if (existsSync(join(bundlePath, "bundle.yaml"))) {
    return bundlePath;
  }
  await mkdir(cacheDir, { recursive: true });

  // Fetch + apply the create-answers wizard, which materializes the bundle dir.
  const createAnswersPath = await ensureAsset(
    demoAssetNames(demoName).createAnswers,
    { tag: releaseTag, cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag) },
  );
  await runOrThrow(GTC_BIN, ["wizard", "--answers", createAnswersPath], cacheDir);

  if (!existsSync(bundlePath)) {
    throw new Error(`expected ${bundlePath} after gtc wizard, not found`);
  }
  return bundlePath;
}

async function downloadSetupAnswers(
  demoName: string,
  releaseTag: string,
): Promise<string> {
  return ensureAsset(
    demoAssetNames(demoName).setupAnswers,
    { tag: releaseTag, cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag) },
  );
}

async function runOrThrow(
  cmd: string,
  args: string[],
  cwd: string,
  env?: Record<string, string>,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    p.stderr?.on("data", (d) => (stderr += d.toString()));
    p.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} ${args.join(" ")} exited ${code}\n${stderr}`));
    });
    p.on("error", reject);
  });
}

async function gtcSetup(
  bundleDir: string,
  setupAnswersPath: string,
  envOverrides?: Record<string, string>,
): Promise<void> {
  await runOrThrow(
    GTC_BIN,
    ["setup", "--no-ui", bundleDir, "--answers", setupAnswersPath],
    bundleDir,
    envOverrides,
  );
}

async function gtcStart(
  bundleDir: string,
  port: number,
  logFile: string,
  envOverrides?: Record<string, string>,
): Promise<ChildProcess> {
  // NOTE: --port flag assumed; if Task 1 Step 1 found a different mechanism,
  // adapt the args/env here.
  await mkdir(join(bundleDir, "..", "logs"), { recursive: true }).catch(() => {});
  const logStream = createWriteStream(logFile, { flags: "w" });
  const proc = spawn(
    GTC_BIN,
    ["start", bundleDir, "--port", String(port)],
    {
      cwd: bundleDir,
      env: { ...process.env, ...envOverrides, GREENTIC_PORT: String(port) },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  proc.stdout?.pipe(logStream);
  proc.stderr?.pipe(logStream);
  return proc;
}

async function waitForReady(port: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/readyz`);
      if (res.ok) return;
      lastErr = `status ${res.status}`;
    } catch (e) {
      lastErr = e;
    }
    await sleep(500);
  }
  throw new Error(`/readyz not ready after ${timeoutMs}ms (last: ${String(lastErr)})`);
}

async function stopGtc(proc: ChildProcess): Promise<void> {
  if (proc.exitCode !== null) return;
  proc.kill("SIGTERM");
  const killed = await Promise.race([
    new Promise<boolean>((res) => proc.once("exit", () => res(true))),
    sleep(5_000).then(() => false),
  ]);
  if (!killed && proc.exitCode === null) {
    proc.kill("SIGKILL");
    await new Promise<void>((res) => proc.once("exit", () => res()));
  }
}

export const test = base.extend<{
  gtcDemo: (opts: DemoOptions) => Promise<GtcDemo>;
}>({
  gtcDemo: async ({}, use, testInfo: TestInfo) => {
    const created: RunningDemo[] = [];

    const factory = async (opts: DemoOptions): Promise<GtcDemo> => {
      for (const key of opts.skipIfMissingSecrets ?? []) {
        if (!process.env[key]) {
          testInfo.skip(true, `missing env var: ${key}`);
        }
      }

      const port = allocatePort({
        workerIndex: testInfo.workerIndex,
        fixtureIndex: created.length,
      });
      const releaseTag = opts.releaseTag ?? "latest";

      const bundleDir = await ensureBundleExtracted(opts.name, testInfo.workerIndex, releaseTag);

      let setupAnswersPath: string;
      if (opts.setupAnswers) {
        setupAnswersPath = join(bundleDir, "..", `setup-answers-override-${opts.name}.json`);
        await writeFile(setupAnswersPath, JSON.stringify(opts.setupAnswers, null, 2));
      } else {
        setupAnswersPath = await downloadSetupAnswers(opts.name, releaseTag);
      }

      await gtcSetup(bundleDir, setupAnswersPath, opts.envOverrides);

      const logFile = join(bundleDir, "..", `gtc-${opts.name}-w${testInfo.workerIndex}.log`);
      const proc = await gtcStart(bundleDir, port, logFile, opts.envOverrides);

      try {
        await waitForReady(port);
      } catch (e) {
        await stopGtc(proc);
        await testInfo.attach(`gtc-log-${opts.name}-startup-fail`, {
          path: logFile,
          contentType: "text/plain",
        });
        throw e;
      }

      const handle: RunningDemo = {
        name: opts.name,
        port,
        demoUrl: `http://127.0.0.1:${port}/v1/web/webchat/${opts.name}/`,
        bundleDir,
        logFile,
        proc,
      };
      created.push(handle);
      return handle;
    };

    await use(factory);

    for (const h of created) {
      await stopGtc(h.proc);
      if (testInfo.status === "failed" || testInfo.status === "timedOut") {
        await testInfo.attach(`gtc-log-${h.name}`, {
          path: h.logFile,
          contentType: "text/plain",
        });
      }
    }
  },
});

export { expect };
```

> If Task 1 Step 1 found that `gtc start` does not support `--port`, replace the `args` array and the env-var setup in `gtcStart()` with the discovered mechanism (e.g. `--listen-addr 127.0.0.1:${port}` or solely `GREENTIC_PORT`).

> If Task 1 Step 2 found that `gtc setup` consumes a different artifact than the bundle directory (e.g. needs the `.gtbundle` archive directly), update `gtcSetup` accordingly.

- [ ] **Step 4: Run, verify the integration test passes**

```bash
cd playwright
bash scripts/bootstrap-gtc.sh stable      # ensure gtc-stable available
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --reporter=list
```

Expected: 1 test passes (the provisional fixture-integration test from Step 1). If `/readyz` times out, check `tmp/worker-0/helpdesk-itsm/gtc-helpdesk-itsm-w0.log` for clues.

- [ ] **Step 5: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/tests/_fixtures/gtc-demo.ts playwright/tests/helpdesk-itsm.spec.ts
git commit -m "feat(playwright): gtcDemo fixture with bundle/setup/start lifecycle"
```

---

## Task 7: Implement the `WebChat` POM

**Files:**
- Create: `playwright/tests/_fixtures/webchat-page.ts`

> The selectors below are the placeholders from spec §6.1. **Before writing code**, walk through Task 1 Step 3's findings. If the real DOM differs, replace the selectors in this task before committing.

- [ ] **Step 1: Write the POM**

```ts
// playwright/tests/_fixtures/webchat-page.ts
import { Page, Locator, expect } from "@playwright/test";

export class WebChat {
  readonly page: Page;
  readonly url: string;
  private readonly input: Locator;
  private readonly sendBtn: Locator;
  private readonly typingIndicator: Locator;

  constructor(page: Page, url: string) {
    this.page = page;
    this.url = url;
    // TODO(Task 1 Step 3 findings): adjust if real DOM differs.
    this.input = page.getByRole("textbox", { name: /message|chat|type/i });
    this.sendBtn = page.getByRole("button", { name: /send/i });
    this.typingIndicator = page.locator(
      '[data-testid="typing-indicator"], .typing-indicator',
    );
  }

  async open(): Promise<void> {
    await this.page.goto(this.url, { waitUntil: "networkidle" });
    await expect(this.input).toBeVisible({ timeout: 30_000 });
    await expect(this.input).toBeEnabled();
  }

  async send(text: string): Promise<void> {
    await this.input.fill(text);
    await this.sendBtn.click();
    // Confirm user echo appears
    await expect(this.page.getByText(text, { exact: false })).toBeVisible({
      timeout: 5_000,
    });
  }

  async awaitReply(opts: { timeoutMs?: number; minLength?: number } = {}): Promise<string> {
    const timeout = opts.timeoutMs ?? 30_000;
    const minLength = opts.minLength ?? 1;
    const startCount = await this.botMessageCount();

    await expect
      .poll(() => this.botMessageCount(), { timeout, intervals: [500, 1_000, 2_000] })
      .toBeGreaterThan(startCount);

    if ((await this.typingIndicator.count()) > 0) {
      await expect(this.typingIndicator).toBeHidden({ timeout: timeout / 2 });
    }

    const last = await this.lastBotMessageText();
    if (last.length < minLength) {
      throw new Error(`bot reply too short: got ${last.length} chars, want >= ${minLength}`);
    }
    return last;
  }

  async awaitCardWithText(matcher: RegExp | string, timeoutMs = 30_000): Promise<Locator> {
    const card = this.page.locator(".ac-container").filter({ hasText: matcher });
    await expect(card.first()).toBeVisible({ timeout: timeoutMs });
    return card.first();
  }

  async clickCardAction(label: string | RegExp): Promise<void> {
    await this.page.getByRole("button", { name: label }).click();
  }

  private botMessageSelector(): Locator {
    // TODO(Task 1 Step 3 findings): adjust to actual DOM.
    return this.page.locator('[data-from="bot"], .bot-message, .from-bot');
  }

  private async botMessageCount(): Promise<number> {
    return this.botMessageSelector().count();
  }

  private async lastBotMessageText(): Promise<string> {
    return this.botMessageSelector().last().innerText();
  }
}
```

- [ ] **Step 2: Type-check the file**

```bash
cd playwright
npx tsc --noEmit
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/tests/_fixtures/webchat-page.ts
git commit -m "feat(playwright): WebChat POM with smoke + card helpers"
```

---

## Task 8: Implement `helpdesk-itsm.spec.ts` (smoke + functional + negative)

**Files:**
- Modify: `playwright/tests/helpdesk-itsm.spec.ts` (replace provisional version from Task 6)

- [ ] **Step 1: Replace the provisional spec with the full one**

```ts
// playwright/tests/helpdesk-itsm.spec.ts
import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

test.describe("helpdesk-itsm demo (Phase 0 walking skeleton)", () => {
  test("smoke: page loads, input interactive, bot replies non-empty without error markers", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("Hello");

    const reply = await chat.awaitReply({ minLength: 10, timeoutMs: 30_000 });
    expect(reply, "bot reply should not contain error markers").not.toMatch(ERROR_MARKERS);
  });

  test("functional: ticket-related intent gets a relevant reply", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("I need to report a printer issue");

    const reply = await chat.awaitReply({ minLength: 10 });
    expect(reply).not.toMatch(ERROR_MARKERS);
    expect(reply, "reply should reference ticketing/issue/printer").toMatch(
      /ticket|issue|printer|created|reported/i,
    );
  });

  test("negative: a reply that contains an error marker should fail the test", async ({
    page,
    gtcDemo,
  }) => {
    // This test asserts the *positive* behavior: bot does NOT echo error markers.
    // It exists to catch the failure mode where 5xx responses get rendered as bot
    // text. If the bot ever does emit "Internal Server Error" verbatim, this catches it.
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("status please");

    const reply = await chat.awaitReply({ minLength: 1, timeoutMs: 30_000 });
    expect(reply).not.toMatch(ERROR_MARKERS);
  });
});
```

- [ ] **Step 2: Run all three tests against the stable channel locally**

```bash
cd playwright
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --reporter=list
```

Expected: 3 tests pass. If a test fails because the bot doesn't include `ticket|issue|printer|created|reported`, capture a screenshot from the trace and either (a) widen the regex if the demo's actual response uses a synonym, or (b) flag this as a real demo regression and stop — Maarten needs to know.

- [ ] **Step 3: Run against the dev channel**

```bash
bash scripts/bootstrap-gtc.sh dev
GTC_BIN=gtc-dev npx playwright test helpdesk-itsm --project=dev --reporter=list
```

Expected: 3 tests pass. If `gtc-dev` build fails because of the versioning bug Maarten flagged to Vlad, document the gap in the PR description and proceed with stable-only validation in Task 11.

- [ ] **Step 4: Commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/tests/helpdesk-itsm.spec.ts
git commit -m "test(playwright): helpdesk-itsm smoke + functional + negative"
```

---

## Task 9: Local end-to-end validation

**Files:** none (validation only)

- [ ] **Step 1: Clean run from a fresh state**

```bash
cd playwright
rm -rf tmp/ test-results/ playwright-report/ node_modules/
npm ci
npx playwright install chromium
bash scripts/bootstrap-gtc.sh stable
GTC_BIN=gtc-stable npx playwright test --project=stable
```

Expected: all `helpdesk-itsm` tests pass green.

- [ ] **Step 2: Open the HTML report and inspect the trace**

```bash
npx playwright show-report
```

Expected: HTML report opens. Verify trace, screenshot, video are NOT attached for passing tests (we configured `only-on-failure` / `retain-on-failure`).

- [ ] **Step 3: Inject a transient failure and verify artifact capture**

Edit `playwright/tests/helpdesk-itsm.spec.ts` smoke test temporarily:

```ts
// Change:
const reply = await chat.awaitReply({ minLength: 10, timeoutMs: 30_000 });
// To:
const reply = await chat.awaitReply({ minLength: 99999, timeoutMs: 30_000 });
```

```bash
GTC_BIN=gtc-stable npx playwright test helpdesk-itsm --project=stable --reporter=list || true
ls test-results/
npx playwright show-report
```

Expected: failure captures `trace.zip`, `video.webm`, screenshot, and the gtc log via the fixture's `attach()`. Confirm by clicking through the HTML report.

- [ ] **Step 4: Revert the transient failure**

```bash
git checkout -- playwright/tests/helpdesk-itsm.spec.ts
```

Confirm with `git diff` that there are no changes pending.

- [ ] **Step 5: No commit**

This task validates; no code changes leak into the branch.

---

## Task 10: Implement the GHA workflow

**Files:**
- Create: `.github/workflows/demo-playwright.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/demo-playwright.yml
name: Nightly demo Playwright e2e

on:
  schedule:
    - cron: '30 3 * * *'   # 03:30 UTC, after nightly-e2e (00:00) & cloud-demo (02:00)
  workflow_dispatch:
    inputs:
      gtc_channel:
        description: 'gtc channel(s)'
        type: choice
        options: [both, stable, dev]
        default: both
      demo_filter:
        description: 'comma-separated demo names, or "all"'
        default: 'all'

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  e2e:
    name: ${{ matrix.label }}
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 60
    strategy:
      fail-fast: false
      matrix:
        include:
          - label: stable / linux
            runner: ubuntu-24.04
            channel: stable
          - label: dev / linux
            runner: ubuntu-24.04
            channel: dev
          - label: stable / macos
            runner: macos-15
            channel: stable
    env:
      GTC_CHANNEL: ${{ matrix.channel }}
      DEMO_FILTER: ${{ inputs.demo_filter || 'all' }}
    steps:
      - uses: actions/checkout@v4

      - name: Bootstrap Rust 1.95 + wasm32-wasip2
        shell: bash
        run: |
          set -euo pipefail
          if ! command -v rustup >/dev/null 2>&1; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
              | sh -s -- -y --profile minimal --default-toolchain 1.95.0
            echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
          fi
          rustup toolchain install 1.95.0 --profile minimal
          rustup default 1.95.0
          rustup target add wasm32-wasip2 --toolchain 1.95.0
          rustc --version

      - name: Install OS deps (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update -y && sudo apt-get install -y squashfs-tools jq

      - name: Install gtc (channel = ${{ matrix.channel }})
        shell: bash
        run: bash playwright/scripts/bootstrap-gtc.sh "${GTC_CHANNEL}"

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'
          cache-dependency-path: playwright/package-lock.json

      - name: Install npm deps
        working-directory: playwright
        run: npm ci

      - name: Install Playwright browsers
        working-directory: playwright
        run: npx playwright install --with-deps chromium

      - name: Run Playwright
        working-directory: playwright
        env:
          GTC_BIN: gtc-${{ matrix.channel }}
          DEMO_FILTER: ${{ env.DEMO_FILTER }}
        run: npx playwright test --project="${GTC_CHANNEL}"

      - name: Upload Playwright report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report-${{ matrix.label }}
          path: playwright/playwright-report/
          retention-days: 14

      - name: Upload failures (traces, videos, gtc logs)
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-failures-${{ matrix.label }}
          path: |
            playwright/test-results/
            playwright/tmp/**/gtc-*.log
          retention-days: 14
```

- [ ] **Step 2: Validate the YAML**

```bash
cd ~/Works/greentic/greentic-e2e
yamllint .github/workflows/demo-playwright.yml || true     # advisory
gh workflow view demo-playwright.yml --repo greenticai/greentic-e2e 2>&1 || true
```

The `gh workflow view` will fail with "not found" until pushed; that's expected.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/demo-playwright.yml
git commit -m "ci(demo-playwright): add nightly workflow + workflow_dispatch"
```

- [ ] **Step 4: Push the branch and trigger a manual run**

```bash
git push -u origin feat/playwright-demo-e2e-pr1
gh workflow run demo-playwright.yml \
  --repo greenticai/greentic-e2e \
  --ref feat/playwright-demo-e2e-pr1 \
  -f gtc_channel=stable -f demo_filter=helpdesk-itsm
```

Wait for it to finish:

```bash
gh run list --repo greenticai/greentic-e2e --workflow=demo-playwright.yml --limit 1
gh run watch --repo greenticai/greentic-e2e $(gh run list --repo greenticai/greentic-e2e --workflow=demo-playwright.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected: `stable / linux` cell green. `dev / linux` may fail if the upstream `cargo install --git main` build is broken (Maarten flagged this to Vlad — document in PR if so).

---

## Task 11: CI validation — artifacts + Slack notifier

**Files:**
- Modify (temporarily): `playwright/tests/helpdesk-itsm.spec.ts`
- (Revert before final merge)

- [ ] **Step 1: Inject a deterministic failure on the branch**

```bash
sed -i.bak 's/minLength: 10/minLength: 99999/' playwright/tests/helpdesk-itsm.spec.ts
git diff playwright/tests/helpdesk-itsm.spec.ts
```

- [ ] **Step 2: Push the failure as a separate commit so it's easy to revert**

```bash
git add playwright/tests/helpdesk-itsm.spec.ts
git commit -m "ci(playwright): TEMP intentional fail to verify artifact upload [revert]"
git push
```

- [ ] **Step 3: Trigger the workflow and confirm artifact + Slack notifier**

```bash
gh workflow run demo-playwright.yml \
  --repo greenticai/greentic-e2e \
  --ref feat/playwright-demo-e2e-pr1 \
  -f gtc_channel=stable -f demo_filter=helpdesk-itsm
gh run watch --repo greenticai/greentic-e2e $(gh run list --repo greenticai/greentic-e2e --workflow=demo-playwright.yml --limit 1 --json databaseId -q '.[0].databaseId')
```

Expected:
- Workflow fails on the `stable / linux` cell.
- Artifacts `playwright-report-stable / linux` and `playwright-failures-stable / linux` exist.
- The catch-all `notify-scheduled-failures.yml` fires a Slack message.

Verify by:

```bash
gh run download $(gh run list --repo greenticai/greentic-e2e --workflow=demo-playwright.yml --limit 1 --json databaseId -q '.[0].databaseId') \
  --repo greenticai/greentic-e2e --dir /tmp/pw-artifacts
ls -la /tmp/pw-artifacts/
# inspect playwright-failures-* — should contain trace.zip, video, gtc log
```

Check `#engineering` or whichever channel `notify-scheduled-failures.yml` posts to for the Slack alert; if no alert appears within 5 min, audit `.github/workflows/notify-scheduled-failures.yml` to confirm it covers `demo-playwright.yml` (it should, since it's a catch-all).

- [ ] **Step 4: Revert the deterministic failure**

```bash
mv playwright/tests/helpdesk-itsm.spec.ts.bak playwright/tests/helpdesk-itsm.spec.ts
git add playwright/tests/helpdesk-itsm.spec.ts
git commit -m "Revert \"ci(playwright): TEMP intentional fail to verify artifact upload\""
git push
```

> The two commits — the TEMP and its revert — stay in branch history as evidence the artifact pipeline was validated. Reviewers can squash-merge to drop them.

- [ ] **Step 5: Re-run the workflow to confirm green state**

```bash
gh workflow run demo-playwright.yml --repo greenticai/greentic-e2e --ref feat/playwright-demo-e2e-pr1 -f gtc_channel=stable -f demo_filter=helpdesk-itsm
```

Expected: green run, no Slack alert.

---

## Task 12: Documentation polish + PR

**Files:**
- Create: `playwright/README.md`
- Modify: `CLAUDE.md` (greentic-e2e root) — add pointer at `playwright/`
- Modify: `docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` — flip status to `accepted` (only after design PR #39 merges; if it hasn't, leave alone)

- [ ] **Step 1: Write `playwright/README.md`**

```markdown
# Playwright Demo E2E

Browser-driven nightly e2e for `greentic-demo` bundles. Sub-package of `greentic-e2e/`.

See `../docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` for design rationale.

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
3. Run locally, then push and trigger `gh workflow run demo-playwright.yml -f demo_filter=<demo-name>`.

## Failure triage

1. Check the GHA run summary for which matrix cell failed.
2. Download the `playwright-failures-<label>` artifact.
3. `npx playwright show-trace test-results/<failing-test>/trace.zip`.
4. Inspect the gtc log in the same artifact for category-B (lifecycle) failures.

## Out of scope

This sub-package covers WebChat browser-driven demo testing only. Provider-specific HTTP ingress lives in `provider-e2e.yml`. Cloud deploy lives in `cloud-demo-e2e.yml`. Designer/Admin UI lives in their respective repos.
```

- [ ] **Step 2: Update root `CLAUDE.md`**

```bash
# Append a section pointing at playwright/
cat >> CLAUDE.md <<'EOF'

## Playwright sub-package

Browser-driven demo e2e lives under `playwright/`. See `playwright/README.md` for local dev workflow and `docs/superpowers/specs/2026-04-27-playwright-demo-e2e-design.md` for design.
EOF
```

> If the existing `CLAUDE.md` already structures sections differently, integrate the pointer where it fits naturally rather than appending.

- [ ] **Step 3: Type-check + lint pass before final push**

```bash
cd playwright
npx tsc --noEmit
npx playwright test --project=stable
```

Expected: clean.

- [ ] **Step 4: Final commit**

```bash
cd ~/Works/greentic/greentic-e2e
git add playwright/README.md CLAUDE.md
git commit -m "docs(playwright): README + root CLAUDE pointer"
git push
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --draft \
  --base main \
  --head feat/playwright-demo-e2e-pr1 \
  --title "feat(playwright): PR-1 walking skeleton — helpdesk-itsm demo" \
  --body "$(cat <<'EOF'
## Summary

PR-1 of the Playwright demo e2e suite (see design at #39). Ships:

- `playwright/` sub-package: TypeScript strict, `@playwright/test`, `projects: [stable, dev]`.
- `gtcDemo` fixture: per-test bundle download → setup → start → wait /readyz → teardown with on-failure log/screenshot/trace/video capture.
- `WebChat` POM with smoke + card helpers.
- One spec: `helpdesk-itsm.spec.ts` (smoke + functional ticket-intent + negative error-marker).
- `bootstrap-gtc.sh`: installs `gtc-stable` (binstall) and/or `gtc-dev` (`cargo install --git main`) and runs `gtc install` (also exercises Maarten's mksquashfs/cargo-component/wasm32-wasip2 fix).
- `.github/workflows/demo-playwright.yml`: nightly @ 03:30 UTC + workflow_dispatch, matrix `[stable / linux, dev / linux, stable / macos]`.
- `playwright/README.md` + root `CLAUDE.md` pointer.

## Test plan

- [x] Clean local run on Linux passes.
- [x] HTML report inspected — passing tests do NOT attach traces/videos (only-on-failure).
- [x] Intentional failure (Task 11) confirmed artifact upload (trace, video, screenshot, gtc log) and Slack notifier fires.
- [x] `dev / linux` cell verified — green / has documented gap (see PR comments).
- [ ] Reviewer: pull branch and run `cd playwright && npm ci && npx playwright install chromium && bash scripts/bootstrap-gtc.sh stable && npm run test:stable`.

## Out of scope (deferred to PR-2)

- 12 other demos (quickstart, hr-onboarding, incident-demo, sales-crm, supply-chain, telco-x-demo, redbutton, cards-demo, deep-research-demo, greentic-ai, github-mcp, weather-mcp-demo).
- Adaptive Card flows.
- macOS / dev cell.
- Custom GHA summary reporter.

## Open items confirmed during PR-1 (per spec §13)

(Filled in by implementer based on Task 1 findings.)

## Closes / references

- Design spec: #39
EOF
)"
```

- [ ] **Step 6: Mark PR ready when comfortable**

After self-review and at least one teammate skim:

```bash
gh pr ready
```

---

## Acceptance gate (must hold before merging PR-1)

- [ ] All 12 tasks above show all checkboxes ticked.
- [ ] `npm run test:stable` passes from a clean `node_modules/` on Linux and macOS.
- [ ] GHA `stable / linux` is green for `helpdesk-itsm` on the latest pushed commit.
- [ ] Failure artifacts (trace, video, screenshot, gtc log) confirmed via the Task 11 intentional-failure run.
- [ ] Slack notifier confirmed firing on intentional failure.
- [ ] `dev / linux` is green OR has a documented gap in the PR description with `@vlad` tagged.
- [ ] PR #39 (design spec) approved or has at least Maarten/Vahe/Osoro skim.
- [ ] No regressions in `provider-e2e.yml`, `cloud-demo-e2e.yml`, `nightly-e2e.yml`, `webchat-passthrough-e2e.yml` (verify by running them on the branch via `gh workflow run`).

---

## Notes for the implementer

- TDD discipline: write the failing assertion, run it, then implement. Do not write the implementation first and back-fill tests.
- Keep commits small and scoped to one task. The plan structure mirrors commits.
- If a task surfaces an unanticipated issue (e.g. `gtc start --port` truly does not exist), pause and update both the spec §13 and this plan in the same commit before proceeding.
- Do not add dependencies beyond `@playwright/test`, `@types/node`, `typescript`. If you find you need `tsx` for Task 5 Step 5 only, that's fine; otherwise resist.
- The plan stops at PR-1. PR-2 will be planned separately once PR-1 is stable in nightly for at least 2 consecutive runs.
