import type { RemotePlacePin } from "../../api/types";

export function isSafePublicUrl(raw: string | undefined): boolean {
  if (!raw) return false;
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    const host = parsed.hostname.toLowerCase();
    if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return false;
    if (host.endsWith(".ts.net")) return false;
    if (/^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(host)) {
      return false;
    }
    return true;
  } catch {
    return false;
  }
}

export function placeDirectionsUrl(place: RemotePlacePin): string {
  if (place.appleMapsURL && isSafePublicUrl(place.appleMapsURL)) return place.appleMapsURL;
  const q = encodeURIComponent(place.name);
  return `https://maps.apple.com/?q=${q}&ll=${place.latitude.toFixed(6)},${place.longitude.toFixed(6)}`;
}

export function lonToTileX(lon: number, z: number): number {
  return ((lon + 180) / 360) * Math.pow(2, z);
}

export function latToTileY(lat: number, z: number): number {
  const rad = (lat * Math.PI) / 180;
  return ((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * Math.pow(2, z);
}

export function initialZoomForDelta(delta: number): number {
  const d = Math.max(delta || 0.04, 0.01);
  if (d <= 0.015) return 15;
  if (d <= 0.035) return 14;
  if (d <= 0.08) return 13;
  if (d <= 0.18) return 12;
  return 11;
}

/** A pin's icon: the Mac's emoji, or one from the category for cards from older Macs. */
export function placeGlyph(place: RemotePlacePin): string {
  if (place.glyph && [...place.glyph].length <= 2) return place.glyph;
  const text = (place.category ?? "").toLowerCase();
  if (["urgent", "clinic", "hospital", "medical", "pharmacy", "dental"].some((word) => text.includes(word))) return "✚";
  if (["cafe", "café", "coffee", "tea", "matcha", "boba"].some((word) => text.includes(word))) return "☕";
  if (["restaurant", "food", "bakery"].some((word) => text.includes(word))) return "🍴";
  return "📍";
}

/** The row's note under the address: an approximate pin, or the name the listing uses. */
export function placeNote(place: RemotePlacePin): { text: string; warning: boolean } | null {
  if (place.approximate) return { text: "Approximate location", warning: true };
  if (place.listedName) return { text: `Listed as ${place.listedName}`, warning: false };
  return null;
}

/** A pin's estimated width: icon, padding and its label (capped), as the Mac's PlaceMapFit.pinWidth. */
export function pinWidth(name: string): number {
  return Math.min(name.length * 6.4, 150) + 36;
}

/**
 * Moves that keep close pins readable (PlaceMapFit.labelOffsets): each pin, centered on its point, keeps
 * its spot unless an earlier one is there, then takes the nearest free spot (rows above and below, then
 * sideways) inside the map; with none free, the one that overlaps least.
 */
export function pinOffsets(pins: { x: number; y: number; w: number; h: number }[], width: number, height: number): [number, number][] {
  const placed: { l: number; t: number; r: number; b: number }[] = [];
  return pins.map((pin) => {
    const step = pin.h + 2;
    const moves: [number, number][] = [];
    for (let row = -3; row <= 3; row++) for (const shift of [0, -0.5, 0.5, -1, 1]) moves.push([shift * (pin.w + 2), row * step]);
    const cost = (m: [number, number]) => (Math.abs(m[0]) / pin.w) * 2 + Math.abs(m[1]) / step;
    moves.sort((a, b) => cost(a) - cost(b));
    let best: [number, number] = [0, 0];
    let least = Infinity;
    for (const [dx, dy] of moves) {
      const r = { l: pin.x - pin.w / 2 + dx - 1, t: pin.y - pin.h / 2 + dy - 1, r: pin.x + pin.w / 2 + dx + 1, b: pin.y + pin.h / 2 + dy + 1 };
      if ((dx || dy) && (r.l < 0 || r.t < 0 || r.r > width || r.b > height)) continue;
      let overlap = 0;
      for (const o of placed) {
        const w = Math.min(r.r, o.r) - Math.max(r.l, o.l);
        const h = Math.min(r.b, o.b) - Math.max(r.t, o.t);
        if (w > 0 && h > 0) overlap += w * h;
      }
      if (overlap < least) { best = [dx, dy]; least = overlap; }
      if (overlap === 0) break;
    }
    placed.push({ l: pin.x - pin.w / 2 + best[0], t: pin.y - pin.h / 2 + best[1], r: pin.x + pin.w / 2 + best[0], b: pin.y + pin.h / 2 + best[1] });
    return best;
  });
}
