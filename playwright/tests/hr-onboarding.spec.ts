import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

// Welcome-card title resolved from i18n
// (card.welcome_card body header).
const WELCOME_TITLE = /Acme Corp\s*-\s*HR Onboarding/i;

// welcome_card.json action_id -> routeToCardId mapping; titles are
// i18n keys that resolve in en.json via component-adaptive-card's
// i18n_inline machinery.
const NAV_BUTTONS: Array<{ label: RegExp; targetText: RegExp }> = [
  { label: /Start Onboarding/i, targetText: /New Employee Registration/i },
  { label: /Check Progress/i, targetText: /Onboarding Checklist/i },
  { label: /Upload Documents/i, targetText: /Required Documents/i },
  { label: /Request Access/i, targetText: /System Access Request/i },
];

test.describe("hr-onboarding demo (click-card flow)", () => {
  test("welcome card auto-renders on chat open", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "hr-onboarding" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    // Pack ships flow=on_message with single node welcome routing=End.
    // No user input required: autoStart triggers the flow which
    // renders welcome_card and stops.
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    // Regression guard: the cascade-Next bug (#142) used to leave
    // users on `show_completion_card` ("Onboarding Complete!"). After
    // the fix, the completion card must NOT appear unless the user
    // explicitly drives the flow there.
    const completion = page
      .locator(".ac-container")
      .filter({ hasText: /Onboarding Complete/i });
    await expect(completion).toHaveCount(0);

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
      const demo = await gtcDemo({ name: "hr-onboarding" });
      const chat = new WebChat(page, demo.demoUrl);

      await chat.open();
      await expect(
        page.getByText(/Connectivity Status:\s*Connected/i),
      ).toBeVisible({ timeout: 30_000 });
      await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

      await chat.clickCardAction(label);
      await chat.awaitCardWithText(targetText, 15_000);

      const visibleText = await page.locator("body").innerText();
      expect(visibleText).not.toMatch(ERROR_MARKERS);
    });
  }

  // Multi-hop journey: welcome -> Start Onboarding -> employee_form
  // -> "Confirm Registration" -> onboarding_checklist
  // -> "Back to Menu" -> welcome_card.
  // Validates that intermediate cards expose their own routeToCardId
  // nav, and that the "Back to Menu" loop returns to the welcome
  // entrypoint.
  test("journey: welcome -> employee_form -> checklist -> back to welcome", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "hr-onboarding" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(WELCOME_TITLE, 30_000);

    await chat.clickCardAction(/Start Onboarding/i);
    await chat.awaitCardWithText(/New Employee Registration/i, 15_000);

    await chat.clickCardAction(/Confirm Registration/i);
    await chat.awaitCardWithText(/Onboarding Checklist/i, 15_000);

    // "Back to Menu" on onboarding_checklist routes back to welcome.
    await chat.clickCardAction(/Back to Menu/i);
    await chat.awaitCardWithText(WELCOME_TITLE, 15_000);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });
});
