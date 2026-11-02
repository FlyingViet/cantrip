// Generic cards (`RemoteCardDocument`, docs/cards.md): what a card draws, safe links, labels and chart math.
// The renderer (Cards.tsx) draws each block once from these; nothing here branches on a card's `type`.
import type {
  RemoteCardAction, RemoteCardBadge, RemoteCardBlock, RemoteCardDocument, RemoteCardItem, RemoteCardPin, RemoteCardSource,
  RemoteCardStat, RemoteCardTone,
} from "../../api/types";
import { isSafePublicUrl } from "./richCardLogic";

export const CARD_BLOCK_TYPES: ReadonlySet<string> = new Set([
  "header", "stat", "keyValue", "strip", "chart", "list", "map", "image", "badges", "notice",
]);
/** A link card is one button, so only blocks without their own buttons draw in it. */
const LINK_BLOCK_TYPES: ReadonlySet<string> = new Set(["image", "header", "stat", "keyValue", "badges", "notice"]);
/** Blocks that start a new section of a panel card (a divider above them). */
const SECTION_BLOCK_TYPES: ReadonlySet<string> = new Set(["keyValue", "strip", "chart", "list", "map", "image"]);
const TONES: ReadonlySet<string> = new Set(["positive", "negative", "warning", "accent", "neutral"]);

/** A string the card can show: the Mac's strings, numbers as text, and nothing else. */
export function cardText(value: unknown): string | undefined {
  if (typeof value === "string") return value.trim() ? value : undefined;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return undefined;
}

function list<T>(value: T[] | undefined): T[] {
  return Array.isArray(value) ? value.filter((entry) => entry !== null && typeof entry === "object") : [];
}

export function cardStyle(card: RemoteCardDocument): "panel" | "link" {
  return card.style === "link" ? "link" : "panel";
}

export function cardTone(tone: unknown): RemoteCardTone {
  return typeof tone === "string" && TONES.has(tone) ? (tone as RemoteCardTone) : "neutral";
}

/** An emoji to draw for an unknown symbol (short, so it can't carry text). */
export function cardGlyph(glyph: unknown): string | undefined {
  return typeof glyph === "string" && glyph.trim() && [...glyph].length <= 4 ? glyph : undefined;
}

export function isImageID(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

export function cardBadges(badges: RemoteCardBadge[] | undefined): RemoteCardBadge[] {
  return list(badges).filter((badge) => cardText(badge.text));
}

export function cardLines(block: RemoteCardBlock): string[] {
  return Array.isArray(block.lines) ? block.lines.map(cardText).filter((line): line is string => !!line) : [];
}

export function cardItems(block: RemoteCardBlock): RemoteCardItem[] {
  return list(block.items);
}

export function mapPins(block: RemoteCardBlock): RemoteCardPin[] {
  return list(block.pins).filter((pin) => typeof pin.id === "string" && Number.isFinite(pin.latitude) && Number.isFinite(pin.longitude));
}

export function cardRows(block: RemoteCardBlock): { key: string; value: string; symbol?: string }[] {
  return list(block.rows).flatMap((row) => {
    const key = cardText(row.key), value = cardText(row.value);
    return key || value ? [{ key: key ?? "", value: value ?? "", symbol: row.symbol }] : [];
  });
}

/** Whether a block has anything to draw. */
export function blockHasContent(block: RemoteCardBlock): boolean {
  switch (block.type) {
    case "header":
      return !!(cardText(block.title) || cardText(block.subtitle) || cardLines(block).length || cardText(block.stat?.value));
    case "stat":
      return !!cardText(block.value);
    case "keyValue":
      return cardRows(block).length > 0;
    case "strip":
      return cardItems(block).some((item) => cardText(item.label) || cardText(item.value));
    case "chart":
      return cardItems(block).some((item) => cardText(item.label) || Number.isFinite(item.high));
    case "list":
      return cardItems(block).some((item) => cardText(item.title));
    case "map":
      return mapPins(block).length > 0 || (Number.isFinite(block.latitude) && Number.isFinite(block.longitude));
    case "image":
      return isImageID(block.imageID);
    case "badges":
      return cardBadges(block.badges).length > 0;
    case "notice":
      return !!(cardText(block.title) || cardText(block.text));
    default:
      return false;
  }
}

/** One thing a card draws: a block, or a map with the mapLinked list right after it as its legend. */
export type CardPart =
  | { kind: "block"; block: RemoteCardBlock; divided: boolean }
  | { kind: "map"; map: RemoteCardBlock; legend?: RemoteCardBlock; divided: boolean };

/** What a card draws, in order: known blocks with something to show (unknown ones are skipped). */
export function cardParts(card: RemoteCardDocument): CardPart[] {
  const style = cardStyle(card);
  const blocks = list(card.blocks).filter((block) => typeof block.type === "string" && CARD_BLOCK_TYPES.has(block.type));
  const parts: CardPart[] = [];
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index];
    if (!blockHasContent(block) || (style === "link" && !LINK_BLOCK_TYPES.has(block.type))) continue;
    const divided = parts.length > 0 && SECTION_BLOCK_TYPES.has(block.type);
    if (block.type === "map") {
      const next = blocks[index + 1];
      const legend = next?.type === "list" && next.mapLinked === true && blockHasContent(next) ? next : undefined;
      if (legend) index++;
      parts.push({ kind: "map", map: block, legend, divided });
    } else {
      parts.push({ kind: "block", block, divided });
    }
  }
  return parts;
}

/** The map's region: the block's, or one around its pins when it has none. */
export function mapRegion(block: RemoteCardBlock): { latitude: number; longitude: number; latitudeDelta: number; longitudeDelta: number } {
  const pins = mapPins(block);
  const lats = pins.map((pin) => pin.latitude), lons = pins.map((pin) => pin.longitude);
  const middle = (values: number[]) => (values.length ? (Math.min(...values) + Math.max(...values)) / 2 : 0);
  const spread = (values: number[]) => (values.length > 1 ? Math.max(0.01, (Math.max(...values) - Math.min(...values)) * 1.4) : 0.04);
  const positive = (value: number | undefined) => Number.isFinite(value) && value! > 0;
  return {
    latitude: Number.isFinite(block.latitude) ? block.latitude! : middle(lats),
    longitude: Number.isFinite(block.longitude) ? block.longitude! : middle(lons),
    latitudeDelta: positive(block.latitudeDelta) ? block.latitudeDelta! : spread(lats),
    longitudeDelta: positive(block.longitudeDelta) ? block.longitudeDelta! : spread(lons),
  };
}

/** The map's attribution; the tiles are always OpenStreetMap's, so it always credits them. */
export function mapAttribution(attribution: unknown): string {
  const text = cardText(attribution);
  if (!text) return "© OpenStreetMap";
  return /openstreetmap/i.test(text) ? text : `${text} · © OpenStreetMap`;
}

/** The card's plain text, for a card with nothing this client can draw. */
export function cardFallback(card: RemoteCardDocument): string {
  return cardText(card.fallbackText)?.trim() ?? "";
}

/** The card's name for screen readers. */
export function cardLabel(card: RemoteCardDocument): string {
  const header = list(card.blocks).find((block) => block.type === "header" && cardText(block.title));
  return cardText(card.accessibilityLabel) ?? cardText(header?.title) ?? (cardFallback(card).split("\n")[0] || "Card");
}

/** Where an action may go from this PC: public http(s) only (Windows' bridge refuses everything else). */
export function safeActionUrl(action: RemoteCardAction | undefined): string | null {
  const url = action && typeof action.url === "string" ? action.url : "";
  return isSafePublicUrl(url) ? url : null;
}

/** The phone number of a `tel:` action, for showing it (this PC can't place the call). */
export function telNumber(action: RemoteCardAction | undefined): string | null {
  const match = typeof action?.url === "string" ? /^tel:(\+?[0-9][0-9\-. ()]{2,24})$/i.exec(action.url.trim()) : null;
  if (!match) return null;
  const digits = match[1].replace(/[^0-9+]/g, "");
  const us = /^\+?1?(\d{3})(\d{3})(\d{4})$/.exec(digits);
  if (us && (digits.startsWith("+1") || digits.length === 10)) return `${digits.startsWith("+1") ? "+1 " : ""}${us[1]}-${us[2]}-${us[3]}`;
  return digits;
}

/** The icon for an action's kind. */
export function actionSymbol(kind: unknown): string {
  switch (kind) {
    case "directions": return "arrow.triangle.turn.up.right.diamond.fill";
    case "call": return "phone.fill";
    case "website": return "globe";
    default: return "arrow.up.right";
  }
}

/** The footer of a panel card: "Updated 3:39 PM" and the attribution, linked only to a public page. */
export function cardFooter(source: RemoteCardSource | undefined, locale?: string): { updated: string; attribution: string; url: string | null } | null {
  if (!source || typeof source !== "object") return null;
  const date = typeof source.updatedAt === "string" ? new Date(source.updatedAt) : null;
  const updated = date && !Number.isNaN(date.getTime()) ? `Updated ${date.toLocaleTimeString(locale ?? [], { hour: "numeric", minute: "2-digit" })}` : "";
  const attribution = cardText(source.attribution) ?? "";
  if (!updated && !attribution) return null;
  return { updated, attribution, url: attribution && isSafePublicUrl(source.url) ? source.url! : null };
}

function joined(parts: (string | undefined)[], separator = ", "): string {
  return parts.filter((part): part is string => !!part).join(separator);
}

/** A row's screen reader label: the Mac's, or one from its fields. */
export function itemLabel(item: RemoteCardItem, blockType: string): string {
  const given = cardText(item.accessibilityLabel);
  if (given) return given;
  const badges = cardBadges(item.badges).map((badge) => badge.text);
  switch (blockType) {
    case "strip":
      return joined([cardText(item.label), cardText(item.value), cardText(item.note)]);
    case "chart": {
      const low = cardText(item.lowText) ?? cardText(item.low), high = cardText(item.highText) ?? cardText(item.high);
      return joined([cardText(item.label), cardText(item.note), low && high ? `${low} to ${high}` : high ?? low]);
    }
    default:
      return joined([cardText(item.title), cardText(item.subtitle), ...badges, cardText(item.detail), cardText(item.note), cardText(item.trailing)]);
  }
}

export function statLabel(stat: RemoteCardStat | undefined): string {
  if (!stat) return "";
  return cardText(stat.accessibilityLabel) ?? joined([cardText(stat.label), cardText(stat.value), cardText(stat.detail)], " ");
}

/** A chart's scale: its `min`…`max`, or the items' lows and highs when it has none. */
export function chartScale(block: RemoteCardBlock): { min: number; max: number } {
  const items = cardItems(block);
  const values = items.flatMap((item) => [item.low, item.high]).filter((value): value is number => Number.isFinite(value));
  const min = Number.isFinite(block.min) ? block.min! : values.length ? Math.min(...values) : 0;
  const max = Number.isFinite(block.max) ? block.max! : values.length ? Math.max(...values) : 1;
  return { min: block.kind === "bar" && !Number.isFinite(block.min) ? Math.min(0, min) : min, max };
}

/**
 * Where an item's bar sits on the chart's scale, as CSS percentages: from `low` (a `bar` chart's
 * bars start at `min` when they have none) to `high`, at least 4% wide so a one-value day still shows.
 */
export function chartBar(item: RemoteCardItem, scale: { min: number; max: number }, kind: unknown): { left: number; width: number } | null {
  if (!Number.isFinite(item.high) && !Number.isFinite(item.low)) return null;
  let low = Number.isFinite(item.low) ? item.low! : kind === "bar" ? scale.min : item.high!;
  let high = Number.isFinite(item.high) ? item.high! : low;
  if (low > high) [low, high] = [high, low];
  const span = scale.max - scale.min > 0 ? scale.max - scale.min : 1;
  const left = Math.min(100, Math.max(0, ((low - scale.min) / span) * 100));
  return { left, width: Math.min(100 - left, Math.max(4, ((high - low) / span) * 100)) };
}

/** The chart's columns: label, icon, note, low, bar, high (icon and note only when some row has one). */
export function chartColumns(items: RemoteCardItem[]): string {
  const chars = (pick: (item: RemoteCardItem) => unknown) => Math.max(0, ...items.map((item) => cardText(pick(item))?.length ?? 0));
  const label = Math.min(120, Math.max(46, chars((item) => item.label) * 8));
  const value = Math.min(80, Math.max(34, Math.max(chars((item) => item.lowText ?? item.low), chars((item) => item.highText ?? item.high)) * 8.5));
  const columns = [`${label}px`];
  if (items.some((item) => typeof item.symbol === "string" && item.symbol)) columns.push("24px");
  if (items.some((item) => cardText(item.note))) columns.push("36px");
  columns.push(`${value}px`, "minmax(30px, 1fr)", `${value}px`);
  return columns.join(" ");
}
