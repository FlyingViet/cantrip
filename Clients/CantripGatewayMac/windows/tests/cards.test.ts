import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { RemoteCardBlock, RemoteCardDocument } from "../src/gateway/api/types";
import { symbolIcon } from "../src/gateway/ui/icons";
import {
  actionSymbol, cardFallback, cardFooter, cardGlyph, cardLabel, cardParts, cardText, cardTone, chartBar, chartColumns, chartScale,
  itemLabel, mapAttribution, mapRegion, safeActionUrl, statLabel, telNumber,
} from "../src/gateway/ui/transcript/cardLogic";
import { fitZoom, initialZoomForDelta, tileSpan, weatherRanges } from "../src/gateway/ui/transcript/richCardLogic";

// Real host output (CardDocument.snapshot) from the Cantrip Mac.
const fixture = (name: string): RemoteCardDocument =>
  JSON.parse(readFileSync(new URL(`./fixtures/cards/${name}.json`, import.meta.url), "utf8")) as RemoteCardDocument;
const NAMES = ["weather", "weather-unavailable", "places", "link", "flights", "tool-card"];
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
