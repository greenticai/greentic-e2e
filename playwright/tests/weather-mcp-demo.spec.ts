import type { Locator } from "@playwright/test";
import { test, expect } from "./_fixtures/gtc-demo";
import { WebChat } from "./_fixtures/webchat-page";

const ERROR_MARKERS = /error|exception|panic|stack trace/i;
const CAPITAL_CITIES: Array<{ city: string; country: string }> = [
  { city: "Nairobi", country: "Kenya" },
  { city: "Jakarta", country: "Indonesia" },
  { city: "Paris", country: "France" },
  { city: "Tokyo", country: "Japan" },
  { city: "Ottawa", country: "Canada" },
  { city: "Canberra", country: "Australia" },
];

test.describe("weather-mcp-demo", () => {
  test("smoke: chat loads, connects, accepts user input", async ({ page, gtcDemo }) => {
    const demo = await gtcDemo({ name: "weather-mcp-demo" });
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
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  test(
    "functional: current weather and forecast use random cities from the capital collection",
    async ({ page, gtcDemo }) => {
      const demo = await gtcDemo({
        name: "weather-mcp-demo",
        skipIfMissingSecrets: ["WEATHER_API_KEY"],
      });
      const [currentCase, forecastCase] = pickDistinctRandomCities(2);

      await test.step(`current weather: ${currentCase.city}`, async () => {
        const chat = new WebChat(page, demo.demoUrl);
        await chat.open();
        await expect(
          page.getByText(/Connectivity Status:\s*Connected/i),
        ).toBeVisible({ timeout: 30_000 });

        const assistantCard = await ensureWeatherAssistantCard(chat);
        const resultCard = await submitWeatherCard(chat, assistantCard, {
          city: currentCase.city,
          actionLabel: /Current Weather/i,
          days: "3",
        });
        await expect(resultCard).toContainText(
          `Location: ${currentCase.city}, ${currentCase.country}`,
        );
        await expect(resultCard).toContainText(/Temp /i);
        await expect(resultCard).toContainText(/Feels /i);
        await expect(resultCard).toContainText(/Wind /i);

        const visibleText = await page.locator("body").innerText();
        expect(visibleText).not.toMatch(ERROR_MARKERS);
      });

      await test.step(`forecast weather: ${forecastCase.city}`, async () => {
        const chat = new WebChat(page, demo.demoUrl);
        await chat.open();
        await expect(
          page.getByText(/Connectivity Status:\s*Connected/i),
        ).toBeVisible({ timeout: 30_000 });

        const assistantCard = await ensureWeatherAssistantCard(chat);
        const resultCard = await submitWeatherCard(chat, assistantCard, {
          city: forecastCase.city,
          actionLabel: /Forecast Weather/i,
          days: "3",
        });
        await expect(resultCard).toContainText(
          `Location: ${forecastCase.city}, ${forecastCase.country}`,
        );
        await expect(resultCard).toContainText(/Today /i);
        await expect(resultCard).toContainText(/High /i);
        await expect(resultCard).toContainText(/Low /i);
        await expect(resultCard).toContainText(/Chance of rain/i);

        const visibleText = await page.locator("body").innerText();
        expect(visibleText).not.toMatch(ERROR_MARKERS);
      });
    },
  );
});

async function ensureWeatherAssistantCard(chat: WebChat) {
  const page = chat.page;
  const existing = page.locator(".ac-container").filter({ hasText: /Weather Assistant/i }).last();
  if (await existing.isVisible().catch(() => false)) {
    return existing;
  }

  await chat.send("Hello");
  const assistantCard = page
    .locator(".ac-container")
    .filter({ hasText: /Weather Assistant/i })
    .last();
  await expect(assistantCard).toBeVisible({ timeout: 30_000 });
  await expect(assistantCard).toContainText(/Current Weather/i);
  await expect(assistantCard).toContainText(/Forecast Weather/i);
  return assistantCard;
}

async function submitWeatherCard(
  chat: WebChat,
  assistantCard: Locator,
  opts: { city: string; actionLabel: RegExp; days: string },
) {
  const page = chat.page;
  const beforeCount = await page.locator(".ac-container").count();
  const cityInput = assistantCard.locator('input[placeholder="Nairobi"]').last();
  await expect(cityInput).toBeVisible({ timeout: 10_000 });
  await cityInput.fill(opts.city);

  const daysInput = assistantCard.locator('input[placeholder="3"]').last();
  if (await daysInput.count()) {
    await daysInput.fill(opts.days);
  }

  await assistantCard
    .locator("button.ac-pushButton")
    .filter({ hasText: opts.actionLabel })
    .first()
    .click();

  await expect
    .poll(() => page.locator(".ac-container").count(), {
      timeout: 60_000,
      intervals: [500, 1_000, 2_000],
    })
    .toBeGreaterThan(beforeCount);

  const resultCard = page
    .locator(".ac-container")
    .filter({ hasText: new RegExp(`Location:\\s*${escapeRegex(opts.city)},`, "i") })
    .last();
  await expect(resultCard).toBeVisible({ timeout: 60_000 });
  return resultCard;
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function pickDistinctRandomCities(count: number): Array<{ city: string; country: string }> {
  const shuffled = [...CAPITAL_CITIES];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    [shuffled[index], shuffled[swapIndex]] = [shuffled[swapIndex], shuffled[index]];
  }
  return shuffled.slice(0, count);
}
