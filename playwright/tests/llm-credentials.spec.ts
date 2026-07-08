import { test, expect } from "@playwright/test";
import { checkDeepseekLlm } from "./_fixtures/llm-preflight";

// Dedicated credential-health canary — deliberately NOT using the `gtcDemo`
// fixture, so it needs no bundle setup and no browser page. It's one HTTP
// call, done in well under a second, so it runs before (and far cheaper
// than) any of the ~30s-3min demo flows below.
//
// The demo functional tests (deep-research-demo, pet-daycare-demo) *skip*
// on any LLM preflight failure, on purpose — some of those failures are
// known, pre-existing infra limitations (see deep-research-demo.spec.ts's
// KNOWN LIMITATION note), not something a secret rotation can fix. That
// means a genuinely broken DEEPSEEK_KEY — expired, revoked, or rate-limited
// — would otherwise show up only as a handful of quietly skipped tests,
// easy to miss in a CI summary. This test FAILS instead, so a bad secret is
// one obvious red line, not a pattern you have to notice across skips.
test.describe("LLM credentials", () => {
  test("DEEPSEEK_KEY answers a live call (not invalid, revoked, or rate-limited)", async () => {
    const key = process.env.DEEPSEEK_KEY?.trim();
    test.skip(!key, "DEEPSEEK_KEY not set — nothing to validate");

    const result = await checkDeepseekLlm();
    expect(result.ok, result.ok ? undefined : result.reason).toBe(true);
  });
});
