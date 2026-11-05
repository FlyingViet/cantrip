// Cantrip's generic cards (docs/cards.md) as plain DOM: one function per block, so a new kind of
// card needs no code here. Card strings only ever go into textContent and attributes; icons are
// constants. `map` and `image` blocks need the Mac (its map tiles and image cache), so they're skipped.
import type { Action, Badge, Block, CardDocument, Item, Source, Stat } from "../shared/cards";
import "./cards.css";

type Open = (url: string) => void;

// Lucide outlines (ISC), the icons Cantrip Gateway for Windows uses; constants, never card data.
const ICONS: Record<string, string> = {
  "sun.max.fill": "<circle cx='12' cy='12' r='4'/><path d='M12 2v2'/><path d='M12 20v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='m17.66 17.66 1.41 1.41'/><path d='M2 12h2'/><path d='M20 12h2'/><path d='m6.34 17.66-1.41 1.41'/><path d='m19.07 4.93-1.41 1.41'/>",
  "moon.stars.fill": "<path d='M18 5h4'/><path d='M20 3v4'/><path d='M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401'/>",
  "cloud.sun.fill": "<path d='M12 2v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='M20 12h2'/><path d='m19.07 4.93-1.41 1.41'/><path d='M15.947 12.65a4 4 0 0 0-5.925-4.128'/><path d='M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6Z'/>",
  "cloud.moon.fill": "<path d='M13 16a3 3 0 0 1 0 6H7a5 5 0 1 1 4.9-6z'/><path d='M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36'/>",
  "cloud.fill": "<path d='M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z'/>",
  "cloud.fog.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 17H7'/><path d='M17 21H9'/>",
  "cloud.drizzle.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 19v1'/><path d='M8 14v1'/><path d='M16 19v1'/><path d='M16 14v1'/><path d='M12 21v1'/><path d='M12 16v1'/>",
  "cloud.rain.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 14v6'/><path d='M8 14v6'/><path d='M12 16v6'/>",
  "cloud.heavyrain.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='m9.2 22 3-7'/><path d='m9 13-3 7'/><path d='m17 13-3 7'/>",
  "cloud.sleet.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 15h.01'/><path d='M8 19h.01'/><path d='M12 17h.01'/><path d='M12 21h.01'/><path d='M16 15h.01'/><path d='M16 19h.01'/>",
  "cloud.snow.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 15h.01'/><path d='M8 19h.01'/><path d='M12 17h.01'/><path d='M12 21h.01'/><path d='M16 15h.01'/><path d='M16 19h.01'/>",
  "cloud.sun.rain.fill": "<path d='M12 2v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='M20 12h2'/><path d='m19.07 4.93-1.41 1.41'/><path d='M15.947 12.65a4 4 0 0 0-5.925-4.128'/><path d='M3 20a5 5 0 1 1 8.9-4H13a3 3 0 0 1 2 5.24'/><path d='M11 20v2'/><path d='M7 19v2'/>",
  "cloud.moon.rain.fill": "<path d='M11 20v2'/><path d='M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36'/><path d='M3 20a5 5 0 1 1 8.9-4H13a3 3 0 0 1 2 5.24'/><path d='M7 19v2'/>",
  "cloud.bolt.rain.fill": "<path d='M6 16.326A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 .5 8.973'/><path d='m13 12-3 5h4l-3 5'/>",
  "cloud.hail.fill": "<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 14v2'/><path d='M8 14v2'/><path d='M16 20h.01'/><path d='M8 20h.01'/><path d='M12 16v2'/><path d='M12 22h.01'/>",
  "location.fill": "<polygon points='3 11 22 2 13 21 11 13 3 11'/>",
  "exclamationmark.icloud": "<path d='M12 12v4'/><path d='M12 20h.01'/><path d='M8.128 16.949A7 7 0 1 1 15.71 8h1.79a1 1 0 0 1 0 9h-1.642'/>",
  "exclamationmark.triangle.fill": "<path d='m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3'/><path d='M12 9v4'/><path d='M12 17h.01'/>",
  "info.circle": "<circle cx='12' cy='12' r='10'/><path d='M12 16v-4'/><path d='M12 8h.01'/>",
  "checkmark.circle.fill": "<circle cx='12' cy='12' r='10'/><path d='m16 9-5.5 5.5L8 12'/>",
  "airplane": "<path d='M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z'/>",
  "star.fill": "<path d='M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z'/>",
  "shippingbox.fill": "<path d='M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z'/><path d='M12 22V12'/><polyline points='3.29 7 12 12 20.71 7'/><path d='m7.5 4.27 9 5.15'/>",
  "link": "<path d='M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71'/><path d='M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71'/>",
  "globe": "<circle cx='12' cy='12' r='10'/><path d='M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20'/><path d='M2 12h20'/>",
  "arrow.up.right.square": "<path d='M15 3h6v6'/><path d='M10 14 21 3'/><path d='M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6'/>",
  "phone.fill": "<path d='M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384'/>",
  "clock": "<circle cx='12' cy='12' r='10'/><path d='M12 6v6l4 2'/>",
  "calendar": "<path d='M8 2v3'/><path d='M16 2v3'/><rect x='3' y='3' width='18' height='18' rx='2'/><path d='M3 9h18'/>",
  "mappin": "<path d='M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0'/><circle cx='12' cy='10' r='3'/>",
  "cup.and.saucer.fill": "<path d='M10 2v2'/><path d='M14 2v2'/><path d='M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1h14a4 4 0 1 1 0 8h-1'/><path d='M6 2v2'/>",
  "birthday.cake.fill": "<path d='M20 21v-8a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8'/><path d='M4 16s.5-1 2-1 2.5 2 4 2 2.5-2 4-2 2.5 2 4 2 2-1 2-1'/><path d='M2 21h20'/><path d='M7 8v3'/><path d='M12 8v3'/><path d='M17 8v3'/><path d='M7 4h.01'/><path d='M12 4h.01'/><path d='M17 4h.01'/>",
  "fork.knife": "<path d='M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2'/><path d='M7 2v20'/><path d='M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7'/>",
  "bag.fill": "<path d='M16 10a4 4 0 0 1-8 0'/><path d='M3.103 6.034h17.794'/><path d='M3.4 5.467a2 2 0 0 0-.4 1.2V20a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6.667a2 2 0 0 0-.4-1.2l-2-2.667A2 2 0 0 0 17 2H7a2 2 0 0 0-1.6.8z'/>",
  "cart.fill": "<path d='m2.05 2.05 1.099-.028a1 1 0 0 1 1.008.815l2.69 14.347A1 1 0 0 0 7.83 18H18'/><path d='M4.563 5h16.435a1 1 0 0 1 .981 1.204l-1.026 6.226A2 2 0 0 1 18.962 14H6.25'/><circle cx='18' cy='20' r='2'/><circle cx='8' cy='20' r='2'/>",
  "bed.double.fill": "<path d='M2 20v-8a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v8'/><path d='M4 10V6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v4'/><path d='M12 4v6'/><path d='M2 18h20'/>",
  "building.columns.fill": "<path d='M10 18v-7'/><path d='M11.119 2.205a2 2 0 0 1 1.762 0l7.84 3.846A.5.5 0 0 1 20.5 7h-17a.5.5 0 0 1-.22-.949z'/><path d='M14 18v-7'/><path d='M18 18v-7'/><path d='M3 22h18'/><path d='M6 18v-7'/>",
  "cross.case.fill": "<path d='M12 11v4'/><path d='M14 13h-4'/><path d='M16 6V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2'/><path d='M18 6v14'/><path d='M6 6v14'/><rect width='20' height='14' x='2' y='6' rx='2'/>",
  "figure.run": "<path d='M17.596 12.768a2 2 0 1 0 2.829-2.829l-1.768-1.767a2 2 0 0 0 2.828-2.829l-2.828-2.828a2 2 0 0 0-2.829 2.828l-1.767-1.768a2 2 0 1 0-2.829 2.829z'/><path d='m2.5 21.5 1.4-1.4'/><path d='m20.1 3.9 1.4-1.4'/><path d='M5.343 21.485a2 2 0 1 0 2.829-2.828l1.767 1.768a2 2 0 1 0 2.829-2.829l-6.364-6.364a2 2 0 1 0-2.829 2.829l1.768 1.767a2 2 0 0 0-2.828 2.829z'/><path d='m9.6 14.4 4.8-4.8'/>",
  "fuelpump.fill": "<path d='M14 13h2a2 2 0 0 1 2 2v2a2 2 0 0 0 4 0v-6.998a2 2 0 0 0-.59-1.42L18 5'/><path d='M14 21V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v16'/><path d='M2 21h13'/><path d='M3 9h11'/>",
  "graduationcap.fill": "<path d='M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z'/><path d='M22 10v6'/><path d='M6 12.5V16a6 3 0 0 0 12 0v-3.5'/>",
  "tree.fill": "<path d='M10 10v.2A3 3 0 0 1 8.9 16H5a3 3 0 0 1-1-5.8V10a3 3 0 0 1 6 0Z'/><path d='M7 16v6'/><path d='M13 19v3'/><path d='M12 19h8.3a1 1 0 0 0 .7-1.7L18 14h.3a1 1 0 0 0 .7-1.7L16 9h.2a1 1 0 0 0 .8-1.7L13 3l-1.4 1.5'/>",
  "hammer": "<path d='m15 12-8.373 8.373a1 1 0 1 1-3-3L12 9'/><path d='m18 15 4-4'/><path d='m21.5 11.5-1.914-1.914A2 2 0 0 1 19 8.172V7l-2.26-2.26a6 6 0 0 0-4.202-1.756L9 2.96l.92.82A6.18 6.18 0 0 1 12 8.4V10l2 2h1.172a2 2 0 0 1 1.414.586L18.5 14.5'/>",
  "xmark.circle.fill": "<circle cx='12' cy='12' r='10'/><path d='m15 9-6 6'/><path d='m9 9 6 6'/>",
  "stop.circle": "<circle cx='12' cy='12' r='10'/><rect x='9' y='9' width='6' height='6' rx='1'/>",
  "questionmark.circle": "<circle cx='12' cy='12' r='10'/><path d='M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3'/><path d='M12 17h.01'/>",
  "arrow.up.circle": "<circle cx='12' cy='12' r='10'/><path d='m16 12-4-4-4 4'/><path d='M12 16V8'/>",
  "arrow.down.circle": "<circle cx='12' cy='12' r='10'/><path d='M12 8v8'/><path d='m8 12 4 4 4-4'/>",
  "arrow.left.arrow.right": "<path d='M8 3 4 7l4 4'/><path d='M4 7h16'/><path d='m16 21 4-4-4-4'/><path d='M20 17H4'/>",
  "wineglass.fill": "<path d='M8 22h8'/><path d='M7 10h10'/><path d='M12 15v7'/><path d='M12 15a5 5 0 0 0 5-5c0-2-.5-4-2-8H9c-1.5 4-2 6-2 8a5 5 0 0 0 5 5Z'/>",
};

/** Solid shapes, where an outline reads poorly at badge size. */
const FILLED = new Set(["location.fill", "star.fill"]);
const ACTION_SYMBOLS: Record<string, string> = {
  open: "arrow.up.right.square", directions: "location.fill", call: "phone.fill", website: "globe",
};
const TONES = new Set(["positive", "negative", "warning", "accent", "neutral"]);
/** The blocks this client draws; anything else (map, image, newer types) is skipped. */
const DRAWN = new Set(["header", "stat", "keyValue", "strip", "chart", "list", "badges", "notice", "progress"]);

const has = (record: Record<string, string>, key: string | undefined): key is string =>
  typeof key === "string" && Object.prototype.hasOwnProperty.call(record, key);
/** A block's entries that are objects, so one malformed entry can't break the card. */
const entries = <T>(value: T[] | undefined): T[] =>
  Array.isArray(value) ? value.filter((entry) => Boolean(entry) && typeof entry === "object") : [];
const texts = (value: string[] | undefined): string[] => (Array.isArray(value) ? value.filter((line) => typeof line === "string") : []);

/** The Lucide markup for an SF Symbol name Cantrip uses, or undefined. */
export function iconMarkup(symbol: string | undefined): string | undefined {
  return has(ICONS, symbol) ? ICONS[symbol] : undefined;
}

/** Sun gold, moon pale, rain and snow blue, clouds and fog grey; other icons take the text color. */
export function symbolTint(symbol: string): "sun" | "moon" | "wet" | "cloud" | "plain" {
  if (symbol === "sun.max.fill") return "sun";
  if (symbol === "moon.stars.fill") return "moon";
  if (!symbol.startsWith("cloud")) return "plain";
  return /rain|drizzle|snow|sleet|hail|bolt/.test(symbol) ? "wet" : "cloud";
}

/** A known tone's class suffix, or "" (card data never becomes a class name). */
export function toneClass(tone: string | undefined): string {
  return tone && TONES.has(tone) ? `tone-${tone}` : "";
}

/** Only https and http links open; anything else (tel, file, javascript…) is refused. */
export function safeUrl(value: unknown): string | null {
  if (typeof value !== "string" || !value || value.length > 2_048) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** A chart's scale: its `min`/`max`, else the items' own lowest and highest values. */
export function chartScale(block: Pick<Block, "min" | "max" | "items">): { min: number; max: number } {
  const values = entries(block.items).flatMap((item) => [item.low, item.high]).filter((value): value is number => Number.isFinite(value));
  const min = Number.isFinite(block.min) ? (block.min as number) : values.length ? Math.min(...values) : 0;
  const max = Number.isFinite(block.max) ? (block.max as number) : values.length ? Math.max(...values) : 1;
  return { min, max };
}

/** Where a bar from `low` to `high` sits on the `min`…`max` scale, in percent (at least 4% wide). */
export function barPosition(low: number, high: number, min: number, max: number): { left: number; width: number } {
  const span = max > min ? max - min : 1;
  const from = Math.min(Math.max(low, min), max), to = Math.min(Math.max(high, from), max);
  const width = Math.max(4, ((to - from) / span) * 100);
  return { left: Math.max(0, Math.min(((from - min) / span) * 100, 100 - width)), width };
}

/** The blocks this client can draw with something in them; a card with none shows its `fallbackText`. */
export function drawableBlocks(card: Pick<CardDocument, "blocks">): Block[] {
  return (Array.isArray(card.blocks) ? card.blocks : []).filter((block) => {
    if (!block || typeof block !== "object" || !DRAWN.has(block.type)) return false;
    switch (block.type) {
      case "header": return Boolean(block.title || block.subtitle || texts(block.lines).length || block.stat?.value);
      case "stat": return Boolean(block.value);
      case "keyValue": return entries(block.rows).length > 0;
      case "strip": case "chart": case "list": return entries(block.items).length > 0;
      case "badges": return entries(block.badges).some((badge) => badge.text);
      case "notice": return Boolean(block.title || block.text);
      case "progress": return Boolean(block.label || block.startedAt);
      default: return false;
    }
  });
}

function el(tag: string, className?: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** The symbol's icon, else its emoji `glyph`, else nothing. */
function icon(symbol: string | undefined, className: string, glyph?: string): HTMLElement | null {
  const markup = iconMarkup(symbol);
  if (!markup) {
    if (!glyph) return null;
    const node = el("span", `${className} card-glyph`, glyph);
    node.setAttribute("aria-hidden", "true");
    return node;
  }
  const node = el("span", `${className} ${symbolTint(symbol as string)}`);
  node.setAttribute("aria-hidden", "true");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  for (const [name, value] of [["viewBox", "0 0 24 24"], ["fill", FILLED.has(symbol as string) ? "currentColor" : "none"],
    ["stroke", "currentColor"], ["stroke-width", "2"], ["stroke-linecap", "round"], ["stroke-linejoin", "round"]]) svg.setAttribute(name, value);
  svg.innerHTML = markup;
  node.append(svg);
  return node;
}

/** An icon slot that keeps columns aligned when an item has no icon. */
function iconSlot(symbol: string | undefined, className: string, glyph?: string): HTMLElement {
  const node = icon(symbol, className, glyph);
  if (node) return node;
  const empty = el("span", className);
  empty.setAttribute("aria-hidden", "true");
  return empty;
}

function label(node: HTMLElement, text: string | undefined): void {
  if (text) node.setAttribute("aria-label", text);
}

function headerBlock(block: Block): HTMLElement {
  const head = el("div", "card-block card-header");
  const leading = icon(block.symbol, `card-icon card-header-icon ${toneClass(block.tone)}`.trim());
  if (leading) head.append(leading);
  const info = el("div", "card-header-text");
  if (block.title) info.append(el("div", "card-title", block.title));
  if (block.subtitle) {
    const subtitle = el("div", "card-subtitle");
    const symbol = icon(block.subtitleSymbol, "card-icon card-subtitle-icon");
    if (symbol) subtitle.append(symbol);
    subtitle.append(el("span", "", block.subtitle));
    info.append(subtitle);
  }
  texts(block.lines).forEach((line, index) => info.append(el("div", index === 0 ? "card-line" : "card-line-muted", line)));
  head.append(info);
  if (block.stat?.value) head.append(headerStat(block.stat));
  return head;
}

function headerStat(stat: Stat): HTMLElement {
  const node = el("div", "card-header-stat");
  node.setAttribute("role", "img");
  label(node, stat.accessibilityLabel || [stat.label, stat.value, stat.detail].filter(Boolean).join(" "));
  const symbol = icon(stat.symbol, "card-icon card-header-stat-icon");
  if (symbol) node.append(symbol);
  node.append(el("span", "card-header-stat-value", stat.value));
  return node;
}

function statBlock(block: Block): HTMLElement {
  const node = el("div", "card-block card-stat");
  if (block.accessibilityLabel) {
    node.setAttribute("role", "img");
    label(node, block.accessibilityLabel);
  }
  if (block.label) node.append(el("div", "card-stat-label", block.label));
  const main = el("div", "card-stat-main");
  const symbol = icon(block.symbol, "card-icon card-stat-icon");
  if (symbol) main.append(symbol);
  main.append(el("span", "card-stat-value", block.value));
  node.append(main);
  if (block.detail) node.append(el("div", "card-stat-detail", block.detail));
  return node;
}

function keyValueBlock(block: Block): HTMLElement {
  const node = el("div", "card-block card-keyvalue");
  node.setAttribute("role", "list");
  label(node, block.accessibilityLabel);
  for (const row of entries(block.rows)) {
    const line = el("div", "card-kv-row");
    line.setAttribute("role", "listitem");
    label(line, `${row.key}: ${row.value}`);
    const key = el("span", "card-kv-key");
    const symbol = icon(row.symbol, "card-icon card-kv-icon");
    if (symbol) key.append(symbol);
    key.append(el("span", "", row.key));
    line.append(key, el("span", "card-kv-value", row.value));
    node.append(line);
  }
  return node;
}

function stripBlock(block: Block): HTMLElement {
  const items = entries(block.items);
  const icons = items.some((item) => item.symbol || item.glyph);
  const node = el("div", "card-block card-strip");
  node.setAttribute("role", "list");
  label(node, block.accessibilityLabel);
  for (const item of items) {
    const column = el("div", "card-strip-item");
    column.setAttribute("role", "listitem");
    label(column, item.accessibilityLabel);
    column.append(el("span", "", item.label ?? ""));
    if (icons) column.append(iconSlot(item.symbol, "card-icon", item.glyph));
    column.append(el("span", "card-note", item.note ?? ""), el("span", "card-strip-value", item.value ?? ""));
    node.append(column);
  }
  return node;
}

function chartBlock(block: Block): HTMLElement {
  const items = entries(block.items);
  const { min, max } = chartScale({ ...block, items });
  const icons = items.some((item) => item.symbol || item.glyph);
  const node = el("div", "card-block card-chart");
  node.setAttribute("role", "list");
  label(node, block.accessibilityLabel);
  for (const item of items) {
    const row = el("div", "card-chart-row");
    row.setAttribute("role", "listitem");
    label(row, item.accessibilityLabel);
    const low = Number.isFinite(item.low) ? (item.low as number) : min;
    const high = Number.isFinite(item.high) ? (item.high as number) : low;
    const { left, width } = barPosition(low, high, min, max);
    const bar = el("span", "card-bar"), fill = el("span");
    bar.setAttribute("aria-hidden", "true");
    fill.style.left = `${left}%`;
    fill.style.width = `${width}%`;
    bar.append(fill);
    row.append(el("span", "card-chart-label", item.label ?? ""), icons ? iconSlot(item.symbol, "card-icon", item.glyph) : el("span"),
      el("span", "card-note", item.note ?? ""), el("span", "card-chart-low", item.lowText ?? ""), bar,
      el("span", "card-chart-high", item.highText ?? ""));
    node.append(row);
  }
  return node;
}

function badgeRow(badges: Badge[]): HTMLElement {
  const row = el("div", "card-badges");
  for (const badge of entries(badges)) {
    if (!badge.text) continue;
    const pill = el("span", `card-badge ${toneClass(badge.tone) || "tone-neutral"}`);
    const symbol = icon(badge.symbol, "card-icon card-badge-icon");
    if (symbol) pill.append(symbol);
    pill.append(el("span", "", badge.text));
    row.append(pill);
  }
  return row;
}

function actionButtons(actions: Action[], open: Open): HTMLElement | null {
  const row = el("div", "card-actions");
  for (const action of entries(actions)) {
    const url = safeUrl(action.url);
    if (!url || !action.label) continue;
    const button = el("button", "card-action") as HTMLButtonElement;
    button.type = "button";
    const symbol = icon(has(ACTION_SYMBOLS, action.kind) ? ACTION_SYMBOLS[action.kind] : ACTION_SYMBOLS.open, "card-icon card-action-icon");
    if (symbol) button.append(symbol);
    button.append(el("span", "", action.label));
    button.addEventListener("click", () => open(url));
    row.append(button);
  }
  return row.childElementCount ? row : null;
}

function listItem(item: Item, icons: boolean, open: Open): HTMLElement {
  const row = el("div", "card-list-row");
  row.setAttribute("role", "listitem");
  label(row, item.accessibilityLabel);
  if (icons) row.append(iconSlot(item.symbol, "card-icon card-list-icon", item.glyph));
  const main = el("div", "card-list-main");
  if (item.title) main.append(el("div", "card-list-item-title", item.title));
  if (item.subtitle) main.append(el("div", "card-list-subtitle", item.subtitle));
  if (entries(item.badges).length) main.append(badgeRow(item.badges ?? []));
  if (item.detail) main.append(el("div", "card-list-detail", item.detail));
  if (item.note) main.append(el("div", `card-list-note ${toneClass(item.tone)}`.trim(), item.note));
  const actions = actionButtons(entries(item.actions), open);
  if (actions) main.append(actions);
  row.append(main);
  if (item.trailing) row.append(el("div", "card-list-trailing", item.trailing));
  return row;
}

function listBlock(block: Block, open: Open): HTMLElement {
  const items = entries(block.items);
  const icons = items.some((item) => iconMarkup(item.symbol) || item.glyph);
  const node = el("div", "card-block card-list");
  if (block.title) node.append(el("div", "card-list-title", block.title));
  const list = el("div", "card-list-rows");
  list.setAttribute("role", "list");
  label(list, block.accessibilityLabel || block.title);
  for (const item of items) list.append(listItem(item, icons, open));
  node.append(list);
  return node;
}

function badgesBlock(block: Block): HTMLElement {
  const node = el("div", "card-block card-badges-block card-flow");
  label(node, block.accessibilityLabel);
  node.append(badgeRow(entries(block.badges)));
  return node;
}

function noticeBlock(block: Block): HTMLElement {
  const node = el("div", `card-block card-notice card-flow ${toneClass(block.tone)}`.trim());
  if (block.title) {
    const title = el("div", "card-notice-title");
    const symbol = icon(block.symbol, "card-icon card-notice-icon");
    if (symbol) title.append(symbol);
    title.append(el("span", "", block.title));
    node.append(title);
  }
  if (block.text) node.append(el("div", "card-notice-text", block.text));
  return node;
}

/** "0:42", "3:05", "1:02:09". */
export function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600), minutes = Math.floor((total % 3600) / 60), rest = String(total % 60).padStart(2, "0");
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}

/** What a progress block (build cards) shows at `now` (ms): the elapsed time ticks from `startedAt`. */
export function progressState(block: Block, now: number): {
  running: boolean; label: string; elapsed?: string; fraction?: number; showsBar: boolean; remaining?: string; spoken: string;
} {
  const started = Date.parse(block.startedAt ?? ""), finished = Date.parse(block.finishedAt ?? "");
  const running = block.status === "running" && Number.isNaN(finished);
  const end = running ? now : finished;
  const seconds = Number.isNaN(started) || Number.isNaN(end) ? undefined : Math.max(0, (end - started) / 1000);
  const expected = typeof block.expectedSeconds === "number" && block.expectedSeconds > 0 ? block.expectedSeconds : undefined;
  const step = typeof block.fraction === "number" && Number.isFinite(block.fraction) ? Math.min(1, Math.max(0, block.fraction)) : undefined;
  const label = block.label || (running ? "Running" : "Done");
  let fraction: number | undefined, remaining: string | undefined;
  if (running) {
    if (step !== undefined) fraction = step;
    else if (expected !== undefined && seconds !== undefined && seconds < expected) fraction = seconds / expected;
    if (expected !== undefined && seconds !== undefined) remaining = seconds < expected ? `About ${clock(expected - seconds)} left` : "Longer than usual";
  } else {
    fraction = 1;
  }
  const elapsed = seconds === undefined ? undefined : clock(seconds);
  const spoken = [label, elapsed ? `${running ? "running for" : "took"} ${elapsed}` : "", remaining ?? "", block.detail ?? ""]
    .filter(Boolean).join(", ");
  return { running, label, elapsed, fraction, showsBar: running || (block.status !== "ended" && !Number.isNaN(finished)), remaining, spoken };
}

/** Running progress blocks on screen; one timer ticks them all and stops when none are left. */
const ticking = new Set<() => boolean>();
let ticker: ReturnType<typeof setInterval> | undefined;

function progressBlock(block: Block): HTMLElement {
  const tone = block.status === "running" ? "tone-accent" : toneClass(block.tone);
  const node = el("div", `card-block card-progress card-flow ${tone}`.trim());
  node.setAttribute("role", "group");
  const time = el("span", "card-progress-time"), bar = el("div", "card-progress-bar"), fill = el("span");
  const top = el("div", "card-progress-top");
  top.append(el("span", "card-progress-label", block.label ?? ""), time);
  bar.setAttribute("aria-hidden", "true");
  bar.append(fill);
  const foot = el("div", "card-progress-foot"), left = el("span", "card-progress-left");
  foot.append(el("span", "", block.detail ?? ""), left);
  node.append(top, bar, foot);
  const draw = (): boolean => {
    const state = progressState(block, Date.now());
    time.textContent = state.elapsed ?? "";
    bar.hidden = !state.showsBar;
    bar.classList.toggle("indeterminate", state.fraction === undefined);
    fill.style.width = state.fraction === undefined ? "" : `${Math.max(2, state.fraction * 100)}%`;
    left.textContent = state.remaining ?? "";
    foot.hidden = !block.detail && !state.remaining;
    node.setAttribute("aria-label", state.spoken);
    return state.running;
  };
  if (draw()) {
    // It goes on screen after this returns; it stops ticking once it leaves (or never arrives).
    let attached = false, waits = 0;
    ticking.add(() => {
      if (node.isConnected) attached = true;
      else return !attached && ++waits < 5;
      return draw();
    });
    ticker ??= setInterval(() => {
      for (const tick of ticking) if (!tick()) ticking.delete(tick);
      if (!ticking.size) { clearInterval(ticker); ticker = undefined; }
    }, 1000);
  }
  return node;
}

function drawBlock(block: Block, open: Open): HTMLElement | null {
  switch (block.type) {
    case "header": return headerBlock(block);
    case "stat": return statBlock(block);
    case "keyValue": return keyValueBlock(block);
    case "strip": return stripBlock(block);
    case "chart": return chartBlock(block);
    case "list": return listBlock(block, open);
    case "badges": return badgesBlock(block);
    case "notice": return noticeBlock(block);
    case "progress": return progressBlock(block);
    default: return null;
  }
}

/** "Updated 3:39 PM" and the attribution, linked to the source's page. */
function footer(source: Source | undefined, open: Open): HTMLElement | null {
  if (!source || (!source.attribution && !source.updatedAt)) return null;
  const foot = el("div", "card-footer");
  const updated = source.updatedAt ? new Date(source.updatedAt) : null;
  if (updated && !Number.isNaN(updated.getTime())) {
    foot.append(el("span", "", `Updated ${updated.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`));
  }
  if (source.attribution) {
    const url = safeUrl(source.url);
    if (url) {
      const button = el("button", "card-attribution", source.attribution) as HTMLButtonElement;
      button.type = "button";
      button.addEventListener("click", () => open(url));
      foot.append(button);
    } else {
      foot.append(el("span", "card-attribution", source.attribution));
    }
  }
  return foot.childElementCount ? foot : null;
}

/** The card as DOM, or null when there's nothing to show (no drawable block and no fallback text). */
export function cardElement(card: CardDocument, open: Open): HTMLElement | null {
  const blocks = drawableBlocks(card);
  const fallback = typeof card.fallbackText === "string" ? card.fallbackText.trim() : "";
  if (!blocks.length && !fallback) return null;
  const isLink = card.style === "link";
  const wrap = el("section", isLink ? "card-panel card-link" : "card-panel");
  label(wrap, card.accessibilityLabel || fallback.split("\n")[0] || "Card");
  for (const block of blocks) {
    const node = drawBlock(block, open);
    if (node) wrap.append(node);
  }
  if (!blocks.length) wrap.append(el("div", "card-block card-fallback", fallback));
  const url = isLink ? safeUrl(card.action?.url) : null;
  if (url) {
    wrap.setAttribute("role", "link");
    wrap.tabIndex = 0;
    wrap.addEventListener("click", () => open(url));
    wrap.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        open(url);
      }
    });
  } else if (!isLink) {
    const foot = footer(card.source, open);
    if (foot) wrap.append(foot);
  }
  return wrap;
}

/** Draws `card` into `container` (hidden when there's nothing to show). */
export function renderCard(container: HTMLElement, card: CardDocument, openExternal: Open): void {
  const node = card && typeof card === "object" ? cardElement(card, openExternal) : null;
  if (!node) {
    container.replaceChildren();
    container.classList.add("hidden");
    return;
  }
  container.replaceChildren(node);
  container.classList.remove("hidden");
}

export function renderCardLoading(container: HTMLElement, text: string): void {
  container.replaceChildren(el("div", "card-panel card-loading", text));
  container.classList.remove("hidden");
}
