import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;

test.describe("helpdesk-itsm demo (Phase 0 walking skeleton)", () => {
  test("smoke: page loads, input interactive, bot replies non-empty without error markers", async ({
    page,
    gtcDemo,
  }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("Hello");

    const reply = await chat.awaitReply({ minLength: 10, timeoutMs: 30_000 });
    expect(reply, "bot reply should not contain error markers").not.toMatch(ERROR_MARKERS);
  });

  test("functional: ticket-related intent gets a relevant reply", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("I need to report a printer issue");

    const reply = await chat.awaitReply({ minLength: 10 });
    expect(reply).not.toMatch(ERROR_MARKERS);
    expect(reply, "reply should reference ticketing/issue/printer").toMatch(
      /ticket|issue|printer|created|reported/i,
    );
  });

  test("negative: a reply that contains an error marker should fail the test", async ({
    page,
    gtcDemo,
  }) => {
    // This test asserts the *positive* behavior: bot does NOT echo error markers.
    // It exists to catch the failure mode where 5xx responses get rendered as
    // bot text. If the bot ever does emit "Internal Server Error" verbatim, this
    // catches it.
    const demo = await gtcDemo({ name: "helpdesk-itsm" });
    const chat = new WebChat(page, demo.demoUrl);

    await chat.open();
    await chat.send("status please");

    const reply = await chat.awaitReply({ minLength: 1, timeoutMs: 30_000 });
    expect(reply).not.toMatch(ERROR_MARKERS);
  });
});
