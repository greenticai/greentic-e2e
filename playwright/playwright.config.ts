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
