import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { RemoteCardBlock, RemoteCardDocument } from "../src/gateway/api/types";
import { symbolIcon } from "../src/gateway/ui/icons";
import {
  actionSymbol, cardClock, cardFallback, cardFooter, cardGlyph, cardLabel, cardParts, cardText, cardTone, chartBar, chartColumns, chartScale,
  isImageID, itemLabel, mapAttribution, mapRegion, progressState, safeActionUrl, statLabel, telNumber,
} from "../src/gateway/ui/transcript/cardLogic";
import { fitZoom, initialZoomForDelta, tileSpan, weatherRanges } from "../src/gateway/ui/transcript/richCardLogic";

// Real host output (CardDocument.snapshot) from the Cantrip Mac.
const fixture = (name: string): RemoteCardDocument =>
  JSON.parse(readFileSync(new URL(`./fixtures/cards/${name}.json`, import.meta.url), "utf8")) as RemoteCardDocument;
const NAMES = ["weather", "weather-unavailable", "places", "link", "flights", "tool-card", "build", "build-failed", "transfer", "builds"];
const card = (blocks: RemoteCardBlock[], extra: Partial<RemoteCardDocument> = {}): RemoteCardDocument =>
  ({ version: 1, id: "c", type: "custom", blocks, ...extra });

function symbolsIn(document: RemoteCardDocument): string[] {
  const symbols: (string | undefined)[] = [];
  for (const block of document.blocks) {
    symbols.push(block.symbol, block.subtitleSymbol, block.stat?.symbol);
    for (const item of block.items ?? []) {
      symbols.push(item.symbol, ...(item.badges ?? []).map((badge) => badge.symbol), ...(item.actions ?? []).map((action) => actionSymbol(action.kind)));
    }
    for (const pin of block.pins ?? []) symbols.push(pin.symbol);
    for (const badge of block.badges ?? []) symbols.push(badge.symbol);
  }
  return symbols.filter((symbol): symbol is string => !!symbol);
}

describe("card symbols", () => {
  it("has an icon for every symbol the Mac's cards use", () => {
    const used = new Set(NAMES.flatMap((name) => symbolsIn(fixture(name))));
    expect(used.size).toBeGreaterThan(10);
    for (const symbol of used) expect(symbolIcon(symbol), symbol).toBeDefined();
  });

  it("maps the host's symbols to Lucide icons, with or without .fill", () => {
    for (const symbol of ["airplane", "link", "star.fill", "shippingbox.fill", "phone", "globe", "cup.and.saucer.fill", "fork.knife",
      "birthday.cake.fill", "mappin", "cross.case.fill", "bed.double.fill", "sun.max.fill", "exclamationmark.icloud"]) {
      expect(symbolIcon(symbol), symbol).toBe(symbol);
    }
    expect(symbolIcon("bell.fill")).toBe("bell");
    expect(symbolIcon("lock.fill")).toBe("lock.fill");
  });

  it("draws nothing for unknown symbols, or the emoji when there is one", () => {
    for (const symbol of ["sparkle.magnifyingglass", "constructor", "__proto__", "toString", "", undefined, 3, {}]) {
      expect(symbolIcon(symbol)).toBeUndefined();
    }
    expect(cardGlyph("☕")).toBe("☕");
    expect(cardGlyph("<b>not an emoji</b>")).toBeUndefined();
    expect(cardGlyph({})).toBeUndefined();
    expect(cardGlyph("  ")).toBeUndefined();
  });
});

describe("card actions", () => {
  it("opens public http and https pages only", () => {
    expect(safeActionUrl({ kind: "open", label: "Book", url: "https://kiwi.com/u/hqtj9x" })).toBe("https://kiwi.com/u/hqtj9x");
    expect(safeActionUrl({ kind: "website", label: "Website", url: "http://www.example.com/maiko" })).toBe("http://www.example.com/maiko");
    for (const url of ["tel:+14085550100", "javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "http://localhost:8080/",
      "http://10.0.0.0:8080/", "https://mac.tail1234.ts.net/", "https://user:pw@example.com/", "not a url", ""]) {
      expect(safeActionUrl({ kind: "open", label: "Open", url }), url).toBeNull();
    }
    expect(safeActionUrl(undefined)).toBeNull();
    expect(safeActionUrl({ kind: "open", label: "Open", url: 5 } as never)).toBeNull();
  });

  it("shows a call's number instead of opening tel: links", () => {
    expect(telNumber({ kind: "call", label: "Call", url: "tel:+14085550100" })).toBe("+1 408-555-0100");
    expect(telNumber({ kind: "call", label: "Call", url: "tel:4085550100" })).toBe("408-555-0100");
    expect(telNumber({ kind: "call", label: "Call", url: "tel:+442071234567" })).toBe("+442071234567");
    expect(telNumber({ kind: "call", label: "Call", url: "tel:javascript:alert(1)" })).toBeNull();
    expect(telNumber({ kind: "open", label: "Open", url: "https://example.com" })).toBeNull();
  });

  it("picks an icon per kind", () => {
    expect(symbolIcon(actionSymbol("directions"))).toBeDefined();
    expect(actionSymbol("call")).toBe("phone.fill");
    expect(actionSymbol("website")).toBe("globe");
    expect(actionSymbol("open")).toBe("arrow.up.right");
    expect(actionSymbol("unknown")).toBe("arrow.up.right");
  });
});

describe("chart bars", () => {
  it("places each day like the legacy forecast card", () => {
    const chart = fixture("weather").blocks.find((block) => block.type === "chart")!;
    const scale = chartScale(chart);
    expect(scale).toEqual({ min: 35, max: 59 });
    const bars = chart.items!.map((item) => chartBar(item, scale, chart.kind));
    expect(bars).toEqual(weatherRanges(chart.items!.map((item) => ({ low: item.low!, high: item.high! }))));
    expect(bars[0]!.left).toBeCloseTo(12.5);
    expect(bars[0]!.width).toBeCloseTo(41.667, 2);
    expect(chartColumns(chart.items!)).toBe("46px 24px 36px 34px minmax(30px, 1fr) 34px");
  });

  it("keeps a bar at least 4% wide and inside the track", () => {
    const scale = { min: 0, max: 100 };
    expect(chartBar({ low: 50, high: 50 }, scale, "range")).toEqual({ left: 50, width: 4 });
    expect(chartBar({ low: 99, high: 99 }, scale, "range")).toEqual({ left: 99, width: 1 });
    expect(chartBar({ low: -20, high: 140 }, scale, "range")).toEqual({ left: 0, width: 100 });
    expect(chartBar({ low: 80, high: 20 }, scale, "range")).toEqual({ left: 20, width: 60 });
    expect(chartBar({ label: "None" }, scale, "range")).toBeNull();
    expect(chartBar({ low: 1, high: 1 }, { min: 1, max: 1 }, "range")).toEqual({ left: 0, width: 4 });
  });

  it("starts a bar chart's bars at its minimum (zero when it has none)", () => {
    const block: RemoteCardBlock = { type: "chart", kind: "bar", items: [{ label: "Mon", high: 4 }, { label: "Tue", high: 8 }] };
    const scale = chartScale(block);
    expect(scale).toEqual({ min: 0, max: 8 });
    expect(chartBar(block.items![0], scale, "bar")).toEqual({ left: 0, width: 50 });
    expect(chartColumns(block.items!)).toBe("46px 34px minmax(30px, 1fr) 34px");
  });
});

describe("what a card draws", () => {
  it("draws every fixture's blocks", () => {
    expect(cardParts(fixture("weather")).map((part) => [part.kind === "block" ? part.block.type : "map", part.divided]))
      .toEqual([["header", false], ["strip", true], ["chart", true]]);
    expect(cardParts(fixture("weather-unavailable")).map((part) => part.kind === "block" && part.block.type)).toEqual(["header", "notice"]);
    expect(cardParts(fixture("tool-card")).map((part) => part.kind === "block" && [part.block.type, part.divided]))
      .toEqual([["header", false], ["stat", false], ["keyValue", true], ["badges", false]]);
    expect(cardParts(fixture("flights")).map((part) => part.kind === "block" && part.block.type)).toEqual(["header", "list"]);
    expect(cardParts(fixture("link")).map((part) => part.kind === "block" && part.block.type)).toEqual(["header"]);
  });

  it("makes the mapLinked list after a map its legend", () => {
    const parts = cardParts(fixture("places"));
    expect(parts).toHaveLength(1);
    const [map] = parts;
    expect(map.kind).toBe("map");
    if (map.kind !== "map") return;
    expect(map.legend?.items?.map((item) => item.pinID)).toEqual(map.map.pins?.map((pin) => pin.id));

    const alone = cardParts(card([{ type: "list", mapLinked: true, items: [{ title: "A" }] }]));
    expect(alone.map((part) => part.kind === "block" && part.block.type)).toEqual(["list"]);
    const unrelated = cardParts(card([fixture("places").blocks[0], { type: "list", items: [{ title: "A" }] }]));
    expect(unrelated.map((part) => (part.kind === "map" ? `map${part.legend ? "+legend" : ""}` : part.block.type))).toEqual(["map", "list"]);
  });

  it("skips unknown and empty blocks, and falls back to the card's text", () => {
    const unknown = card([{ type: "hologram", title: "x" }, { type: "header" }, { type: "list", items: [] }, { type: "image", imageID: "../etc" }],
      { fallbackText: "Package 1Z999\nArrives Nov 4" });
    expect(cardParts(unknown)).toEqual([]);
    expect(cardFallback(unknown)).toBe("Package 1Z999\nArrives Nov 4");
    expect(cardParts(card([{ type: "hologram" }, { type: "notice", title: "Heads up" }])).map((part) => part.kind === "block" && part.block.type))
      .toEqual(["notice"]);
    expect(cardParts({ version: 1, id: "x", type: "x", blocks: "nope" } as never)).toEqual([]);
    expect(cardParts(card([null as never, { type: "badges", badges: [{ text: "" }] }, { type: "header", lines: "oops" as never }]))).toEqual([]);
  });

  it("draws only blocks without their own buttons in a link card", () => {
    const link = card([{ type: "image", imageID: "c".repeat(64) }, { type: "header", title: "Mac Studio" }, { type: "list", items: [{ title: "A" }] },
      fixture("places").blocks[0]], { style: "link" });
    expect(cardParts(link).map((part) => part.kind === "block" && part.block.type)).toEqual(["image", "header"]);
  });

  it("keeps the Mac's cached images and site icons on link cards", () => {
    // The Mac's link preview cache IDs are 24 hex characters.
    expect(isImageID("0a1b2c3d4e5f60718293a4b5")).toBe(true);
    expect(isImageID("c".repeat(64))).toBe(true);
    for (const bad of ["../etc", "c".repeat(15), "c".repeat(65), "0a1b2c3d4e5f6071829g", 42]) expect(isImageID(bad)).toBe(false);
    const link = card([
      { type: "image", imageID: "0a1b2c3d4e5f60718293a4b5" },
      { type: "header", title: "Instagram", subtitle: "instagram.com", subtitleImageID: "5b4a3928170f6e5d4c3b2a10" },
    ], { style: "link", action: { kind: "open", label: "Open", url: "https://www.instagram.com/" } });
    const parts = cardParts(link);
    expect(parts.map((part) => part.kind === "block" && part.block.type)).toEqual(["image", "header"]);
    const header = parts[1].kind === "block" ? parts[1].block : undefined;
    expect(header?.subtitleImageID).toBe("5b4a3928170f6e5d4c3b2a10");
  });

  it("names the card, its rows and stats for screen readers", () => {
    expect(cardLabel(fixture("weather"))).toBe("Weather for Seattle, WA");
    expect(cardLabel(fixture("tool-card"))).toBe("Package 1Z999");
    expect(cardLabel(card([], { fallbackText: "" }))).toBe("Card");
    const flights = fixture("flights").blocks[1];
    expect(itemLabel(flights.items![0], "list")).toContain("price 258 USD");
    expect(itemLabel({ title: "Matcha", subtitle: "Cafe", badges: [{ text: "Open now", tone: "positive" }], trailing: "$$" }, "list"))
      .toBe("Matcha, Cafe, Open now, $$");
    expect(itemLabel({ label: "3 PM", value: "48°", note: "20%" }, "strip")).toBe("3 PM, 48°, 20%");
    expect(itemLabel({ label: "Mon", lowText: "35°", highText: "53°" }, "chart")).toBe("Mon, 35° to 53°");
    expect(statLabel(fixture("weather").blocks[0].stat)).toBe("Now 48 degrees Fahrenheit, Clear");
    expect(statLabel({ value: "Nov 4", label: "Arrives" })).toBe("Arrives Nov 4");
  });

  it("only draws strings, and known tones", () => {
    expect(cardText({ toString: () => "<script>" })).toBeUndefined();
    expect(cardText(42)).toBe("42");
    expect(cardText(" ")).toBeUndefined();
    expect(cardTone("warning")).toBe("warning");
    expect(cardTone("hotpink")).toBe("neutral");
    expect(cardTone(undefined)).toBe("neutral");
  });
});

describe("card footer", () => {
  it("shows the update time and the attribution linked to a public page", () => {
    const footer = cardFooter(fixture("weather").source, "en-US");
    expect(footer?.updated).toMatch(/^Updated \d{1,2}:\d{2}\s?[AP]M$/);
    expect(footer?.attribution).toBe("Weather data by Open-Meteo.com");
    expect(footer?.url).toBe("https://open-meteo.com/");
    expect(cardFooter(fixture("weather-unavailable").source)).toEqual({ updated: "", attribution: "Weather data by Open-Meteo.com", url: "https://open-meteo.com/" });
    expect(cardFooter(fixture("tool-card").source)?.attribution).toBe("");
    expect(cardFooter({ kind: "tool", attribution: "Local", url: "http://10.0.0.0/" })?.url).toBeNull();
    expect(cardFooter({ kind: "preview", name: "Apple" })).toBeNull();
    expect(cardFooter(undefined)).toBeNull();
    expect(cardFooter({ kind: "tool", updatedAt: "yesterday" })).toBeNull();
  });
});

describe("map blocks", () => {
  it("uses the block's region, or one around its pins", () => {
    const places = fixture("places").blocks[0];
    expect(mapRegion(places)).toEqual({ latitude: 37.3541, longitude: -121.9552, latitudeDelta: 0.06, longitudeDelta: 0.06 });
    const region = mapRegion({ type: "map", pins: [{ id: "a", title: "A", latitude: 10, longitude: 20 }, { id: "b", title: "B", latitude: 12, longitude: 24 }] });
    expect(region.latitude).toBe(11);
    expect(region.longitude).toBe(22);
    expect(region.latitudeDelta).toBeCloseTo(2.8);
    expect(mapRegion({ type: "map", pins: [{ id: "a", title: "A", latitude: 1, longitude: 2 }] }).latitudeDelta).toBe(0.04);
  });

  it("always credits OpenStreetMap for the tiles", () => {
    expect(mapAttribution("Apple Maps · © OpenStreetMap")).toBe("Apple Maps · © OpenStreetMap");
    expect(mapAttribution("Apple Maps")).toBe("Apple Maps · © OpenStreetMap");
    expect(mapAttribution(undefined)).toBe("© OpenStreetMap");
  });

  it("zooms out until every pin clears the floating legend", () => {
    const places = fixture("places").blocks[0];
    const pins = places.pins!.map((pin) => ({ ...pin, w: Math.min(pin.title.length * 6.4, 150) + 36 }));
    const center = { lat: places.latitude!, lon: places.longitude! };
    const start = initialZoomForDelta(0.06);
    expect(start).toBe(13);
    expect(fitZoom(pins, center, start, { width: 2000, height: 2000 })).toBe(13);
    const fitted = fitZoom(pins, center, start, { width: 312, height: 310 });
    expect(fitted).toBeLessThan(13);
    expect(fitted).toBeGreaterThanOrEqual(10);
    expect(fitZoom(pins, center, 4, { width: 10, height: 10 })).toBe(3);
  });

  it("covers the whole map with tiles", () => {
    expect(tileSpan(100, 580)).toEqual([-1, 1]);
    expect(tileSpan(0, 256)).toEqual([0, 0]);
    expect(tileSpan(-30, 310)).toEqual([0, 1]);
  });
});

describe("progress blocks (build cards)", () => {
  const start = Date.parse("2026-11-04T20:00:00.000Z");
  const block = (extra: Partial<RemoteCardBlock> = {}): RemoteCardBlock => ({
    type: "progress", status: "running", label: "Testing", tone: "accent", startedAt: "2026-11-04T20:00:00.000Z",
    expectedSeconds: 185, detail: "Usually 3m 05s (4 earlier runs)", ...extra,
  });

  it("draws the Mac's build cards: a header, then the progress block with no divider", () => {
    const parts = cardParts(fixture("build"));
    expect(parts.map((part) => part.kind === "block" ? part.block.type : part.kind)).toEqual(["header", "progress"]);
    expect(parts[1].divided).toBe(false);
    const failed = fixture("build-failed");
    expect(failed.blocks[0]).toMatchObject({ symbol: "xmark.circle.fill", tone: "negative" });
    expect(progressState(failed.blocks[1], Date.now())).toMatchObject({ running: false, label: "Failed", elapsed: "0:47", fraction: 1 });
  });

  it("draws a reply's builds as one card: the leading build, one beside it, then earlier steps", () => {
    const builds = fixture("builds");
    const parts = cardParts(builds);
    expect(parts.map((part) => part.kind === "block" ? part.block.type : part.kind)).toEqual(["header", "progress", "progress", "list"]);
    expect(parts[3].divided).toBe(true);
    expect(progressState(builds.blocks[2], Date.now())).toMatchObject({ running: true, label: "make build", fraction: undefined });
    expect(builds.blocks[3].items?.map((item) => [item.note, item.tone, item.trailing])).toEqual([
      ["Succeeded", "positive", "2:21"], ["Failed · Exit code 65", "negative", "1:37"],
    ]);
  });

  it("follows a transfer's own progress, with icons for every direction", () => {
    const transfer = fixture("transfer");
    expect(transfer).toMatchObject({ type: "transfer" });
    expect(progressState(transfer.blocks[1], Date.now())).toMatchObject({ running: true, label: "Transferring", fraction: 0.66 });
    expect(transfer.blocks[1].detail).toBe("19.2 GB of 29.1 GB · 32.6 MB/s");
    for (const symbol of ["arrow.up.circle", "arrow.down.circle", "arrow.left.arrow.right"]) expect(symbolIcon(symbol), symbol).toBeDefined();
  });

  it("ticks the elapsed time and the time left from the estimate", () => {
    expect(progressState(block(), start + 65_000)).toMatchObject({
      running: true, elapsed: "1:05", remaining: "About 2:00 left", showsBar: true,
    });
    expect(progressState(block(), start + 65_000).fraction).toBeCloseTo(65 / 185, 3);
    const late = progressState(block(), start + 200_000);
    expect(late.fraction).toBeUndefined();
    expect(late.remaining).toBe("Longer than usual");
    expect(progressState(block({ fraction: 0.25, expectedSeconds: undefined }), start + 30_000)).toMatchObject({ fraction: 0.25, remaining: undefined });
  });

  it("never makes up a percentage or a duration", () => {
    const first = progressState(block({ expectedSeconds: undefined }), start + 3_729_000);
    expect(first.fraction).toBeUndefined();
    expect(first.elapsed).toBe("1:02:09");
    const ended = progressState(block({ status: "ended", label: "Ended" }), start + 60_000);
    expect(ended).toMatchObject({ running: false, elapsed: undefined, showsBar: false });
    expect(progressState(block({ startedAt: "nonsense" }), start).elapsed).toBeUndefined();
    expect(cardClock(-4)).toBe("0:00");
  });
});
