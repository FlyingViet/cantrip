// Generic cards (`RemoteCardDocument`, docs/cards.md): what a card draws, safe links, labels and chart math.
// The renderer (Cards.tsx) draws each block once from these; nothing here branches on a card's `type`.
import type {
  RemoteCardAction, RemoteCardBadge, RemoteCardBlock, RemoteCardButton, RemoteCardDocument, RemoteCardItem, RemoteCardPin,
  RemoteCardSource, RemoteCardStat, RemoteCardTone,
} from "../../api/types";
import { isSafePublicUrl } from "./richCardLogic";

export const CARD_BLOCK_TYPES: ReadonlySet<string> = new Set([
  "header", "stat", "keyValue", "strip", "chart", "list", "map", "image", "badges", "notice", "progress",
  "section", "table", "tabs", "actions",
]);
/** The most blocks a card draws (a view's card has up to 48, nested ones included). */
export const MAX_CARD_BLOCKS = 48;
/** The `actions` button kinds a view's buttons may have (docs/views.md); others are hidden. */
export const VIEW_ACTION_KINDS: ReadonlySet<string> = new Set(["open", "runTask", "refresh", "openRecord", "ask"]);
/** A link card is one button, so only blocks without their own buttons draw in it. */
const LINK_BLOCK_TYPES: ReadonlySet<string> = new Set(["image", "header", "stat", "keyValue", "badges", "notice"]);
/** Blocks that start a new section of a panel card (a divider above them). */
const SECTION_BLOCK_TYPES: ReadonlySet<string> = new Set(["keyValue", "strip", "chart", "list", "map", "image", "section", "table", "tabs"]);
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

/** An image the Mac's link preview cache serves: 16-64 hex characters (24 today). */
export function isImageID(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{16,64}$/i.test(value);
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
    case "section":
      return !!(cardText(block.title) || cardText(block.subtitle));
    case "table":
      return cardTable(block) !== null;
    case "tabs":
      return cardTabs(block).length > 0;
    case "actions":
      return cardButtons(block).length > 0;
    case "header":
      return !!(cardText(block.title) || cardText(block.subtitle) || cardLines(block).length || cardText(block.stat?.value));
    case "stat":
      return !!cardText(block.value);
    case "keyValue":
      return cardRows(block).length > 0;
    case "strip":
      return cardItems(block).some((item) => cardText(item.label) || cardText(item.value));
    case "chart":
      if (block.kind === "pie") return pieSlices(block).length > 0;
      if (block.kind === "line") return cardItems(block).some((item) => Number.isFinite(item.high));
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
    case "progress":
      return !!(cardText(block.label) || cardText(block.startedAt));
    default:
      return false;
  }
}

/** "0:42", "3:05", "1:02:09". */
export function cardClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600), minutes = Math.floor((total % 3600) / 60), rest = String(total % 60).padStart(2, "0");
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}

export interface ProgressState {
  running: boolean;
  label: string;
  /** "1:23"; undefined when there are no times to count from (a result the Mac couldn't read). */
  elapsed?: string;
  /** 0-1, or undefined for an indeterminate bar while running (no step counter or estimate). */
  fraction?: number;
  showsBar: boolean;
  detail?: string;
  /** "About 1:20 left" or "Longer than usual". */
  remaining?: string;
  spoken: string;
}

/** What a progress block shows at `now` (ms): the elapsed time ticks from its `startedAt`. */
export function progressState(block: RemoteCardBlock, now: number): ProgressState {
  const started = Date.parse(cardText(block.startedAt) ?? ""), finished = Date.parse(cardText(block.finishedAt) ?? "");
  const running = block.status === "running" && Number.isNaN(finished);
  const end = running ? now : finished;
  const seconds = Number.isNaN(started) || Number.isNaN(end) ? undefined : Math.max(0, (end - started) / 1000);
  const expected = typeof block.expectedSeconds === "number" && block.expectedSeconds > 0 ? block.expectedSeconds : undefined;
  const step = typeof block.fraction === "number" && Number.isFinite(block.fraction) ? Math.min(1, Math.max(0, block.fraction)) : undefined;
  const label = cardText(block.label) ?? (running ? "Running" : "Done");
  const detail = cardText(block.detail);
  let fraction: number | undefined, remaining: string | undefined;
  if (running) {
    if (step !== undefined) fraction = step;
    else if (expected !== undefined && seconds !== undefined && seconds < expected) fraction = seconds / expected;
    if (expected !== undefined && seconds !== undefined) {
      remaining = seconds < expected ? `About ${cardClock(expected - seconds)} left` : "Longer than usual";
    }
  } else {
    fraction = 1;
  }
  const elapsed = seconds === undefined ? undefined : cardClock(seconds);
  const spoken = [label, elapsed ? `${running ? "running for" : "took"} ${elapsed}` : "", remaining ?? "", detail ?? ""]
    .filter(Boolean).join(", ");
  return { running, label, elapsed, fraction, showsBar: running || (block.status !== "ended" && !Number.isNaN(finished)),
    detail, remaining, spoken };
}

/** One thing a card draws: a block, a map with the mapLinked list right after it as its legend, or tabs with their blocks. */
export type CardPart =
  | { kind: "block"; block: RemoteCardBlock; divided: boolean }
  | { kind: "map"; map: RemoteCardBlock; legend?: RemoteCardBlock; divided: boolean }
  | { kind: "tabs"; block: RemoteCardBlock; tabs: CardTabPane[]; divided: boolean };

/** One tab of a `tabs` block: its title and the blocks it owns. */
export interface CardTabPane {
  title: string;
  symbol?: string;
  parts: CardPart[];
}

export interface CardPartsOptions {
  /** The `actions` button kinds this card may show; without it (a chat reply) `actions` blocks are skipped. */
  actionKinds?: ReadonlySet<string>;
}

/**
 * What a card draws, in order: known blocks with something to show (unknown ones are skipped). A `tabs` block
 * owns the next `count` blocks for each tab in turn (counted before anything is skipped, clamped at the end).
 */
export function cardParts(card: RemoteCardDocument, options: CardPartsOptions = {}): CardPart[] {
  return partsOf(list(card.blocks).slice(0, MAX_CARD_BLOCKS), cardStyle(card), options);
}

function isKnownBlock(block: RemoteCardBlock | undefined): block is RemoteCardBlock {
  return !!block && typeof block.type === "string" && CARD_BLOCK_TYPES.has(block.type);
}

function partsOf(blocks: RemoteCardBlock[], style: "panel" | "link", options: CardPartsOptions): CardPart[] {
  const parts: CardPart[] = [];
  // A section heading starts a group: what follows it isn't divided from it.
  const divided = (type: string) => {
    const last = parts[parts.length - 1];
    return !!last && SECTION_BLOCK_TYPES.has(type) && !(last.kind === "block" && last.block.type === "section");
  };
  let index = 0;
  while (index < blocks.length) {
    const block = blocks[index++];
    if (!isKnownBlock(block)) continue;
    if (block.type === "tabs") {
      // Link cards (and tabs with no tabs) show every block in order, as clients without tabs do.
      const tabs = style === "panel" ? cardTabs(block) : [];
      if (!tabs.length) continue;
      const panes = tabs.map((tab) => {
        const owned = blocks.slice(index, index + tab.count);
        index += owned.length;
        return { title: tab.title, symbol: tab.symbol, parts: partsOf(owned, style, options) };
      });
      parts.push({ kind: "tabs", block, tabs: panes, divided: divided("tabs") });
      continue;
    }
    if (block.type === "actions" && (!options.actionKinds || !cardButtons(block, options.actionKinds).length)) continue;
    if (!blockHasContent(block) || (style === "link" && !LINK_BLOCK_TYPES.has(block.type))) continue;
    if (block.type === "map") {
      let next = index;
      while (next < blocks.length && !isKnownBlock(blocks[next])) next++;
      const candidate = blocks[next];
      const legend = candidate?.type === "list" && candidate.mapLinked === true && blockHasContent(candidate) ? candidate : undefined;
      if (legend) index = next + 1;
      parts.push({ kind: "map", map: block, legend, divided: divided("map") });
    } else {
      parts.push({ kind: "block", block, divided: divided(block.type) });
    }
  }
  return parts;
}

/** Rows a thumbnail's fallback table, list or key-value block keeps. */
export const PREVIEW_ROWS = 3;

/** The blocks a card shows with its tabs resolved to the first tab: the other tabs' blocks are left out. */
function firstTabBlocks(blocks: RemoteCardBlock[]): RemoteCardBlock[] {
  const shown: RemoteCardBlock[] = [];
  let index = 0;
  while (index < blocks.length) {
    const block = blocks[index++];
    if (block.type !== "tabs") {
      shown.push(block);
      continue;
    }
    const counts = cardTabs(block).map((tab) => tab.count);
    shown.push(...firstTabBlocks(blocks.slice(index, index + (counts[0] ?? 0))));
    index += counts.reduce((sum, count) => sum + count, 0);
  }
  return shown;
}

/**
 * What a view's thumbnail draws (the views grid spec's previewBlocks): the resolved card is flat, so a `tabs` block
 * keeps only its first tab's blocks. Up to 2 stats and the first chart, in document order; when there are none, the
 * first table, list or key-value block cut to its first 3 rows. Headings, sections, buttons, notices, badges, progress,
 * images and maps never show.
 */
export function previewBlocks(card: RemoteCardDocument | null | undefined): RemoteCardBlock[] {
  const blocks = firstTabBlocks(list(card?.blocks).slice(0, MAX_CARD_BLOCKS)).filter((block) => isKnownBlock(block) && blockHasContent(block));
  let stats = 0, chart = false;
  const chosen = blocks.filter((block) => {
    if (block.type === "stat" && stats < 2) {
      stats += 1;
      return true;
    }
    if (block.type === "chart" && !chart) {
      chart = true;
      return true;
    }
    return false;
  });
  if (chosen.length) return chosen;
  const fallback = blocks.find((block) => block.type === "table" || block.type === "list" || block.type === "keyValue");
  if (!fallback) return [];
  switch (fallback.type) {
    case "table": return [{ ...fallback, tableRows: list(fallback.tableRows).slice(0, PREVIEW_ROWS) }];
    case "list": return [{ ...fallback, items: list(fallback.items).slice(0, PREVIEW_ROWS) }];
    default: return [{ ...fallback, rows: list(fallback.rows).slice(0, PREVIEW_ROWS) }];
  }
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

/**
 * The footer of a panel card: "Updated 3:39 PM" (with " · Updating…" while a live card is out of date) and
 * the attribution, linked only to a public page.
 */
export function cardFooter(source: RemoteCardSource | undefined, locale?: string, updating = false): { updated: string; attribution: string; url: string | null } | null {
  if (!source || typeof source !== "object") return updating ? { updated: "Updating…", attribution: "", url: null } : null;
  const date = typeof source.updatedAt === "string" ? new Date(source.updatedAt) : null;
  const time = date && !Number.isNaN(date.getTime()) ? `Updated ${date.toLocaleTimeString(locale ?? [], { hour: "numeric", minute: "2-digit" })}` : "";
  const updated = updating ? (time ? `${time} · Updating…` : "Updating…") : time;
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

// MARK: Blocks views add (docs/views.md "New blocks in resolved cards")

/** A `tabs` block's tabs: a title (or "Tab 2") and how many of the following blocks it owns. */
export function cardTabs(block: RemoteCardBlock): { title: string; symbol?: string; count: number }[] {
  return list(block.tabs).map((tab, index) => ({
    title: cardText(tab.title) ?? `Tab ${index + 1}`,
    symbol: typeof tab.symbol === "string" && tab.symbol ? tab.symbol : undefined,
    count: typeof tab.count === "number" && Number.isFinite(tab.count) ? Math.max(0, Math.floor(tab.count)) : 0,
  }));
}

export interface CardButtonModel {
  id: string;
  kind: string;
  label: string;
  symbol?: string;
  prominent: boolean;
  confirmTitle: string;
  confirmMessage?: string;
}

/** An `actions` block's buttons this client can run (`kinds`); buttons of other kinds are hidden. */
export function cardButtons(block: RemoteCardBlock, kinds: ReadonlySet<string> = VIEW_ACTION_KINDS): CardButtonModel[] {
  return list<RemoteCardButton>(block.buttons).flatMap((button) => {
    const id = typeof button.id === "string" ? button.id.trim() : "";
    const label = cardText(button.label);
    if (!id || !label || typeof button.kind !== "string" || !kinds.has(button.kind)) return [];
    return [{
      id, kind: button.kind, label,
      symbol: typeof button.symbol === "string" && button.symbol ? button.symbol : undefined,
      prominent: button.style === "prominent",
      confirmTitle: cardText(button.confirmTitle) ?? `${label}?`,
      confirmMessage: cardText(button.confirmMessage),
    }];
  });
}

/** The icon a view button shows when its own symbol isn't one this client has. */
export function buttonSymbol(kind: string): string {
  switch (kind) {
    case "runTask": return "play";
    case "refresh": return "arrow.clockwise";
    case "openRecord": return "arrow.up.forward.square";
    case "ask": return "bubble.left.and.bubble.right";
    default: return "arrow.up.right";
  }
}

export type CardAlign = "leading" | "trailing" | "center";

export interface CardTableModel {
  title?: string;
  columns: { title: string; align: CardAlign }[];
  rows: { key: string; label: string; cells: { text: string; tone?: RemoteCardTone; symbol?: string }[] }[];
}

function cardAlign(value: unknown): CardAlign {
  return value === "trailing" || value === "center" ? value : "leading";
}

/** A `table` block's columns and rows, each row padded or cut to the columns; null when it has no rows. */
export function cardTable(block: RemoteCardBlock): CardTableModel | null {
  const columns = list(block.columns).map((column) => ({ title: cardText(column.title) ?? "", align: cardAlign(column.align) }));
  const sourceRows = list(block.tableRows).filter((row) => Array.isArray(row.cells));
  const width = columns.length || Math.max(0, ...sourceRows.map((row) => row.cells.length));
  if (!width || !sourceRows.length) return null;
  while (columns.length < width) columns.push({ title: "", align: "leading" });
  const rows = sourceRows.map((row, index) => {
    const cells = Array.from({ length: width }, (_, column) => {
      const cell = row.cells[column];
      const text = cell && typeof cell === "object" ? cardText(cell.text) ?? "" : "";
      const tone = cell && typeof cell.tone === "string" && TONES.has(cell.tone) ? (cell.tone as RemoteCardTone) : undefined;
      const symbol = cell && typeof cell.symbol === "string" && cell.symbol ? cell.symbol : undefined;
      return { text, tone, symbol };
    });
    const spoken = cells.map((cell, column) => (cell.text ? (columns[column].title ? `${columns[column].title}: ${cell.text}` : cell.text) : ""));
    return {
      key: typeof row.id === "string" && row.id ? row.id : String(index),
      label: cardText(row.accessibilityLabel) ?? joined(spoken),
      cells,
    };
  });
  return { title: cardText(block.title), columns, rows };
}

export interface LinePoint {
  x: number;
  y: number;
  label: string;
  value: string;
  spoken: string;
}

export interface LineChartModel {
  points: LinePoint[];
  min: number;
  max: number;
  /** Indexes of the points labelled under the line: the first, middle and last. */
  labelled: number[];
}

function numberText(value: number): string {
  return value.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

/** A `line` chart's points in a `width`×`height` box (y down), on its `min`…`max` scale. */
export function lineChart(block: RemoteCardBlock, width: number, height: number): LineChartModel {
  const items = cardItems(block).filter((item) => Number.isFinite(item.high));
  const values = items.map((item) => item.high!);
  // `min`…`max`, widened to every point (and to a span when they're all equal), as Cantrip Agent draws it.
  const lows = Number.isFinite(block.min) ? [block.min!, ...values] : values;
  const highs = Number.isFinite(block.max) ? [block.max!, ...values] : values;
  const min = lows.length ? Math.min(...lows) : 0;
  let max = highs.length ? Math.max(...highs) : 1;
  if (max <= min) max = min + 1;
  const span = max - min;
  const points = items.map((item, index) => {
    const fraction = Math.min(1, Math.max(0, (item.high! - min) / span));
    const label = cardText(item.label) ?? "";
    const value = cardText(item.highText) ?? numberText(item.high!);
    return {
      x: items.length > 1 ? (index / (items.length - 1)) * width : width / 2,
      y: height - fraction * height,
      label, value,
      spoken: cardText(item.accessibilityLabel) ?? joined([label, value]),
    };
  });
  const last = points.length - 1;
  const labelled = last < 0 ? [] : [...new Set([0, Math.floor(last / 2), last])];
  return { points, min, max, labelled };
}

/** The pie's colors in order; an item's `tone` overrides its slot. */
export const PIE_PALETTE = ["#4C9DFF", "#34C759", "#FFCC00", "#AF52DE", "#5AC8FA", "#FF9F0A", "#FF6482", "#8E8E93"];
const TONE_FILLS: Record<RemoteCardTone, string> = {
  positive: "#34d399", negative: "#f87171", warning: "#f5b841", accent: "#4c9dff", neutral: "#8e8e93",
};

export interface PieSlice {
  label: string;
  value: number;
  valueText: string;
  /** 0-1 of the total. */
  fraction: number;
  /** Where the slice starts, 0-1 clockwise from the top. */
  start: number;
  percent: string;
  color: string;
  spoken: string;
}

/** "42%", "<1%" for a sliver, "0%". */
export function percentText(fraction: number): string {
  const percent = Math.round(fraction * 100);
  return fraction > 0 && percent < 1 ? "<1%" : `${percent}%`;
}

/** A `pie` chart's slices: the items with a positive value, each one's share of the total, colored by its tone or
 *  the palette at its place among the items. */
export function pieSlices(block: RemoteCardBlock): PieSlice[] {
  const items = cardItems(block);
  const total = items.reduce((sum, item) => sum + (Number.isFinite(item.high) && item.high! > 0 ? item.high! : 0), 0);
  if (!(total > 0)) return [];
  let before = 0;
  return items.flatMap((item, index) => {
    if (!Number.isFinite(item.high) || item.high! <= 0) return [];
    const value = item.high!;
    const fraction = value / total;
    const start = before / total;
    before += value;
    const label = cardText(item.label) ?? "";
    const valueText = cardText(item.highText) ?? numberText(value);
    const percent = percentText(fraction);
    const tone = typeof item.tone === "string" && TONES.has(item.tone) ? (item.tone as RemoteCardTone) : undefined;
    // The Mac's label usually says the share already ("Applied, 9, 41 percent").
    const given = cardText(item.accessibilityLabel);
    return [{
      label, value, valueText, fraction, start, percent,
      color: tone ? TONE_FILLS[tone] : PIE_PALETTE[index % PIE_PALETTE.length],
      spoken: given ? (/%|percent/i.test(given) ? given : `${given}, ${percent}`) : joined([label, cardText(item.highText), percent]),
    }];
  });
}
