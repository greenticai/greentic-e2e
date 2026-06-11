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
