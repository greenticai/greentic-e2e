/**
 * Validate weatherapi.com itself is up before driving a full gtc setup +
 * browser flow toward it. weather-mcp-demo's tests have no way to tell an
 * upstream outage (503, DNS failure, timeout) apart from an actual product
 * regression — both currently show up as the same "Weather Assistant" card
 * never rendering. A cheap direct ping lets us skip the former instead of
 * failing it.
 */

export type WeatherApiPreflightResult = { ok: true } | { ok: false; reason: string };

const PREFLIGHT_TIMEOUT_MS = 10_000;

export async function checkWeatherApiAvailable(): Promise<WeatherApiPreflightResult> {
  const key = process.env.WEATHER_API_KEY?.trim();
  if (!key) {
    return { ok: false, reason: "WEATHER_API_KEY not set" };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PREFLIGHT_TIMEOUT_MS);
  try {
    const res = await fetch(
      `https://api.weatherapi.com/v1/current.json?key=${encodeURIComponent(key)}&q=London`,
      { signal: controller.signal },
    );
    if (res.ok) return { ok: true };
    // 5xx: the service itself is down. 401/403: the key is bad. Either way
    // the demo can't do anything useful, so both skip rather than fail.
    const reason =
      res.status >= 500
        ? `weatherapi.com is down: HTTP ${res.status}`
        : `weatherapi.com rejected the request: HTTP ${res.status}`;
    return { ok: false, reason };
  } catch (err) {
    return {
      ok: false,
      reason: `weatherapi.com is unreachable: ${(err as Error).message}`,
    };
  } finally {
    clearTimeout(timer);
  }
}
