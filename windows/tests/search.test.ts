import { describe, expect, it } from "vitest";
import { rankApps, scoreApp, searchableQuery } from "../src/shared/search";

describe("app search", () => {
  it("strips launch verbs", () => {
    expect(searchableQuery(" Open   Chrome ")).toBe("chrome");
    expect(searchableQuery("launch Windows Terminal")).toBe("windows terminal");
  });

  it("ranks exact and prefix matches before fuzzy matches", () => {
    const apps = [
      { name: "Google Chrome" },
      { name: "Chrome" },
      { name: "Chromium Browser" },
    ];
    expect(rankApps("chrome", apps).map((app) => app.name)).toEqual([
      "Chrome",
      "Google Chrome",
    ]);
  });

  it("matches compact subsequences without accepting very loose matches", () => {
    expect(scoreApp("vsc", "Visual Studio Code")?.tier).toBe(1);
    expect(scoreApp("vscode", "Visual Studio Code")).toBeNull();
  });

  it("prefers a running app when scores tie", () => {
    const ranked = rankApps("note", [
      { name: "Notepad X", isRunning: false },
      { name: "Notepad Y", isRunning: true },
    ]);
    expect(ranked[0].name).toBe("Notepad Y");
  });
});
