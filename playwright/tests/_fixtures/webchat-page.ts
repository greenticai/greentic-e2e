import { Page, Locator, expect } from "@playwright/test";

export class WebChat {
  readonly page: Page;
  readonly url: string;
  private readonly input: Locator;
  private readonly sendBtn: Locator;
  private readonly typingIndicator: Locator;

  constructor(page: Page, url: string) {
    this.page = page;
    this.url = url;
    // TODO(Task 1 Step 3 findings): adjust selectors after real DOM inspection.
    this.input = page.getByRole("textbox", { name: /message|chat|type/i });
    this.sendBtn = page.getByRole("button", { name: /send/i });
    this.typingIndicator = page.locator(
      '[data-testid="typing-indicator"], .typing-indicator',
    );
  }

  async open(): Promise<void> {
    await this.page.goto(this.url, { waitUntil: "networkidle" });
    await expect(this.input).toBeVisible({ timeout: 30_000 });
    await expect(this.input).toBeEnabled();
  }

  async send(text: string): Promise<void> {
    await this.input.fill(text);
    await this.sendBtn.click();
    await expect(this.page.getByText(text, { exact: false })).toBeVisible({
      timeout: 5_000,
    });
  }

  async awaitReply(opts: { timeoutMs?: number; minLength?: number } = {}): Promise<string> {
    const timeout = opts.timeoutMs ?? 30_000;
    const minLength = opts.minLength ?? 1;
    const startCount = await this.botMessageCount();

    await expect
      .poll(() => this.botMessageCount(), { timeout, intervals: [500, 1_000, 2_000] })
      .toBeGreaterThan(startCount);

    if ((await this.typingIndicator.count()) > 0) {
      await expect(this.typingIndicator).toBeHidden({ timeout: timeout / 2 });
    }

    const last = await this.lastBotMessageText();
    if (last.length < minLength) {
      throw new Error(`bot reply too short: got ${last.length} chars, want >= ${minLength}`);
    }
    return last;
  }

  async awaitCardWithText(matcher: RegExp | string, timeoutMs = 30_000): Promise<Locator> {
    const card = this.page.locator(".ac-container").filter({ hasText: matcher });
    await expect(card.first()).toBeVisible({ timeout: timeoutMs });
    return card.first();
  }

  async clickCardAction(label: string | RegExp): Promise<void> {
    await this.page.getByRole("button", { name: label }).click();
  }

  private botMessageSelector(): Locator {
    // TODO(Task 1 Step 3 findings): adjust to actual DOM.
    return this.page.locator('[data-from="bot"], .bot-message, .from-bot');
  }

  private async botMessageCount(): Promise<number> {
    return this.botMessageSelector().count();
  }

  private async lastBotMessageText(): Promise<string> {
    return this.botMessageSelector().last().innerText();
  }
}
