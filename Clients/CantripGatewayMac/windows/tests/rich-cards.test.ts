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
    expect(isSafePublicUrl("http://fixer.example-home.com")).toBe(false);
    expect(isSafePublicUrl("http://192.168.0.94:8092")).toBe(false);
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
