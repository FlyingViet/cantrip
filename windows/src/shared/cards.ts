// Card documents (docs/cards.md): Cantrip's one format for every card under a reply, made of a
// few building blocks each client draws natively, so a new kind of card needs no client code.
// Mirrors the Mac's `CardDocument` (Sources/Cantrip/CardDocuments.swift).
import { ATTRIBUTION, ATTRIBUTION_URL, DAY_COUNT, HOUR_COUNT, type WeatherCard } from "./weather";

export const CARD_VERSION = 1;

/** Badge and note tones. */
export type Tone = "positive" | "negative" | "warning" | "accent" | "neutral";

export interface Source {
  /** "resolver", "tool" or "preview". */
  kind: string;
  name?: string;
  attribution?: string;
  url?: string;
  /** ISO 8601, e.g. "2026-11-01T22:15:00Z". */
  updatedAt?: string;
}

/** Opens `url` (clients refuse anything but https, http and, where they can, tel). */
export interface Action {
  /** "open", "directions", "call" or "website": the icon; every action just opens `url`. */
  kind: string;
  label: string;
  url: string;
}

export interface Badge {
  text: string;
  tone?: Tone | string;
  symbol?: string;
}

export interface Stat {
  value: string;
  label?: string;
  symbol?: string;
  detail?: string;
  accessibilityLabel?: string;
}

export interface Row {
  key: string;
  value: string;
  symbol?: string;
}

/** An entry in a strip, chart or list; each block uses the fields it needs. */
export interface Item {
  id?: string;
  label?: string;
  title?: string;
  subtitle?: string;
  detail?: string;
  symbol?: string;
  glyph?: string;
  value?: string;
  note?: string;
  tone?: Tone | string;
  low?: number;
  high?: number;
  lowText?: string;
  highText?: string;
  trailing?: string;
  pinID?: string;
  badges?: Badge[];
  actions?: Action[];
  accessibilityLabel?: string;
}

export interface Pin {
  id: string;
  title: string;
  latitude: number;
  longitude: number;
  glyph?: string;
  symbol?: string;
}

/** `type`: header, stat, keyValue, strip, chart, list, map, image, badges or notice (others are skipped). */
export interface Block {
  type: string;
  title?: string;
  subtitle?: string;
  subtitleSymbol?: string;
  symbol?: string;
  lines?: string[];
  stat?: Stat;
  value?: string;
  label?: string;
  detail?: string;
  text?: string;
  tone?: Tone | string;
  /** chart: "range" or "bar". */
  kind?: string;
  rows?: Row[];
  items?: Item[];
  badges?: Badge[];
  min?: number;
  max?: number;
  pins?: Pin[];
  latitude?: number;
  longitude?: number;
  latitudeDelta?: number;
  longitudeDelta?: number;
  /** list: its items are the previous map block's pins (`pinID`), shown as its legend. */
  mapLinked?: boolean;
  attribution?: string;
  imageID?: string;
  aspectRatio?: number;
  accessibilityLabel?: string;
}

export interface CardDocument {
  version: number;
  id: string;
  /** What it is ("weather", "places", "link", "flights", …): for logs and tests; never branched on. */
  type: string;
  /** "panel" (default) or "link" (a compact card; the whole card opens `action.url`). */
  style?: "panel" | "link" | string;
  accessibilityLabel?: string;
  action?: Action;
  source?: Source;
  /** The card as plain text, for anything that can't draw a block. */
  fallbackText?: string;
  blocks: Block[];
}

export type Card = CardDocument;

const present = <T>(values: (T | undefined)[]): T[] => values.filter((value): value is T => value !== undefined);

/** The card as text, line by line like the Mac's `CardDocument.plainText`. */
export function cardPlainText(card: Pick<CardDocument, "blocks">): string {
  const lines: string[] = [];
  for (const block of card.blocks ?? []) {
    switch (block.type) {
      case "header":
        lines.push(present([block.title, block.subtitle]).join(" — "));
        lines.push(...(block.lines ?? []));
        if (block.stat) lines.push(present([block.stat.value, block.stat.label]).join(" "));
        break;
      case "stat":
        lines.push(present([block.label, block.value, block.detail]).join(" "));
        break;
      case "keyValue":
        lines.push(...(block.rows ?? []).map((row) => `${row.key}: ${row.value}`));
        break;
      case "strip":
        lines.push((block.items ?? []).map((item) => present([item.label, item.value, item.note]).join(" ")).join(" · "));
        break;
      case "chart":
        lines.push(...(block.items ?? []).map((item) =>
          present([item.label, item.note, present([item.lowText, item.highText]).join("–")]).filter(Boolean).join(" ")));
        break;
      case "list":
        lines.push(...(block.items ?? []).map((item) => `• ${present([item.title, item.subtitle, item.detail, item.trailing]).join(" — ")}`));
        break;
      case "badges":
        lines.push((block.badges ?? []).map((badge) => badge.text).join(" · "));
        break;
      case "notice":
        lines.push(present([block.title, block.text]).join(": "));
        break;
    }
  }
  return lines.filter((line) => line.trim() !== "").join("\n");
}

export function withFallbackText(card: CardDocument): CardDocument {
  return { ...card, fallbackText: cardPlainText(card) };
}

/** ISO 8601 to the second, as the Mac encodes dates ("2026-11-01T22:15:00Z"). */
export function isoSeconds(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * The forecast as generic blocks, exactly like the Mac's `WeatherCard.document`: a header with the
 * big temperature, the hourly strip, the 10 days as a range chart, and Open-Meteo as the source.
 */
export function weatherDocument(card: WeatherCard): CardDocument {
  const place = card.place;
  const header: Block = { type: "header", title: place };
  if (card.placeNote) {
    header.subtitle = card.placeNote;
    header.subtitleSymbol = "location.fill";
  }
  const current = card.status === "ok" ? card.current : undefined;
  const updatedAt = current ? isoSeconds(card.updatedAt) : undefined;
  const source: Source = { kind: "resolver", name: "Open-Meteo", attribution: ATTRIBUTION, url: ATTRIBUTION_URL, ...(updatedAt ? { updatedAt } : {}) };
  const base = { version: CARD_VERSION, id: `weather-${place.toLowerCase()}`, type: "weather", accessibilityLabel: `Weather for ${place}`, source };
  if (!current) {
    const notice: Block = {
      type: "notice", symbol: "exclamationmark.icloud", title: "Forecast unavailable", text: card.message || "Ask again in a moment.", tone: "warning",
    };
    return withFallbackText({ ...base, blocks: [header, notice] });
  }
  const unitName = card.unit === "C" ? "degrees Celsius" : "degrees Fahrenheit";
  const chance = (value: number | undefined) => (typeof value === "number" && value >= 10 ? { note: `${value}%` } : {});
  const spokenChance = (value: number | undefined) =>
    typeof value === "number" && value >= 10 ? `, ${value} percent chance of precipitation` : "";

  const days = (card.daily ?? []).slice(0, DAY_COUNT);
  const today = days[0] ?? card.today;
  const detail: string[] = [];
  if (today) {
    detail.push(`H ${today.high}°  L ${today.low}°`);
    if (typeof today.precipitationChance === "number") detail.push(`${today.precipitationChance}% precip.`);
  }
  if (typeof current.feelsLike === "number" && Math.abs(current.feelsLike - current.temperature) >= 3) detail.push(`Feels like ${current.feelsLike}°`);
  header.lines = [current.condition, ...(detail.length ? [detail.join(" · ")] : [])];
  header.stat = {
    value: `${current.temperature}°`, symbol: current.symbol, accessibilityLabel: `Now ${current.temperature} ${unitName}, ${current.condition}`,
  };

  const strip: Block = {
    type: "strip",
    accessibilityLabel: "Hourly forecast",
    items: (card.hourly ?? []).slice(0, HOUR_COUNT + 1).map((hour) => ({
      label: hour.label, symbol: hour.symbol, value: `${hour.temperature}°`, ...chance(hour.precipitationChance),
      accessibilityLabel: `${hour.label}, ${hour.temperature} ${unitName}, ${hour.condition}${spokenChance(hour.precipitationChance)}`,
    })),
  };

  const chart: Block = {
    type: "chart",
    kind: "range",
    accessibilityLabel: `${days.length}-day forecast`,
    min: days.length ? Math.min(...days.map((day) => day.low)) : 0,
    max: days.length ? Math.max(...days.map((day) => day.high)) : 1,
    items: days.map((day) => ({
      label: day.label, symbol: day.symbol, ...chance(day.precipitationChance), low: day.low, high: day.high,
      lowText: `${day.low}°`, highText: `${day.high}°`,
      accessibilityLabel: `${day.label}, ${day.condition}, high ${day.high}, low ${day.low} ${unitName}${spokenChance(day.precipitationChance)}`,
    })),
  };
  return withFallbackText({ ...base, blocks: [header, strip, chart] });
}
