import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

test.describe("helpdesk-itsm demo (Phase 0 walking skeleton)", () => {
  // Framework smoke: verify the chat infra is up end-to-end (page loads,
  // input interactive, send echoes into the transcript, no error markers
  // surfaced). Bot reply is NOT asserted here because helpdesk-itsm uses
  // LLM-driven Chat2Flow routing — undocumented dependency, see PR description
  // and §13.9 of the design spec for the full upstream punch list.
  test("smoke: chat loads and accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    // Wait for DirectLine to fully connect before sending — otherwise the
    // user message lands in a local queue and the user echo shows
    // "Sending…" status instead of being acknowledged by the runner.
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    await chat.send("Hello");

    const userArticle = page
      .locator("article")
      .filter({ hasText: "Hello" })
      .first();
    await expect(userArticle).toBeVisible({ timeout: 5_000 });

    // Check VISIBLE body text — page.content() returns full HTML which
    // includes BotFramework framework class names like
    // 'webchat__submit-error-message' that match /error/i but are not
    // surfaced errors.
    const visibleText = await page.locator("body").innerText();
    expect(visibleText, "page should not surface error markers").not.toMatch(
      ERROR_MARKERS,
    );
  });

  test("connectivity: WebChat reports connected state", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();

    // BotFramework WebChat exposes the DirectLine connection status as text.
    // "Connected" indicates the runtime issued a DirectLine token and the
    // browser opened a WebSocket — i.e. the messaging-webchat-gui provider
    // and dev-store secret seeding are correctly wired.
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
  });

  // Bot-reply assertion gated on an LLM API key. The helpdesk-itsm flow uses
  // LLM-driven intent routing (Chat2Flow); without a real key, the bot stays
  // silent. Confirmed via CI run #7 page snapshot: feed contains user article
  // only, no bot reply, even for "I need to report a printer issue".
  //
  // Set OPENAI_API_KEY (or future ANTHROPIC_API_KEY) in repo Actions secrets,
  // then this test runs and asserts the demo's actual ticket-intent reply.
  test("functional: ticket-intent reply (skipped when LLM key absent)", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({
      name: "helpdesk-itsm",
      skipIfMissingSecrets: ["OPENAI_API_KEY"],
    });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("I need to report a printer issue");

    const reply = await chat.awaitReply({ minLength: 10, timeoutMs: 60_000 });
    expect(reply).not.toMatch(ERROR_MARKERS);
    expect(reply, "reply should reference ticketing/issue/printer").toMatch(
      /ticket|issue|printer|created|reported/i,
    );
  });
});

// Click-card flow: welcome.json auto-renders three Action.Submit
// buttons with `routeToCardId` data, dispatching the target asset
// card directly through the messaging adapter (no flow re-run, no
// LLM hop). Verified via probe run on 2026-04-29: welcome renders on
// chat open with 3 nav buttons, no cascade.
const HELPDESK_WELCOME_TITLE = /IT Help Desk/i;

const HELPDESK_NAV_BUTTONS: Array<{ label: RegExp; targetText: RegExp }> = [
  { label: /Create a Ticket/i, targetText: /Step 1 of 2 .* Create IT Ticket/i },
  { label: /My Tickets & Status/i, targetText: /Your Tickets & Status/i },
  { label: /Urgent: Call Center/i, targetText: /IT Help Desk Call Center/i },
];

test.describe("helpdesk-itsm demo (click-card flow)", () => {
  test("welcome card auto-renders on chat open", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });

    await chat.awaitCardWithText(HELPDESK_WELCOME_TITLE, 30_000);

    // Cascade-Next regression guard: only the welcome card should
    // render; downstream confirmation cards must not leak through.
    const ticketSubmitted = page
      .locator(".ac-container")
      .filter({ hasText: /Ticket Submitted/i });
    await expect(ticketSubmitted).toHaveCount(0);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText, "page should not surface error markers").not.toMatch(
      ERROR_MARKERS,
    );
  });

  test("smoke: every welcome button routes to its target card", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(HELPDESK_WELCOME_TITLE, 30_000);

    for (const { label, targetText } of HELPDESK_NAV_BUTTONS) {
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
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  // Multi-hop: welcome -> "My Tickets & Status" -> view_tickets ->
  // "⬅️ Back to Menu" -> welcome.
  // Pure-routing journey (no form gating). Validates that
  // intermediate asset cards expose their own routeToCardId nav and
  // that the "Back to Menu" loop returns to the welcome entrypoint.
  // (The create_ticket flow is form-gated — its required fields would
  // need fill steps before "Next" dispatches; covered separately
  // when form-fill behavior is in scope.)
  test("journey: welcome -> view_tickets -> back to welcome", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await expect(
      page.getByText(/Connectivity Status:\s*Connected/i),
    ).toBeVisible({ timeout: 30_000 });
    await chat.awaitCardWithText(HELPDESK_WELCOME_TITLE, 30_000);

    const welcomeCards = page
      .locator(".ac-container")
      .filter({ hasText: HELPDESK_WELCOME_TITLE });
    const welcomeBefore = await welcomeCards.count();

    await chat.clickCardAction(/My Tickets & Status/i);
    await chat.awaitCardWithText(/Your Tickets & Status/i, 15_000);

    // view_tickets "⬅️ Back to Menu" routes back to welcome. Welcome
    // card was already in chat history from autoStart, so count-poll
    // ensures a *new* welcome instance was rendered post-click rather
    // than passing on the stale one.
    await chat.clickCardAction(/Back to Menu/i);
    await expect
      .poll(() => welcomeCards.count(), {
        timeout: 15_000,
        intervals: [500, 1_000, 2_000],
      })
      .toBeGreaterThan(welcomeBefore);

    const visibleText = await page.locator("body").innerText();
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });
});
