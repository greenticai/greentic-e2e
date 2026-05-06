import { test, expect } from "./_fixtures/gtc-demo";

// Upstream release naming: redbutton-{create,setup}-answers.json
// (no -demo suffix), so the fixture's demo name is "redbutton". The
// bundle dir lookup then resolves "redbutton-demo-bundle" via the
// ${demoName}-demo-bundle candidate in ensureBundleExtracted.
const REDBUTTON = { name: "redbutton" } as const;

test.describe("redbutton-demo (events webhook ingress)", () => {
  test("functional: red-button event is accepted by /v1/events/ingress", async ({
    gtcDemo,
  }) => {
    const demo = await gtcDemo(REDBUTTON);

    // The redbutton-demo registers the greentic.events.webhook provider.
    // Ingress endpoint shape: POST /v1/events/ingress/<provider>/<tenant>/<team>.
    // Upstream setup-answers default tenant=default, team=default.
    const url = `http://127.0.0.1:${demo.port}/v1/events/ingress/greentic.events.webhook/default/default`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        event: "red_button",
        source: "playwright-e2e",
        severity: "critical",
      }),
    });

    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("accepted");
  });
});
