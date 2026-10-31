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
