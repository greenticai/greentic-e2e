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
});
