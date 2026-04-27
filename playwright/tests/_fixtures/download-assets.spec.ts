import { test, expect } from "@playwright/test";
import { releaseAssetUrl, demoAssetNames } from "../../scripts/download-demo-assets";

test.describe("releaseAssetUrl", () => {
  test("uses /releases/latest/download for stable channel", () => {
    expect(
      releaseAssetUrl("helpdesk-itsm-setup-answers.json", { tag: "latest" }),
    ).toBe(
      "https://github.com/greenticai/greentic-demo/releases/latest/download/helpdesk-itsm-setup-answers.json",
    );
  });

  test("uses /releases/download/<tag>/ for pinned version", () => {
    expect(
      releaseAssetUrl("helpdesk-itsm-setup-answers.json", { tag: "v0.1.61" }),
    ).toBe(
      "https://github.com/greenticai/greentic-demo/releases/download/v0.1.61/helpdesk-itsm-setup-answers.json",
    );
  });
});

test.describe("demoAssetNames", () => {
  test("returns the four files for a demo with full quartet", () => {
    expect(demoAssetNames("helpdesk-itsm")).toEqual({
      createAnswers: "helpdesk-itsm-create-answers.json",
      setupAnswers: "helpdesk-itsm-setup-answers.json",
      bundle: "helpdesk-itsm-demo.gtbundle",
      pack: "helpdesk-itsm.gtpack",
    });
  });
});
