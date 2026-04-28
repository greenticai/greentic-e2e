import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

test.describe("sales-crm demo (PR-1 walking skeleton)", () => {
  test("smoke: chat loads, connects, accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "sales-crm" });
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
    expect(visibleText, "page should not surface error markers").not.toMatch(
      ERROR_MARKERS,
    );
  });
});
