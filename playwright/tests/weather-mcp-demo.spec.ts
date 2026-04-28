import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

test.describe("weather-mcp-demo (PR-1 walking skeleton)", () => {
  test("smoke: chat loads, connects, accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "weather-mcp-demo" });
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

  test("functional: bot replies (skipped without weather API key)", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({
      name: "weather-mcp-demo",
      skipIfMissingSecrets: ["WEATHER_API_KEY"],
    });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.send("What's the weather in Jakarta?");

    const reply = await chat.awaitReply({ minLength: 30, timeoutMs: 60_000 });
    expect(reply).not.toMatch(ERROR_MARKERS);
  });
});
