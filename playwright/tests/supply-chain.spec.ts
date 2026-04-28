import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

// Welcome card title text (rendered on autoStart from
// flows/main entrypoint=show_welcome).
const WELCOME_TITLE = /Supply Chain Management/i;

// Each welcome-card button is an Action.Submit with
// data.routeToCardId = <asset-card-id>. Clicking dispatches the
// asset card directly through the messaging adapter (no flow re-run).
const NAV_BUTTONS: Array<{ label: RegExp; targetText: RegExp }> = [
  {
    label: /Track Orders/i,
    targetText: /(Order|Search Orders|Pipeline|Orders Search)/i,
  },
  {
    label: /Inventory Overview/i,
    targetText: /Inventory/i,
  },
  {
    label: /Manage Shipments/i,
    targetText: /Shipment/i,
  },
  {
    label: /Report Issue/i,
    targetText: /(Report|Issue)/i,
  },
];

test.describe("supply-chain demo (click-card flow)", () => {
  test("welcome card auto-renders on chat open", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "supply-chain" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    // The pack ships flow=main with single node show_welcome routing=End.
    // No user input required: autoStart triggers the flow which renders
    // welcome.json. Should NOT cascade to other cards.
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    // Spot-check that the cascade-bug regression isn't back: only the
    // welcome card should be rendered, not show_issue_confirm
    // ("Issue Submitted") that used to land last in the broken Next
    // chain.
    const issueSubmitted = page
      .locator(".ac-container")
      .filter({ hasText: /Issue Submitted/i });
    await expect(issueSubmitted).toHaveCount(0);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText, "page should not surface error markers").not.toMatch(
      ERROR_MARKERS,
    );
  });

  for (const { label, targetText } of NAV_BUTTONS) {
    test(`welcome -> ${label.source}: routeToCardId dispatches target card`, async ({
      page,
      gtcDemo,
    }) => {
      const demo = await gtcDemo({ name: "supply-chain" });
      const chat = new WebChat(page, demo.demoUrl);

      await chat.open();
      await expect(
        page.getByText(/Connectivity Status:\s*Connected/i),
      ).toBeVisible({ timeout: 30_000 });
      await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

      await chat.clickCardAction(label);

      // Target card should render via routeToCardId dispatch (asset
      // path resolves under assets/cards/<id>.json).
      await chat.awaitCardWithText(targetText, 15_000);

      const visibleText = await page.locator("body").innerText();
      expect(visibleText, "page should not surface error markers").not.toMatch(
        ERROR_MARKERS,
      );
    });
  }

  // Multi-hop journey: welcome -> Track Orders -> orders_search ->
  // "Find Order" -> orders_list -> "⬅️ Back" -> orders_search.
  // Validates that intermediate asset cards expose their own
  // routeToCardId nav buttons (not just the welcome card).
  test("journey: welcome -> orders_search -> orders_list -> back", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "supply-chain" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    // orders_search card uses "Track Order" as title and ships a
    // unique subtitle "Step 1 of 3 - Search by order number..." that
    // doesn't appear elsewhere — anchor on it to disambiguate from
    // welcome's "📦 Track Orders" button label.
    const ORDERS_SEARCH_MARK = /Search by order number/i;
    const ordersSearchCards = page
      .locator(".ac-container")
      .filter({ hasText: ORDERS_SEARCH_MARK });

    await chat.clickCardAction(/Track Orders/i);
    await chat.awaitCardWithText(ORDERS_SEARCH_MARK, 15_000);
    const ordersSearchBefore = await ordersSearchCards.count();

    await chat.clickCardAction(/Find Order/i);
    await chat.awaitCardWithText(/Order List/i, 15_000);

    // orders_list "⬅️ Back" routes back to orders_search; orders_search
    // also has "⬅️ Back to Menu". Anchor on end-of-text so we click the
    // right one.
    await chat.clickCardAction(/Back$/);
    // Verify a *new* orders_search instance was rendered (not just the
    // earlier one persisting in chat history).
    await expect
      .poll(() => ordersSearchCards.count(), {
        timeout: 15_000,
        intervals: [500, 1_000, 2_000],
      })
      .toBeGreaterThan(ordersSearchBefore);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText, "page should not surface error markers").not.toMatch(
      ERROR_MARKERS,
    );
  });
});
