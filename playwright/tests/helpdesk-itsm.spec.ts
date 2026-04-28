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
    await chat.send("Hello");

    const userArticle = page
      .locator("article")
      .filter({ hasText: "Hello" })
      .first();
    await expect(userArticle).toBeVisible({ timeout: 5_000 });

    const pageContent = await page.content();
    expect(pageContent, "page should not surface error markers").not.toMatch(
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
