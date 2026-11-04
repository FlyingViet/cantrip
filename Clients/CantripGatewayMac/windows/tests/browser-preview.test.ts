import { describe, expect, it } from "vitest";
import { usesBrowser } from "../src/gateway/ui/transcript/browserPreviewLogic";

describe("browser preview", () => {
  it("shows the card only for replies with browser tool calls", () => {
    expect(usesBrowser([{ browser: true }])).toBe(true);
    expect(usesBrowser([{}, { browser: true }])).toBe(true);
    expect(usesBrowser([{}, { browser: false }])).toBe(false);
    expect(usesBrowser([])).toBe(false);
    expect(usesBrowser(undefined)).toBe(false);
  });
});

describe("browser frame requests", () => {
  it("asks the Mac to wait for a change only when a picture is shown", async () => {
    const { browserFramePath } = await import("../src/gateway/ui/transcript/browserPreviewLogic");
    expect(browserFramePath(560)).toBe("/api/v1/browser/frame?width=560");
    expect(browserFramePath(1120.4, 42)).toBe("/api/v1/browser/frame?width=1120&after=42");
    expect(browserFramePath(100, 0)).toBe("/api/v1/browser/frame?width=240");
    expect(browserFramePath(5000)).toBe("/api/v1/browser/frame?width=1920");
  });

  it("asks again right away from a Mac that waits for changes, and polls an older one", async () => {
    const { nextFrameDelay } = await import("../src/gateway/ui/transcript/browserPreviewLogic");
    expect(nextFrameDelay(7, 900)).toBe(0);
    expect(nextFrameDelay(undefined, 900)).toBe(900);
  });
});
