import { describe, expect, it } from "vitest";
import { getInstantAnswer } from "../src/shared/instantAnswers";

describe("instant answers", () => {
  it("evaluates arithmetic with precedence and parentheses", () => {
    expect(getInstantAnswer("142 * 8.5")?.title).toBe("= 1,207");
    expect(getInstantAnswer("(2 + 3) * 4")?.title).toBe("= 20");
    expect(getInstantAnswer("10 / 4")?.title).toBe("= 2.5");
  });

  it("rejects malformed or non-arithmetic input", () => {
    expect(getInstantAnswer("2 +")).toBeNull();
    expect(getInstantAnswer("hello + world")).toBeNull();
    expect(getInstantAnswer("42")).toBeNull();
  });

  it("converts common units", () => {
    expect(getInstantAnswer("10 km to miles")?.title).toBe("10 km = 6.2137 mi");
    expect(getInstantAnswer("1 gb to mb")?.title).toBe("1 GB = 1,024 MB");
  });

  it("converts temperatures", () => {
    expect(getInstantAnswer("72 f to c")?.title).toBe("72°F = 22.2222°C");
    expect(getInstantAnswer("0 c to f")?.title).toBe("0°C = 32°F");
  });
});
