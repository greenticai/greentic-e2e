import { test, expect } from "./_fixtures/gtc-demo";

test("helpdesk-itsm: gtcDemo fixture starts demo and exposes a reachable URL", async ({ gtcDemo }) => {
  const demo = await gtcDemo({ name: "helpdesk-itsm" });
  expect(demo.name).toBe("helpdesk-itsm");
  expect(demo.team).toBe("default");
  expect(demo.demoUrl).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/v1\/web\/webchat\/default\/$/);

  const res = await fetch(demo.demoUrl.replace(/\/v1\/web\/webchat\/.+/, "/readyz"));
  expect(res.status).toBe(200);
});
