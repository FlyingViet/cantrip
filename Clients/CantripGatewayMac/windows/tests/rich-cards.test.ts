import { describe, expect, it } from "vitest";
import {
  initialZoomForDelta,
  isSafePublicUrl,
  latToTileY,
  lonToTileX,
  placeDirectionsUrl,
} from "../src/gateway/ui/transcript/richCardLogic";

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
