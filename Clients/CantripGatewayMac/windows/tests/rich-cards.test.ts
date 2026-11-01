import { describe, expect, it } from "vitest";
import {
  initialZoomForDelta,
  isSafePublicUrl,
  latToTileY,
  lonToTileX,
  placeDirectionsUrl, weatherAttributionUrl, weatherChance, weatherDetail, weatherIcon, weatherRanges, weatherSpoken, weatherTint } from "../src/gateway/ui/transcript/richCardLogic";

describe("rich cards logic", () => {
  it("allows only public HTTP/HTTPS URLs and blocks private/LAN/tailnet hosts", () => {
    expect(isSafePublicUrl("https://www.apple.com/shop/buy-mac/mac-studio")).toBe(true);
    expect(isSafePublicUrl("http://localhost:8080/status")).toBe(false);
    expect(isSafePublicUrl("https://host.example-tailnet.ts.net/api")).toBe(false);
    expect(isSafePublicUrl("http://printer.local")).toBe(false);
    expect(isSafePublicUrl("http://192.168.0.10:8092")).toBe(false);
    expect(isSafePublicUrl("http://100.101.102.103:443")).toBe(false);
    expect(isSafePublicUrl("file:///etc/hosts")).toBe(false);
    expect(isSafePublicUrl("https://user:pass@example.com")).toBe(false);
  });

  it("computes Apple Maps directions URLs and Web Mercator tile coordinates", () => {
    const url = placeDirectionsUrl({
      id: "concentra-sc",
      name: "Concentra Urgent Care",
      latitude: 37.369236,
      longitude: -121.951182,
    });
    expect(url).toContain("https://maps.apple.com/?q=Concentra%20Urgent%20Care");
    expect(url).toContain("ll=37.369236,-121.951182");

    expect(Math.floor(lonToTileX(-121.951182, 13))).toBe(1320);
    expect(Math.floor(latToTileY(37.369236, 13))).toBe(3178);
    expect(initialZoomForDelta(0.04)).toBe(13);
  });
});

describe("place pin icons and notes", () => {
  const pin = (patch: Record<string, unknown>) => ({ id: "p", name: "Place", latitude: 1, longitude: 1, ...patch }) as never;
  it("draws the Mac's emoji, or one from the category on cards from older Macs", async () => {
    const { placeGlyph } = await import("../src/gateway/ui/transcript/richCardLogic");
    expect(placeGlyph(pin({ glyph: "☕", category: "Urgent care" }))).toBe("☕");
    expect(placeGlyph(pin({ category: "Tea house" }))).toBe("☕");
    expect(placeGlyph(pin({ category: "Urgent care clinic" }))).toBe("✚");
    expect(placeGlyph(pin({}))).toBe("📍");
    expect(placeGlyph(pin({ glyph: "<b>too long</b>" }))).toBe("📍");
  });
  it("notes approximate pins and the listing's own name", async () => {
    const { placeNote } = await import("../src/gateway/ui/transcript/richCardLogic");
    expect(placeNote(pin({ approximate: true, listedName: "X" }))).toEqual({ text: "Approximate location", warning: true });
    expect(placeNote(pin({ listedName: "Arisan" }))).toEqual({ text: "Listed as Arisan", warning: false });
    expect(placeNote(pin({}))).toBeNull();
  });
});

describe("close pins", () => {
  it("move to free spots so no two overlap, inside the map", async () => {
    const { pinOffsets, pinWidth } = await import("../src/gateway/ui/transcript/richCardLogic");
    const names = ["Matsu Matcha", "Matcha Cafe Maiko", "Arisan Tea & Coffee House", "Cere Tea", "Izumi Matcha"];
    const points = [[300, 50], [330, 95], [250, 30], [290, 150], [260, 98]];
    const pins = points.map(([x, y], i) => ({ x, y, w: pinWidth(names[i]), h: 24 }));
    const moves = pinOffsets(pins, 580, 210);
    expect(moves[0]).toEqual([0, 0]);
    const rects = pins.map((p, i) => ({ l: p.x - p.w / 2 + moves[i][0], t: p.y - 12 + moves[i][1], r: p.x + p.w / 2 + moves[i][0], b: p.y + 12 + moves[i][1] }));
    for (let i = 0; i < rects.length; i++) for (let j = i + 1; j < rects.length; j++) {
      const overlap = Math.min(rects[i].r, rects[j].r) > Math.max(rects[i].l, rects[j].l) && Math.min(rects[i].b, rects[j].b) > Math.max(rects[i].t, rects[j].t);
      expect(overlap, `pins ${i} and ${j}`).toBe(false);
    }
    for (const r of rects) expect(r.l >= -1 && r.t >= -1 && r.r <= 581 && r.b <= 211).toBe(true);
  });
});

describe("weather card", () => {
  it("maps the Mac's SF Symbol names to icons and tints, with a cloud for unknown ones", () => {
    expect(weatherIcon("cloud.sun.rain.fill")).toBe("cloud.sun.rain.fill");
    expect(weatherIcon("tornado")).toBe("cloud.fill");
    expect(weatherIcon(undefined)).toBe("cloud.fill");
    expect(weatherTint("sun.max.fill")).toBe("sun");
    expect(weatherTint("moon.stars.fill")).toBe("moon");
    expect(weatherTint("cloud.bolt.rain.fill")).toBe("wet");
    expect(weatherTint("cloud.fog.fill")).toBe("cloud");
  });

  it("shows a precipitation chance only from 10% and speaks every hour", () => {
    expect(weatherChance(8)).toBe("");
    expect(weatherChance(62)).toBe("62%");
    expect(weatherChance(undefined)).toBe("");
    expect(weatherSpoken("3 PM", "47", "F", "Light rain", 40)).toBe("3 PM, 47 degrees Fahrenheit, Light rain, 40 percent chance of precipitation");
    expect(weatherSpoken("Now", "9", "C", "Clear", 0)).toBe("Now, 9 degrees Celsius, Clear");
  });

  it("places each day's bar on the 10 days' scale", () => {
    const ranges = weatherRanges([{ low: 38, high: 48 }, { low: 35, high: 53 }, { low: 43, high: 55 }]);
    expect(ranges[1]).toEqual({ left: 0, width: 90 });
    expect(ranges[2].left).toBeCloseTo(40);
    expect(ranges[2].width).toBeCloseTo(60);
    expect(weatherRanges([{ low: 50, high: 50 }])[0]).toEqual({ left: 0, width: 4 });
  });

  it("writes today's line and keeps the attribution link on Open-Meteo", () => {
    expect(weatherDetail({ today: { high: 48, low: 38, precipitationChance: 1 }, current: { temperature: 48, feelsLike: 45 } }))
      .toBe("H 48°  L 38° · 1% precip. · Feels like 45°");
    expect(weatherDetail({ today: { high: 60, low: 50 }, current: { temperature: 55, feelsLike: 54 } })).toBe("H 60°  L 50°");
    expect(weatherAttributionUrl("https://open-meteo.com/")).toBe("https://open-meteo.com/");
    expect(weatherAttributionUrl("https://tracker.example/x")).toBe("https://open-meteo.com/");
  });
});
