import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { cardPlainText, isoSeconds, weatherDocument, type CardDocument } from "../src/shared/cards";
import { buildCard, conditionSymbol, unavailableCard } from "../src/shared/weather";
import { barPosition, chartScale, clock, drawableBlocks, iconMarkup, progressState, safeUrl, symbolTint, toneClass } from "../src/renderer/cards";

const read = (path: string) => JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));
/** Cards the Mac built (Sources/Cantrip/CardDocuments.swift), from the same Open-Meteo fixture. */
const cards = Object.fromEntries(["weather", "weather-unavailable", "flights", "tool-card", "link", "places"]
  .map((name) => [name, read(`./cards/${name}.json`) as CardDocument]));
const seattle = read("./open-meteo-seattle.json");
/** 2:15 PM PST, Sunday, November 1, 2026: the fixture's "current" time. */
const fixtureNow = new Date(1_793_571_300 * 1000);
/** Hour labels differ only in ICU's narrow no-break space ("3\u202fPM") between versions. */
const same = (value: unknown) => JSON.parse(JSON.stringify(value).replace(/\u202f/g, " "));

describe("weather card document", () => {
  it("is the Mac's weather document, block for block", () => {
    const card = buildCard(seattle, "Seattle, WA", "Your iPhone's location", "F", fixtureNow, "en-US");
    const document = weatherDocument(card);
    expect(same(document)).toEqual(same(cards.weather));
    expect(document.blocks.map((block) => block.type)).toEqual(["header", "strip", "chart"]);
    expect(document.blocks[0]).toMatchObject({
      title: "Seattle, WA", subtitle: "Your iPhone's location", subtitleSymbol: "location.fill",
      lines: ["Clear", "H 48°  L 38° · 1% precip. · Feels like 45°"],
      stat: { value: "48°", symbol: "sun.max.fill", accessibilityLabel: "Now 48 degrees Fahrenheit, Clear" },
    });
    expect(document.blocks[1].items?.filter((item) => "note" in item)).toEqual([]);
    expect(document.blocks[2]).toMatchObject({ kind: "range", min: 35, max: 59 });
    expect(document.source).toEqual({
      kind: "resolver", name: "Open-Meteo", attribution: "Weather data by Open-Meteo.com", url: "https://open-meteo.com/",
      updatedAt: "2026-11-01T22:15:00Z",
    });
  });

  it("says why when there's no forecast", () => {
    const document = weatherDocument(unavailableCard("Atlantis", "Couldn't find “Atlantis” to get its forecast.", "F"));
    expect(document).toEqual(cards["weather-unavailable"]);
    expect(weatherDocument(unavailableCard("Weather", "", "C", "This PC's location")).blocks).toEqual([
      { type: "header", title: "Weather", subtitle: "This PC's location", subtitleSymbol: "location.fill" },
      { type: "notice", symbol: "exclamationmark.icloud", title: "Forecast unavailable", text: "Ask again in a moment.", tone: "warning" },
    ]);
  });

  it("writes the same plain text as the Mac for every kind of card", () => {
    for (const card of Object.values(cards)) expect(cardPlainText(card)).toBe(card.fallbackText);
    expect(isoSeconds("2026-11-01T22:15:00.000Z")).toBe("2026-11-01T22:15:00Z");
    expect(isoSeconds("nonsense")).toBeUndefined();
  });
});

describe("card renderer helpers", () => {
  it("places range bars on the chart's scale", () => {
    const chart = cards.weather.blocks[2];
    expect(chartScale(chart)).toEqual({ min: 35, max: 59 });
    expect(barPosition(38, 48, 35, 59)).toEqual({ left: 12.5, width: (10 / 24) * 100 });
    expect(barPosition(35, 59, 35, 59)).toEqual({ left: 0, width: 100 });
    // At least 4% wide, kept inside the track, out-of-range values clamped.
    expect(barPosition(59, 59, 35, 59)).toEqual({ left: 96, width: 4 });
    expect(barPosition(-10, 200, 0, 100)).toEqual({ left: 0, width: 100 });
    expect(barPosition(5, 5, 5, 5)).toEqual({ left: 0, width: 4 });
    expect(chartScale({ kind: "bar", items: [{ high: 3 }, { low: 1, high: 8 }] } as never)).toEqual({ min: 1, max: 8 });
    expect(chartScale({ items: [] })).toEqual({ min: 0, max: 1 });
  });

  it("maps every symbol Cantrip's cards use to an icon", () => {
    const weatherSymbols = new Set<string>();
    for (const code of [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99, 1234]) {
      weatherSymbols.add(conditionSymbol(code, true));
      weatherSymbols.add(conditionSymbol(code, false));
    }
    const used = ["location.fill", "exclamationmark.icloud", "airplane", "star.fill", "shippingbox.fill", "link",
      "cup.and.saucer.fill", "birthday.cake.fill", "fork.knife", "mappin", ...weatherSymbols];
    for (const symbol of used) expect(iconMarkup(symbol), symbol).toMatch(/^<(path|circle|polygon|rect|polyline) /);
    expect(iconMarkup("questionmark.app")).toBeUndefined();
    expect(iconMarkup("constructor")).toBeUndefined();
    expect(iconMarkup("__proto__")).toBeUndefined();
    expect(iconMarkup(undefined)).toBeUndefined();
    expect(symbolTint("sun.max.fill")).toBe("sun");
    expect(symbolTint("moon.stars.fill")).toBe("moon");
    expect(symbolTint("cloud.drizzle.fill")).toBe("wet");
    expect(symbolTint("cloud.sun.fill")).toBe("cloud");
    expect(symbolTint("airplane")).toBe("plain");
    expect(toneClass("positive")).toBe("tone-positive");
    expect(toneClass("x onclick=alert(1)")).toBe("");
    expect(toneClass(undefined)).toBe("");
  });

  it("opens only web links", () => {
    expect(safeUrl("https://kiwi.com/u/hqtj9x")).toBe("https://kiwi.com/u/hqtj9x");
    expect(safeUrl("http://example.com/a b")).toBe("http://example.com/a%20b");
    for (const url of ["tel:+14085550100", "javascript:alert(1)", "file:///C:/Windows/system32", "data:text/html,hi",
      "ms-settings:privacy", "//example.com", "not a url", "", 42, undefined, `https://example.com/${"x".repeat(2_100)}`]) {
      expect(safeUrl(url), String(url).slice(0, 40)).toBeNull();
    }
  });

  it("skips blocks it can't draw, so such a card falls back to its text", () => {
    expect(drawableBlocks(cards.places).map((block) => block.type)).toEqual(["list"]);
    expect(drawableBlocks(cards["tool-card"]).map((block) => block.type)).toEqual(["header", "stat", "keyValue", "badges"]);
    expect(drawableBlocks(cards.flights).map((block) => block.type)).toEqual(["header", "list"]);
    const unknown: CardDocument = {
      version: 1, id: "x", type: "custom", fallbackText: "Plain text",
      blocks: [{ type: "map", latitude: 1, longitude: 2 }, { type: "image", imageID: "i" }, { type: "hologram" }, { type: "list", items: [] }],
    };
    expect(drawableBlocks(unknown)).toEqual([]);
    expect(drawableBlocks({ blocks: null as never })).toEqual([]);
    expect(drawableBlocks({ blocks: [null as never, { type: "notice", text: "Hi" }] })).toHaveLength(1);
    // Malformed entries don't count (or break the card).
    expect(drawableBlocks({ blocks: [{ type: "list", items: [null as never] }, { type: "badges", badges: [{ text: "" }] },
      { type: "keyValue", rows: "x" as never }, { type: "header", lines: [3 as never] }] })).toEqual([]);
  });
});

describe("progress blocks (build cards)", () => {
  const build = read("./cards/build.json") as CardDocument;
  const failed = read("./cards/build-failed.json") as CardDocument;
  const transfer = read("./cards/transfer.json") as CardDocument;
  const start = Date.parse("2026-11-04T20:00:00.000Z");
  const running = { type: "progress", status: "running", label: "Testing", startedAt: "2026-11-04T20:00:00.000Z", expectedSeconds: 185 };

  it("draws the Mac's build cards with their icons", () => {
    expect(drawableBlocks(build).map((block) => block.type)).toEqual(["header", "progress"]);
    for (const card of [build, failed, transfer]) expect(iconMarkup(card.blocks[0].symbol), card.blocks[0].symbol).toBeDefined();
    for (const symbol of ["arrow.down.circle", "arrow.left.arrow.right"]) expect(iconMarkup(symbol), symbol).toBeDefined();
    expect(progressState(failed.blocks[1], Date.now())).toMatchObject({ running: false, label: "Failed", elapsed: "0:47", fraction: 1 });
    expect(cardPlainText(failed)).toContain("Failed · Exit code 65");
  });

  it("follows a transfer's own progress", () => {
    expect(transfer.type).toBe("transfer");
    expect(progressState(transfer.blocks[1], Date.now())).toMatchObject({ running: true, label: "Transferring", fraction: 0.66 });
    expect(cardPlainText(transfer)).toContain("19.2 GB of 29.1 GB · 32.6 MB/s");
  });

  it("ticks the elapsed time and the time left, never a made-up percentage", () => {
    expect(progressState(running, start + 65_000)).toMatchObject({ running: true, elapsed: "1:05", remaining: "About 2:00 left" });
    expect(progressState(running, start + 200_000)).toMatchObject({ fraction: undefined, remaining: "Longer than usual" });
    expect(progressState({ ...running, expectedSeconds: undefined }, start + 30_000).fraction).toBeUndefined();
    expect(progressState({ ...running, status: "ended" }, start).elapsed).toBeUndefined();
    expect(clock(3_729)).toBe("1:02:09");
  });
});
