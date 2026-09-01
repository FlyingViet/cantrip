import { describe, expect, it } from "vitest";
import { sanitizeUpdateError } from "../src/shared/update";

describe("update errors", () => {
  it("turns an unpublished GitHub feed response into a short message", () => {
    const error = new Error(
      '404\\nHeaders: {"set-cookie":"sensitive-value","x-request-id":"123"}',
    );
    const message = sanitizeUpdateError(error);
    expect(message).toBe("the GitHub release feed has not been published yet.");
    expect(message).not.toContain("sensitive-value");
  });

  it("shows only the first bounded line of an unexpected error", () => {
    const message = sanitizeUpdateError(
      new Error(`network unavailable\nHeaders: ${"x".repeat(500)}`),
    );
    expect(message).toBe("network unavailable");
    expect(message.length).toBeLessThanOrEqual(180);
  });
});
