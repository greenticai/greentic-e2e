import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

// Welcome-card title rendered on autoStart from flows/main
// (single node show_welcome_card, routing=End).
const WELCOME_TITLE = /Sales CRM Assistant/i;

// Each Action.Submit on welcome_card carries data.routeToCardId
// pointing to an asset card. Click dispatches via messaging adapter
// without re-running the flow, so we should land on the target card
// rather than re-rendering welcome.
const NAV_BUTTONS: Array<{ label: RegExp; targetText: RegExp }> = [
  { label: /^New Lead$/i, targetText: /(Lead|Prospect)/i },
  { label: /View Pipeline/i, targetText: /Sales Pipeline/i },
  { label: /My Deals/i, targetText: /Initech Platform Upgrade/i },
  { label: /Schedule Meeting/i, targetText: /Schedule Meeting/i },
];

test.describe("sales-crm demo (click-card flow)", () => {
  test("welcome card auto-renders without literal {{var}} placeholders", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "sales-crm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    // Regression guard: the cards used to ship Mustache-style
    // `${{total_value}}`/`{{deal_count}}` etc. without a data binder.
    // After the static-demo-data fix, no literal '{{' should leak into
    // the rendered DOM.
    const visibleText = await page.locator("body").innerText();
    expect(
      visibleText,
      "rendered chat must not contain unsubstituted {{var}} placeholders",
    ).not.toMatch(/\{\{[a-z_]+\}\}/i);

    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  test("View Pipeline shows static deal data (no template leaks)", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "sales-crm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    await chat.clickCardAction(/View Pipeline/i);

    // pipeline_card was rewritten with hard-coded demo numbers and
    // three static stage sections; verify the headline metrics + at
    // least one stage + at least one deal land in the DOM.
    await chat.awaitCardWithText(/Sales Pipeline/i, 15_000);
    await expect(
      page.locator(".ac-container").filter({ hasText: /\$1,245,000/ }).first(),
    ).toBeVisible({ timeout: 5_000 });
    await expect(
      page.locator(".ac-container").filter({ hasText: /Qualification/i }).first(),
    ).toBeVisible({ timeout: 5_000 });
    await expect(
      page
        .locator(".ac-container")
        .filter({ hasText: /Initech Platform Upgrade/i })
        .first(),
    ).toBeVisible({ timeout: 5_000 });

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(/\{\{[a-z_]+\}\}/i);
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  // Combined smoke: all welcome buttons clicked in one session.
  // Validates routeToCardId dispatch + sequential interaction. Also
  // re-checks no `{{var}}` placeholders leaked into any subsequently
  // rendered card. test.step() preserves per-button failure reports.
  test("smoke: every welcome button routes to its target card", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "sales-crm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    for (const { label, targetText } of NAV_BUTTONS) {
      await test.step(`click "${label.source}" -> render target card`, async () => {
        const targetCards = page
          .locator(".ac-container")
          .filter({ hasText: targetText });
        const before = await targetCards.count();
        await chat.clickCardAction(label);
        await expect
          .poll(() => targetCards.count(), {
            timeout: 15_000,
            intervals: [500, 1_000, 2_000],
          })
          .toBeGreaterThan(before);
      });
    }

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(/\{\{[a-z_]+\}\}/i);
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  // Multi-hop journey: welcome -> My Deals -> deal_detail
  // -> "Schedule Meeting" -> meeting_card.
  // Validates routeToCardId chains across more than one hop and that
  // deal_detail's static demo data ("Initech Platform Upgrade",
  // $120,000, Proposal stage) renders correctly after the click.
  test("journey: welcome -> deal_detail -> meeting", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "sales-crm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    await chat.clickCardAction(/My Deals/i);
    await chat.awaitCardWithText(/Initech Platform Upgrade/i, 15_000);
    await expect(
      page.locator(".ac-container").filter({ hasText: /\$120,000/ }).first(),
    ).toBeVisible({ timeout: 5_000 });
    await expect(
      page.locator(".ac-container").filter({ hasText: /Proposal/i }).first(),
    ).toBeVisible({ timeout: 5_000 });

    await chat.clickCardAction(/^Schedule Meeting$/i);
    await chat.awaitCardWithText(/Schedule Meeting/i, 15_000);
    // meeting_card has form inputs (not the welcome buttons).
    await expect(
      page.getByRole("textbox", { name: /Meeting Subject/i }),
    ).toBeVisible({ timeout: 10_000 });

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(/\{\{[a-z_]+\}\}/i);
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });
});
