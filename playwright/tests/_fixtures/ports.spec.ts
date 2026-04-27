import { test, expect } from "@playwright/test";
import { allocatePort, BASE_PORT, PORTS_PER_WORKER } from "./ports";

test.describe("allocatePort (unit)", () => {
  test("worker 0 gets the base port range", () => {
    expect(allocatePort({ workerIndex: 0, fixtureIndex: 0 })).toBe(BASE_PORT);
    expect(allocatePort({ workerIndex: 0, fixtureIndex: 1 })).toBe(BASE_PORT + 1);
  });

  test("worker N is offset by N * PORTS_PER_WORKER", () => {
    expect(allocatePort({ workerIndex: 1, fixtureIndex: 0 })).toBe(BASE_PORT + PORTS_PER_WORKER);
    expect(allocatePort({ workerIndex: 4, fixtureIndex: 3 })).toBe(BASE_PORT + 4 * PORTS_PER_WORKER + 3);
  });

  test("fixtureIndex must stay below PORTS_PER_WORKER", () => {
    expect(() =>
      allocatePort({ workerIndex: 0, fixtureIndex: PORTS_PER_WORKER }),
    ).toThrow(/fixtureIndex .* must be < PORTS_PER_WORKER/);
  });
});
