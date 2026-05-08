import { existsSync, readFileSync } from "node:fs";
import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;
// Patterns that indicate the LLM call itself failed in the runner — fail
// the test immediately with the actual error instead of waiting out the
// 3-minute reply poll.
const LLM_FATAL_MARKERS: Array<{ re: RegExp; label: string }> = [
  { re: /insufficient_quota/i, label: "OpenAI quota exhausted (HTTP 429 insufficient_quota)" },
  { re: /provider returned status 401/i, label: "OpenAI auth rejected (HTTP 401)" },
  { re: /provider returned status 403/i, label: "OpenAI auth rejected (HTTP 403)" },
  { re: /provider returned status 5\d\d/i, label: "OpenAI upstream 5xx" },
  { re: /pack execution failed: component component-llm-/i, label: "LLM component crashed" },
];

function findLlmFatal(logFile: string): string | null {
  if (!existsSync(logFile)) return null;
  const content = readFileSync(logFile, "utf8");
  for (const { re, label } of LLM_FATAL_MARKERS) {
    if (re.test(content)) return label;
  }
  return null;
}

const RESEARCH_QUESTIONS = [
  [
    "Topic: renewable energy.",
    "Answer in one short sentence.",
    "1. Name one common source.",
    "2. Say one benefit.",
  ].join("\n"),
  [
    "Topic: quantum computing.",
    "Answer in one short sentence.",
    "1. What is a qubit?",
    "2. Why does it matter?",
  ].join("\n"),
  [
    "Topic: the Mediterranean diet.",
    "Answer in one short sentence.",
    "1. Name one core food.",
    "2. Name one health benefit.",
  ].join("\n"),
  [
    "Topic: mRNA vaccines.",
    "Answer in one short sentence.",
    "1. What do they do?",
    "2. Name one example.",
  ].join("\n"),
  [
    "Topic: electric vehicles.",
    "Answer in one short sentence.",
    "1. Name one benefit.",
    "2. Name one challenge.",
  ].join("\n"),
  [
    "Topic: large language models.",
    "Answer in one short sentence.",
    "1. What are they?",
    "2. Name one use case.",
  ].join("\n"),
  [
    "Topic: the Apollo program.",
    "Answer in one short sentence.",
    "1. What was its goal?",
    "2. Was it successful?",
  ].join("\n"),
  [
    "Topic: fusion energy.",
    "Answer in one short sentence.",
    "1. What is it?",
    "2. Why isn't it on the grid yet?",
  ].join("\n"),
  [
    "Topic: CRISPR.",
    "Answer in one short sentence.",
    "1. What does it do?",
    "2. Name one medical use.",
  ].join("\n"),
  [
    "Topic: coral reefs.",
    "Answer in one short sentence.",
    "1. Why are they declining?",
    "2. Name one main driver.",
  ].join("\n"),
];

function pickRandomQuestion(): string {
  return RESEARCH_QUESTIONS[Math.floor(Math.random() * RESEARCH_QUESTIONS.length)];
}

test.describe("deep-research-demo (PR-1 walking skeleton)", () => {
  test("smoke: chat loads, connects, accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "deep-research-demo" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    await chat.send("Hello");
    const userArticle = page
      .locator("article")
      .filter({ hasText: "Hello" })
      .first();
    await expect(userArticle).toBeVisible({ timeout: 5_000 });

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  // Bot reply requires an LLM. Either:
  //   - OPENAI_API_KEY set (real OpenAI), or
  //   - LOCAL_LLM=1 with a local Ollama at http://127.0.0.1:11434 serving
  //     the model the demo's setup-answers point to (gemma3:latest by default).
  //
  // Flow: welcome card (main_menu.json) → fill textarea → click "Single Shot"
  // → research_analyst LLM node → final_report.json card (shows
  // "Processing…" then replaces with LLM output once done).
  test("functional: single-shot research query returns LLM answer (needs OPENAI_API_KEY or LOCAL_LLM=1)", async ({
    page,
    gtcDemo,
  }) => {
    test.skip(
      !process.env.OPENAI_API_KEY && process.env.LOCAL_LLM !== "1",
      "needs OPENAI_API_KEY or LOCAL_LLM=1 (with local Ollama running gemma3:latest)",
    );
    const demo = await gtcDemo({ name: "deep-research-demo" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    // The welcome card (main_menu.json) is sent automatically on connect via autoStart.
    const welcomeCard = page
      .locator(".ac-container")
      .filter({ hasText: /Deep Research Digital Worker/i });
    await expect(welcomeCard.first()).toBeVisible({ timeout: 30_000 });

    // Input.Text with isMultiline:true renders as <textarea> in Adaptive Cards.
    const questionInput = welcomeCard
      .first()
      .locator('textarea[placeholder="What do you want to research?"]');
    await expect(questionInput).toBeVisible({ timeout: 10_000 });
    const question = pickRandomQuestion();
    console.log(`[deep-research-demo single-shot question] ${question}`);
    await questionInput.fill(question);

    // Click Single Shot → routes to research_analyst LLM node.
    await welcomeCard
      .first()
      .locator("button.ac-pushButton")
      .filter({ hasText: /Single Shot/i })
      .first()
      .click();

    // After Single Shot the runner emits one or more new bot activities. The
    // exact card title can vary (Research Analyst / Final Report / generic
    // bot reply), so don't pin to a header — instead wait for any new bot
    // activity to appear in the transcript and grow until it stops looking
    // like the welcome/stock card.
    const STOCK_MARKERS = [
      /Deep Research Digital Worker/i, // welcome card title
      /What do you want to research\?/i, // welcome card prompt
      /Single Shot/i, // welcome card button label
      /Processing/i, // intermediate "Processing…" placeholder
    ];
    // One-sentence answers are intentional; require only a short non-empty
    // reply (>= 15 chars) that doesn't match any stock/processing marker.
    const isStock = (text: string): boolean =>
      STOCK_MARKERS.some((re) => re.test(text)) || text.trim().length < 15;

    const botFeed = page.getByRole("feed").locator("article");

    // Wait for the LLM-driven reply, but short-circuit on a fatal LLM error
    // surfaced in the gtc log (quota, auth, 5xx). Treat fatal as an
    // LLM-provider outage (quota, auth, 5xx, component crash) and
    // soft-skip — the flow is fine, the external dependency is broken.
    let reply = "";
    let fatal: string | null = null;
    await expect
      .poll(
        async () => {
          fatal = findLlmFatal(demo.logFile);
          if (fatal) return "__llm_fatal__";
          const count = await botFeed.count();
          if (count === 0) return "__no_bot_activity__";
          reply = (await botFeed.last().innerText()).trim();
          return isStock(reply) ? "__stock_or_processing__" : "__ready__";
        },
        {
          timeout: 180_000,
          intervals: [2_000, 3_000, 5_000],
        },
      )
      .toMatch(/^(?:__ready__|__llm_fatal__)$/);
    test.skip(
      fatal !== null,
      `LLM provider unavailable: ${fatal} (treating as test infra outage, not a flow regression)`,
    );

    console.log(
      `[deep-research-demo single-shot reply, ${reply.length} chars]\n${reply}`,
    );
    expect(reply.length).toBeGreaterThan(15);
    expect(reply).not.toMatch(ERROR_MARKERS);
    // Final guard: reply must not be a verbatim echo of any stock/welcome marker.
    for (const re of STOCK_MARKERS) {
      expect(reply, `reply still looks like stock content (${re})`).not.toMatch(re);
    }
  });
});
