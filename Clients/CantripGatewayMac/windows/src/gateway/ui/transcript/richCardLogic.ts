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
