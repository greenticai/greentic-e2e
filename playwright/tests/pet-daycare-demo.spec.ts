import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, dirname } from "node:path";

// The pet-daycare demo is the fast2flow showcase: it opts into
// `greentic.cap.fast2flow.v1` and ships `assets/intent-index.json`, so a
// free-text message is BM25-routed to a card via `routeToCardId` — no LLM key
// required. The default min-confidence (0.5) is too strict for the short
// marker-free utterances this demo ships, so we relax it to 0.05.
const FAST2FLOW_ENV = { FAST2FLOW_MIN_CONFIDENCE: "0.05" };

// Emitted by greentic-start when fast2flow can't route free text. Asserting its
// ABSENCE proves a dispatch happened. The card text uses a curly apostrophe
// (U+2019) — "I’m not sure…" — so match straight OR curly (or none).
const NO_DISPATCH_FALLBACK = /I['’]?m not sure what you meant/i;
const ERROR_MARKERS = /error|exception|panic|stack trace/i;

const demoOpts = { name: "pet-daycare-demo", envOverrides: FAST2FLOW_ENV } as const;

// fast2flow is two-tier: the deterministic BM25 host, then an LLM fallback
// (greentic-start fast2flow/llm_router.rs) that fires ONLY when BM25 returns no
// confident match AND the bundle declares a top-level `llm:` block. We exercise
// both outcomes with one paraphrased "boarding" request that shares no tokens
// with any intent's tags/utterances, plus a strict 0.5 deterministic threshold
// so BM25 returns Continue: without an LLM it falls back; with one it routes.
const STRICT_FAST2FLOW_ENV = { FAST2FLOW_MIN_CONFIDENCE: "0.5" };
const LLM_ONLY_UTTERANCE =
  "we're traveling for two weeks and need somewhere our pup can be cared for through the nights";
// boarding_card title: "Book Boarding (Overnight Stay)".
const BOARDING_CARD = /Book Boarding|Boarding|Overnight/i;
// LLM tier gated on a real backend (DeepSeek — a native greentic-llm provider,
// ProviderKind::Deepseek). Mirrors deep-research-demo's env-gated pattern.
const DEEPSEEK_KEY = process.env.DEEPSEEK_KEY?.trim();
const llmDemoOpts = {
  name: "pet-daycare-demo",
  envOverrides: STRICT_FAST2FLOW_ENV,
  bundleLlm: {
    provider: "deepseek",
    model: process.env.DEEPSEEK_MODEL?.trim() || "deepseek-chat",
    // env-var NAME greentic-start resolves the key from (gtcStart passes env).
    api_key_secret: "DEEPSEEK_KEY",
    fast2flow_llm_min_confidence: 0.3,
  },
} as const;
// Same utterance, no `llm:` block — the deterministic tier alone can't route it.
const noLlmSemanticOpts = {
  name: "pet-daycare-demo",
  envOverrides: STRICT_FAST2FLOW_ENV,
} as const;

test.describe("pet-daycare-demo (fast2flow routing + confidence)", () => {
  test("smoke: welcome card auto-renders", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo(demoOpts);
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    // Welcome card is autoStarted on connect: "Pet Daycare Front Desk".
    await expect(
      page.locator(".ac-container").filter({ hasText: /Pet Daycare/i }).first(),
    ).toBeVisible({ timeout: 30_000 });

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  test("functional: free-text 'who is here today' routes to the attendance card", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo(demoOpts);
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.locator(".ac-container").filter({ hasText: /Pet Daycare/i }).first(),
    ).toBeVisible({ timeout: 30_000 });

    // Natural language → fast2flow BM25 match → dispatch to attendance_card.
    await chat.send("who is here today");

    // Routing assertion: the attendance card renders, and we did NOT get the
    // "I'm not sure what you meant" no-dispatch fallback.
    await chat.awaitCardWithText(/Today'?s Attendance|attendance/i, 30_000);
    const body = await page.locator("body").innerText();
    expect(body, "fast2flow should dispatch, not fall back").not.toMatch(
      NO_DISPATCH_FALLBACK,
    );
    expect(body).not.toMatch(ERROR_MARKERS);

    // Confidence assertion — capability-gated. greentic-start only emits the
    // `[fast2flow] dispatch … confidence=…` line once it carries
    // greenticai/greentic-start#227. On older toolchains the line is absent and
    // we skip rather than fail; once it ships, this becomes a hard assertion
    // with no test change.
    const dispatch = findFast2flowDispatch(demo.bundleDir, demo.logFile);
    test.skip(
      dispatch === null,
      "toolchain predates greentic-start#227 (no `[fast2flow] dispatch … confidence=` line); routing asserted, confidence skipped",
    );
    console.log(
      `[pet-daycare-demo] fast2flow dispatch target=${dispatch!.target} confidence=${dispatch!.confidence}`,
    );
    expect(
      dispatch!.confidence,
      "dispatched match should clear the 0.05 min-confidence threshold",
    ).toBeGreaterThanOrEqual(0.05);
    expect(dispatch!.confidence).toBeLessThanOrEqual(1.0);
  });

  test("functional: gibberish yields the no-dispatch fallback", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo(demoOpts);
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.locator(".ac-container").filter({ hasText: /Pet Daycare/i }).first(),
    ).toBeVisible({ timeout: 30_000 });

    await chat.send("asdf qwerty zxcvb nonsense");
    const reply = await chat.awaitReply({ timeoutMs: 30_000 });
    expect(reply, "unmatched free text should hit the no-dispatch fallback").toMatch(
      NO_DISPATCH_FALLBACK,
    );
  });

  // --- LLM routing tier: works when an LLM is present, falls back when not. ---

  test("functional: semantic free-text falls back when no LLM is configured", async ({
    page,
    gtcDemo,
  }) => {
    // No `llm:` block → only the deterministic BM25 tier runs. A paraphrased
    // boarding request scores below the 0.5 threshold, so fast2flow returns
    // Continue and (with no LLM to consult) degrades to the no-dispatch reply.
    const demo = await gtcDemo(noLlmSemanticOpts);
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.locator(".ac-container").filter({ hasText: /Pet Daycare/i }).first(),
    ).toBeVisible({ timeout: 30_000 });

    await chat.send(LLM_ONLY_UTTERANCE);
    const reply = await chat.awaitReply({ timeoutMs: 30_000 });
    expect(
      reply,
      "BM25 can't match a paraphrase and there is no LLM tier, so it must fall back",
    ).toMatch(NO_DISPATCH_FALLBACK);
  });

  test("functional: the LLM tier routes the semantic utterance to boarding", async ({
    page,
    gtcDemo,
  }) => {
    // The LLM fallback tier needs a real backend. Soft-skip when DEEPSEEK_KEY
    // is absent (mirrors deep-research-demo) so the suite is green by default
    // and exercises real routing wherever the key is set.
    test.skip(
      !DEEPSEEK_KEY,
      "DEEPSEEK_KEY not set; fast2flow LLM routing tier not exercised",
    );
    const demo = await gtcDemo(llmDemoOpts);
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.locator(".ac-container").filter({ hasText: /Pet Daycare/i }).first(),
    ).toBeVisible({ timeout: 30_000 });

    // Same paraphrase the no-LLM case fell back on — now the LLM tier resolves it.
    await chat.send(LLM_ONLY_UTTERANCE);
    await chat.awaitCardWithText(BOARDING_CARD, 30_000);
    const body = await page.locator("body").innerText();
    expect(body, "LLM tier should dispatch, not fall back").not.toMatch(
      NO_DISPATCH_FALLBACK,
    );
    expect(body).not.toMatch(ERROR_MARKERS);

    // The LLM tier emits the pinned dispatch line with a real confidence/target
    // (llm_router.rs), independent of greentic-start#227 on the BM25 host.
    const dispatch = findFast2flowDispatch(demo.bundleDir, demo.logFile);
    if (dispatch !== null) {
      console.log(
        `[pet-daycare-demo] fast2flow LLM dispatch target=${dispatch.target} confidence=${dispatch.confidence}`,
      );
      expect(dispatch.target).toMatch(/boarding/i);
      expect(
        dispatch.confidence,
        "LLM dispatch should clear its 0.3 min-confidence threshold",
      ).toBeGreaterThanOrEqual(0.3);
      expect(dispatch.confidence).toBeLessThanOrEqual(1.0);
    }
  });
});

interface Fast2flowDispatch {
  target: string;
  confidence: number;
}

// Scan greentic-start's logs for the pinned dispatch line:
//   [fast2flow] dispatch target=<t> confidence=<c.3> reason=<r>
// operator_log writes to `<log_dir>/system.log`; the exact log dir varies, so we
// search the worker tmp tree + the gtc stdout file + ~/.greentic/logs.
function findFast2flowDispatch(
  bundleDir: string,
  gtcLogFile: string,
): Fast2flowDispatch | null {
  const re = /\[fast2flow\]\s+dispatch\s+target=(\S+)\s+confidence=([0-9]+(?:\.[0-9]+)?)/;
  for (const file of candidateLogFiles(bundleDir, gtcLogFile)) {
    let content: string;
    try {
      content = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const m = content.match(re);
    if (m && m[1] && m[2]) {
      return { target: m[1], confidence: Number(m[2]) };
    }
  }
  return null;
}

function candidateLogFiles(bundleDir: string, gtcLogFile: string): string[] {
  const files = new Set<string>();
  if (gtcLogFile) files.add(gtcLogFile);
  const home = process.env.HOME;
  if (home) files.add(join(home, ".greentic", "logs", "system.log"));
  // Walk the worker tmp tree (bundle's parent) for *.log up to a small depth.
  walkLogs(dirname(bundleDir), 4, files);
  walkLogs(bundleDir, 4, files);
  return [...files];
}

function walkLogs(root: string, depth: number, out: Set<string>): void {
  if (depth < 0 || !existsSync(root)) return;
  let entries: string[];
  try {
    entries = readdirSync(root);
  } catch {
    return;
  }
  for (const name of entries) {
    const full = join(root, name);
    let st;
    try {
      st = statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) {
      walkLogs(full, depth - 1, out);
    } else if (name.endsWith(".log")) {
      out.add(full);
    }
  }
}
