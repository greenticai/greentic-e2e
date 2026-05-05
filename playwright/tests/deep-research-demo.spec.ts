import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

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
    await questionInput.fill("Tell me about renewable energy");

    // Click Single Shot → routes to research_analyst LLM node.
    await welcomeCard
      .first()
      .locator("button.ac-pushButton")
      .filter({ hasText: /Single Shot/i })
      .first()
      .click();

    // Research Analyst result card (final_report.json) appears and first shows
    // "Processing final report…" while the LLM runs.
    const analystCard = page
      .locator(".ac-container")
      .filter({ hasText: /Research Analyst/i });
    await expect(analystCard.first()).toBeVisible({ timeout: 30_000 });

    // Poll until "Processing final report..." disappears — LLM output is ready.
    await expect
      .poll(() => analystCard.last().innerText(), {
        timeout: 120_000,
        intervals: [2_000, 3_000, 5_000],
      })
      .not.toMatch(/Processing final report/i);

    const reply = await analystCard.last().innerText();
    console.log(`[deep-research-demo single-shot reply, ${reply.length} chars]\n${reply}`);
    expect(reply.length).toBeGreaterThan(50);
    expect(reply).not.toMatch(ERROR_MARKERS);
  });
});
