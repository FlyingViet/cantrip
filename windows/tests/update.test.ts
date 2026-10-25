import { describe, expect, it } from "vitest";
import { latestWindowsReleaseTag, sanitizeUpdateError, windowsReleaseFeedURL } from "../src/shared/update";

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

describe("Windows release feed", () => {
  it("picks the newest published windows-v release, ignoring the host's v releases", () => {
    const releases = [
      { tag_name: "v1.1.1" },
      { tag_name: "v1.1" },
      { tag_name: "windows-v0.3.0" },
      { tag_name: "windows-v0.10.0" },
      { tag_name: "windows-v0.9.9" },
      { tag_name: "windows-v1.0.0", draft: true },
      { tag_name: "windows-v0.11.0", prerelease: true },
      { tag_name: "windows-v0.12.0-beta.1" },
      { tag_name: 42 },
      null,
    ];
    expect(latestWindowsReleaseTag(releases)).toBe("windows-v0.10.0");
  });

  it("finds nothing before the first Windows release", () => {
    expect(latestWindowsReleaseTag([{ tag_name: "v1.1.1" }])).toBeNull();
    expect(latestWindowsReleaseTag({ message: "rate limited" })).toBeNull();
  });

  it("serves updates from that release's assets", () => {
    expect(windowsReleaseFeedURL("windows-v0.4.0")).toBe(
      "https://github.com/FlyingViet/cantrip/releases/download/windows-v0.4.0",
    );
  });
});
