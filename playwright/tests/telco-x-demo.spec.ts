import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

// The telco-x demo opens with a category menu (Traffic, Capacity, RCA,
// Service Assurance, …). We don't pin to a specific label so the test
// stays robust as upstream renames or reorders categories — we just
// require the welcome card to expose at least one Action.Submit button
// and that clicking the first one produces a new bot activity.
test.describe("telco-x-demo (webchat category menu)", () => {
  test("smoke: chat loads, connects, accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "telco-x-demo" });
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

  test("welcome card auto-renders with at least one action button", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "telco-x-demo" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    // The welcome card is autoStarted on connect. Match by /Telco/i so the
    // test survives copy edits to the exact title ("Telco-X Assistant",
    // "Telco X", etc.).
    const welcomeCard = page
      .locator(".ac-container")
      .filter({ hasText: /Telco/i });
    await expect(welcomeCard.first()).toBeVisible({ timeout: 30_000 });

    const buttons = welcomeCard.first().locator("button.ac-pushButton");
    await expect(buttons.first()).toBeVisible({ timeout: 5_000 });
    expect(
      await buttons.count(),
      "welcome card should expose at least one Action.Submit",
    ).toBeGreaterThan(0);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  test("functional: clicking the first category produces a follow-up card", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "telco-x-demo" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    const welcomeCard = page
      .locator(".ac-container")
      .filter({ hasText: /Telco/i });
    await expect(welcomeCard.first()).toBeVisible({ timeout: 30_000 });

    const allCards = page.locator(".ac-container");
    const cardCountBefore = await allCards.count();

    const firstButton = welcomeCard
      .first()
      .locator("button.ac-pushButton")
      .first();
    const buttonLabel = (await firstButton.innerText()).trim();
    console.log(`[telco-x-demo] clicking welcome action: ${buttonLabel}`);
    await expect(firstButton).toBeVisible({ timeout: 10_000 });
    await firstButton.click();

    // A new Adaptive Card should render in response to the action — either
    // a sub-menu, a form, or a result card. We don't pin to the title or
    // contents (those vary per playbook), just to "transcript grew".
    await expect
      .poll(() => allCards.count(), {
        timeout: 30_000,
        intervals: [500, 1_000, 2_000],
      })
      .toBeGreaterThan(cardCountBefore);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });
});
