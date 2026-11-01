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

// Weather card (`RemoteWeatherCard`): the Mac sends labels and SF Symbol names; these only format.

const WEATHER_SYMBOLS = new Set([
  "sun.max.fill", "moon.stars.fill", "cloud.sun.fill", "cloud.moon.fill", "cloud.fill", "cloud.fog.fill",
  "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill", "cloud.sleet.fill", "cloud.snow.fill",
  "cloud.sun.rain.fill", "cloud.moon.rain.fill", "cloud.bolt.rain.fill", "cloud.hail.fill",
]);

/** An icon the Gateway has for `symbol` (cloud when the Mac sends one it doesn't know). */
export function weatherIcon(symbol: string | undefined): string {
  return symbol && WEATHER_SYMBOLS.has(symbol) ? symbol : "cloud.fill";
}

/** Tint by kind: sun gold, moon pale, rain and snow blue, clouds and fog grey. */
export function weatherTint(symbol: string | undefined): "sun" | "moon" | "wet" | "cloud" {
  const icon = weatherIcon(symbol);
  if (icon === "sun.max.fill") return "sun";
  if (icon === "moon.stars.fill") return "moon";
  if (/rain|drizzle|snow|sleet|hail|bolt/.test(icon)) return "wet";
  return "cloud";
}

/** "40%" when rain or snow is reasonably likely, else nothing. */
export function weatherChance(chance: number | undefined): string {
  return typeof chance === "number" && chance >= 10 ? `${Math.round(chance)}%` : "";
}

export function weatherUnitName(unit: string | undefined): string {
  return unit === "C" ? "degrees Celsius" : "degrees Fahrenheit";
}

export function weatherSpoken(label: string, temperature: string, unit: string | undefined, condition: string, chance?: number): string {
  const rain = typeof chance === "number" && chance >= 10 ? `, ${Math.round(chance)} percent chance of precipitation` : "";
  return `${label}, ${temperature} ${weatherUnitName(unit)}, ${condition}${rain}`;
}

/** Where each day's low-to-high bar sits on the 10 days' scale, as CSS percentages. */
export function weatherRanges(days: { low: number; high: number }[]): { left: number; width: number }[] {
  const lows = days.map((d) => d.low).filter(Number.isFinite), highs = days.map((d) => d.high).filter(Number.isFinite);
  if (!lows.length || !highs.length) return days.map(() => ({ left: 0, width: 0 }));
  const lowest = Math.min(...lows), span = Math.max(1, Math.max(...highs) - lowest);
  return days.map((d) => {
    const left = Math.min(100, Math.max(0, ((d.low - lowest) / span) * 100));
    return { left, width: Math.min(100 - left, Math.max(4, ((d.high - d.low) / span) * 100)) };
  });
}

/** Today's line under the condition: "H 48°  L 38° · 10% precip. · Feels like 45°". */
export function weatherDetail(card: { today?: { high: number; low: number; precipitationChance?: number }; current?: { temperature: number; feelsLike?: number } }): string {
  const parts: string[] = [];
  if (card.today) {
    parts.push(`H ${Math.round(card.today.high)}°  L ${Math.round(card.today.low)}°`);
    if (typeof card.today.precipitationChance === "number") parts.push(`${Math.round(card.today.precipitationChance)}% precip.`);
  }
  const feels = card.current?.feelsLike;
  if (card.current && typeof feels === "number" && Math.abs(feels - card.current.temperature) >= 3) parts.push(`Feels like ${Math.round(feels)}°`);
  return parts.join(" · ");
}

/** Open-Meteo's own page only: the attribution link never goes anywhere else. */
export function weatherAttributionUrl(raw: string | undefined): string {
  return raw && raw.startsWith("https://open-meteo.com/") ? raw : "https://open-meteo.com/";
}
