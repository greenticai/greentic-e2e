import { defineConfig } from "@playwright/test";

const channel = (process.env.GTC_CHANNEL ?? "stable") as "stable" | "dev";

// Local-dev escape hatch: hosts whose OS isn't on Playwright's supported list
// (e.g. ubuntu26 in early 2026) cannot `npx playwright install chromium`. Set
// PLAYWRIGHT_USE_SYSTEM_CHROME=1 to use system Google Chrome instead of the
// bundled Chromium. Empty in CI so ubuntu-24.04 keeps using the bundle.
const useSystemChrome = process.env.PLAYWRIGHT_USE_SYSTEM_CHROME === "1";
const browserUse = {
  browserName: "chromium" as const,
  ...(useSystemChrome ? { channel: "chrome" as const } : {}),
};

export default defineConfig({
  testDir: "./tests",
  // Active specs:
  //   - weather-mcp-demo, deep-research-demo, telco-x-demo: Adaptive Card driving pattern.
  //   - redbutton-demo: HTTP events-webhook ingress (no browser/card flow).
  // Other *.spec.ts files are walking-skeleton placeholders — re-enable
  // them once each one drives its card form + asserts on the LLM/tool
  // reply (or, for HTTP-only demos, hits the right ingress endpoint).
  testMatch: [
    "weather-mcp-demo.spec.ts",
    "deep-research-demo.spec.ts",
    "redbutton-demo.spec.ts",
    "telco-x-demo.spec.ts",
  ],
  // Serialize tests: greentic-start does not expose --port and binds the runner
  // to default 8080, so two concurrent demos would collide. Tests are short
  // (~30s each) so serialization is acceptable for now.
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
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
    // Video requires Playwright's bundled ffmpeg, which can't install on
    // unsupported host OSes (e.g. ubuntu26). Disable video locally when
    // PLAYWRIGHT_USE_SYSTEM_CHROME=1 so the run still produces trace+screenshot.
    video: useSystemChrome ? "off" : "retain-on-failure",
  },
  projects: [
    {
      name: "stable",
      use: browserUse,
      metadata: { gtcBin: "gtc-stable" },
    },
    {
      name: "dev",
      use: browserUse,
      metadata: { gtcBin: "gtc-dev" },
    },
  ],
});
