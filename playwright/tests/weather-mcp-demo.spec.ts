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
    console.log("[weather-smoke] Chat response to 'Hello':\n", visibleText);
    expect(visibleText).not.toMatch(ERROR_MARKERS);
  });

  test(
    "functional: current weather and forecast use random cities from the capital collection",
    async ({ page, gtcDemo }) => {
      const demo = await gtcDemo({ name: "weather-mcp-demo" });
      const cases = pickDistinctRandomCities(2);
      const currentCase = cases[0]!;
      const forecastCase = cases[1]!;

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
        await expectWeatherResult(resultCard, currentCase);

        const resultText = await resultCard.innerText();
        console.log(`[weather-api] Current Weather for ${currentCase.city}:\n${resultText}`);

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
        await expectWeatherResult(resultCard, forecastCase);

        const resultText = await resultCard.innerText();
        console.log(`[weather-api] Forecast Weather for ${forecastCase.city}:\n${resultText}`);

        const visibleText = await page.locator("body").innerText();
        expect(visibleText).not.toMatch(ERROR_MARKERS);
      });
    },
  );
});

// Weather data is live and varies by city/season, so we don't assert on
// specific labels (Temp/Feels/Wind/High/Low/Chance of rain) — those are
// presentation details the demo can rephrase. We only assert:
//   1. the result references the city the user submitted (location echo);
//   2. the card contains *some* weather-shaped content (a known weather
//      keyword or a temperature unit).
const WEATHER_KEYWORDS =
  /weather|temp|temperature|forecast|humidity|wind|rain|cloud|sun|°|fahrenheit|celsius|mph|kph/i;

async function expectWeatherResult(
  resultCard: Locator,
  place: { city: string; country: string },
): Promise<void> {
  await expect(resultCard).toContainText(place.city);
  const text = await resultCard.innerText();
  expect(text, `result should contain weather-shaped content: ${text}`).toMatch(
    WEATHER_KEYWORDS,
  );
}

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

type CapitalCity = { city: string; country: string };

function pickDistinctRandomCities(count: number): CapitalCity[] {
  if (count > CAPITAL_CITIES.length) {
    throw new Error(
      `requested ${count} cities but only ${CAPITAL_CITIES.length} are defined`,
    );
  }
  const shuffled: CapitalCity[] = [...CAPITAL_CITIES];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    const a = shuffled[index]!;
    const b = shuffled[swapIndex]!;
    shuffled[index] = b;
    shuffled[swapIndex] = a;
  }
  return shuffled.slice(0, count);
}
