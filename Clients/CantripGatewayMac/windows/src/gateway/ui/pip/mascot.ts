// Pip, Cantrip Home's mascot: a port of Hermes/Sources/CantripMascot.swift (mood rules, outfits and
// CantripMascotRenderer) to Canvas 2D. Geometry is in unit coordinates scaled by the canvas size,
// exactly as in Swift, so keep the two in step when either changes.

/// What Cantrip Home's mascot is expressing. Priority favors states that need the user.
export type MascotMood =
  | "idle"
  | "thinking"
  | "searching"
  | "working"
  | "writing"
  | "listening"
  | "speaking"
  | "curious"
  | "concerned"
  | "sleeping";

/** Every mood in the Swift enum's declaration order (`allCases`). */
export const MOODS: readonly MascotMood[] = [
  "idle", "thinking", "searching", "working", "writing",
  "listening", "speaking", "curious", "concerned", "sleeping",
];

/// What a running turn is doing right now, read from the Mac's live transcript and status.
export type MascotActivity = "thinking" | "searching" | "working" | "writing";

export interface MoodInput {
  isConnected: boolean;
  isWorking: boolean;
  /** Defaults to `"thinking"`, as in Swift. */
  activity?: MascotActivity;
  isListening?: boolean;
  isSpeaking?: boolean;
  needsInput?: boolean;
  hasProblem?: boolean;
}

/** `CantripMascotMood.resolve`: disconnected first, then what needs the user, then the live run. */
export function resolveMood(input: MoodInput): MascotMood {
  if (!input.isConnected) return "sleeping";
  if (input.needsInput) return "curious";
  if (input.isListening) return "listening";
  if (input.isSpeaking) return "speaking";
  if (input.isWorking) return activityMood(input.activity ?? "thinking");
  return input.hasProblem ? "concerned" : "idle";
}

export function activityMood(activity: MascotActivity): MascotMood {
  return activity;
}

/// Moods shown while a turn runs; finishing one of them earns a celebration hop.
export function isBusy(mood: MascotMood): boolean {
  return mood === "thinking" || mood === "searching" || mood === "working" || mood === "writing";
}

const MOOD_TITLES: Record<MascotMood, string> = {
  idle: "Resting",
  thinking: "Thinking",
  searching: "Searching",
  working: "Working",
  writing: "Writing",
  listening: "Listening",
  speaking: "Speaking",
  curious: "Curious",
  concerned: "Concerned",
  sleeping: "Asleep",
};

export function moodTitle(mood: MascotMood): string {
  return MOOD_TITLES[mood];
}

/// What the header announces after the lane. Working is announced only by the status row above the composer.
export function moodAccessibilityStatus(mood: MascotMood): string | null {
  switch (mood) {
    case "listening": return "Listening";
    case "speaking": return "Speaking";
    case "curious": return "Waiting for your answer";
    case "concerned": return "Something went wrong";
    default: return null;
  }
}

export interface TranscriptActivity {
  state: string;
  toolName?: string;
  title?: string;
}

export interface TranscriptMessage {
  role: string;
  text?: string;
  activities?: readonly TranscriptActivity[];
  /** Subagents the reply launched; only `status` is read. */
  subagents?: readonly { status?: string }[] | null;
}

const FINISHED_SUBAGENT = new Set(["completed", "failed", "cancelled"]);

/** `CantripMascotActivity.current(status:transcript:)`. */
export function currentActivity(status: string | null | undefined, transcript: readonly TranscriptMessage[]): MascotActivity {
  // Result cards Cantrip posts while Home replies sit above the reply, but skip them anyway.
  let reply: TranscriptMessage | undefined;
  for (let index = transcript.length - 1; index >= 0; index--) {
    if (transcript[index].role !== "handoff") {
      reply = transcript[index];
      break;
    }
  }
  if (!reply || reply.role !== "assistant") return "thinking";
  const activities = reply.activities ?? [];
  for (let index = activities.length - 1; index >= 0; index--) {
    const tool = activities[index];
    if (tool.state === "running") return isLookup(tool.toolName ?? tool.title ?? "") ? "searching" : "working";
  }
  // The Mac clears its status while reply text streams and says "Thinking…" while reasoning.
  const isQuiet = (status ?? "").trim() === "";
  if (isQuiet && (reply.text ?? "") !== "") return "writing";
  // Unknown subagent states decode as live in Swift.
  if (reply.subagents?.some((agent) => !FINISHED_SUBAGENT.has(agent.status ?? ""))) return "working";
  return "thinking";
}

/// Tools that read, search or fetch rather than change anything.
export function isLookup(toolName: string): boolean {
  const name = toolName.toLowerCase();
  if (["view", "read", "grep", "glob", "rg", "ls", "find", "fetch"].includes(name)) return true;
  return ["search", "fetch", "get_", "list_", "lookup", "browse"].some((part) => name.includes(part));
}

/// The mascot's display name, stored per device. Blank or whitespace falls back to Pip.
export const MASCOT_NAME_KEY = "cantrip.mascot.name";
export const DEFAULT_MASCOT_NAME = "Pip";
export const MASCOT_NAME_MAX_LENGTH = 20;

let segmenter: Intl.Segmenter | null | undefined;

/** Splits into user-perceived characters, like Swift's `Character`. */
export function graphemes(text: string): string[] {
  if (segmenter === undefined) segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  return segmenter ? Array.from(segmenter.segment(text), (part) => part.segment) : Array.from(text);
}

/** `CantripMascotName.display`: trimmed, lines joined by spaces, at most 20 characters, else "Pip". */
export function displayName(stored: string | null | undefined): string {
  const trimmed = (stored ?? "")
    .replace(/^[\s\u0085]+|[\s\u0085]+$/g, "")
    .split(/[\n\u000b\u000c\r\u0085\u2028\u2029]/)
    .join(" ");
  return trimmed === "" ? DEFAULT_MASCOT_NAME : graphemes(trimmed).slice(0, MASCOT_NAME_MAX_LENGTH).join("");
}

/// Outfits are stored per device by raw value, so keep existing raw values stable.
export type OutfitID = "starryPlush" | "dinoHoodie" | "pandaKitty";
export const MASCOT_OUTFIT_KEY = "cantrip.mascot.outfit";
export const DEFAULT_OUTFIT: OutfitID = "starryPlush";

/** sRGB components in 0...1, like SwiftUI's `Color(red:green:blue:)`. */
export type RGB = readonly [number, number, number];
const WHITE: RGB = [1, 1, 1];

export interface OutfitPalette {
  background: readonly RGB[];
  darkBackground: readonly RGB[];
  hood: readonly RGB[];
  recess: RGB;
  paw: readonly RGB[];
  accent: RGB;
  fluff: number;
  fur: boolean;
}

export interface Outfit {
  id: OutfitID;
  title: string;
  summary: string;
  /** The wearer is a cat instead of Pip's usual plush face. */
  isCat: boolean;
  palette: OutfitPalette;
}

export const OUTFITS: readonly Outfit[] = [
  {
    id: "starryPlush",
    title: "Starry Plush",
    summary: "Fluffy purple hood with a gold star pin",
    isCat: false,
    palette: {
      background: [WHITE, [0.96, 0.94, 1.0], [0.87, 0.84, 0.98]],
      darkBackground: [[0.98, 0.97, 1.0], [0.91, 0.88, 0.99], [0.8, 0.75, 0.96]],
      hood: [[0.86, 0.79, 1.0], [0.67, 0.55, 0.95], [0.48, 0.35, 0.83]],
      recess: [0.36, 0.24, 0.66],
      paw: [[0.84, 0.76, 1.0], [0.7, 0.59, 0.97]],
      accent: [0.48, 0.33, 0.86],
      fluff: 1,
      fur: true,
    },
  },
  {
    id: "dinoHoodie",
    title: "Dino Hoodie",
    summary: "Green fleece hood with spikes and soft teeth",
    isCat: false,
    palette: {
      background: [WHITE, [0.93, 0.98, 0.92], [0.82, 0.93, 0.82]],
      darkBackground: [[0.97, 1.0, 0.96], [0.88, 0.96, 0.87], [0.74, 0.88, 0.74]],
      hood: [[0.64, 0.9, 0.52], [0.39, 0.75, 0.37], [0.22, 0.55, 0.27]],
      recess: [0.12, 0.38, 0.18],
      paw: [[0.6, 0.87, 0.5], [0.4, 0.72, 0.38]],
      accent: [0.16, 0.5, 0.24],
      fluff: 0.25,
      fur: false,
    },
  },
  {
    id: "pandaKitty",
    title: "Panda Kitty",
    summary: "British Shorthair cat in a panda onesie",
    isCat: true,
    palette: {
      background: [[0.9, 0.97, 0.86], [0.76, 0.9, 0.7], [0.58, 0.79, 0.53]],
      darkBackground: [[0.93, 0.99, 0.9], [0.8, 0.93, 0.75], [0.64, 0.84, 0.59]],
      hood: [WHITE, [0.96, 0.96, 0.97], [0.8, 0.81, 0.85]],
      recess: [0.2, 0.21, 0.26],
      paw: [[0.32, 0.32, 0.36], [0.11, 0.11, 0.14]],
      accent: [0.84, 0.42, 0.1],
      fluff: 0.6,
      fur: true,
    },
  },
];

export function isOutfitID(value: unknown): value is OutfitID {
  return OUTFITS.some((outfit) => outfit.id === value);
}

/** The outfit for a stored raw value; unknown values fall back to Starry Plush. */
export function outfitFor(id: string | null | undefined): Outfit {
  return OUTFITS.find((outfit) => outfit.id === id) ?? OUTFITS[0];
}

/// Seconds the hop lasts after a busy mood settles back to idle.
export const CELEBRATION_DURATION = 1.2;

export interface DrawMascotOptions {
  mood: MascotMood;
  outfit: OutfitID;
  /** Width and height in the context's current units (CSS px when the caller scaled for DPR). */
  size: number;
  /** Seconds on any clock. Pinned to 1 when `reduceMotion` is set, like Swift's still pose. */
  time: number;
  /** Draws the still pose Swift shows for Reduce Motion (no tilt, sway or spin). */
  reduceMotion: boolean;
  /** Seconds since a celebration hop started, while it lasts (`CELEBRATION_DURATION`). */
  celebration?: number | null;
  /** Light-mode backgrounds exist only for parity with Swift; the Windows app is dark. Default true. */
  dark?: boolean;
}

/// Draws one frame of Pip into `ctx`'s current coordinate space at (0, 0, size, size), clipped to a
/// circle with CantripMascotView's hairline rim. The caller clears the canvas and adds the drop shadow.
export function drawMascot(ctx: CanvasRenderingContext2D, options: DrawMascotOptions): void {
  new Renderer(options).draw(ctx);
}

/// Blink curve: open (1) except for brief blinks every 4.3 s and 9.7 s.
export function openness(t: number): number {
  const blink = (period: number, offset: number) => {
    const phase = (t + offset) % period;
    const duration = 0.16;
    if (!(phase >= 0 && phase < duration)) return 1;
    return Math.abs(phase - duration / 2) / (duration / 2);
  };
  return Math.min(blink(4.3, 1.1), blink(9.7, 5.3));
}

// MARK: - Drawing helpers

type Ctx = CanvasRenderingContext2D;

const INK: RGB = [0.16, 0.12, 0.24];
const CAT_OUTLINE = rgba([0.36, 0.4, 0.49], 0.7);

function rgba(color: RGB, alpha = 1): string {
  return `rgba(${color[0] * 255}, ${color[1] * 255}, ${color[2] * 255}, ${alpha})`;
}

function stops(gradient: CanvasGradient, colors: readonly RGB[]): CanvasGradient {
  colors.forEach((color, index) => gradient.addColorStop(colors.length === 1 ? 0 : index / (colors.length - 1), rgba(color)));
  return gradient;
}

function radial(ctx: Ctx, colors: readonly RGB[], x: number, y: number, radius: number): CanvasGradient {
  return stops(ctx.createRadialGradient(x, y, 0, x, y, radius), colors);
}

function linear(ctx: Ctx, colors: readonly RGB[], x0: number, y0: number, x1: number, y1: number): CanvasGradient {
  return stops(ctx.createLinearGradient(x0, y0, x1, y1), colors);
}

const deg = (degrees: number) => (degrees * Math.PI) / 180;

/** Swift's `rounded()`: halves round away from zero. */
const roundHalfAway = (value: number) => Math.sign(value) * Math.round(Math.abs(value));

/** Starts a new path holding one ellipse, in absolute coordinates. */
function ellipse(ctx: Ctx, cx: number, cy: number, rx: number, ry: number): void {
  ctx.beginPath();
  ctx.ellipse(cx, cy, Math.max(0, rx), Math.max(0, ry), 0, 0, Math.PI * 2);
}

/** `Path(ellipseIn: CGRect)`. */
function ellipseIn(ctx: Ctx, x: number, y: number, width: number, height: number): void {
  ellipse(ctx, x + width / 2, y + height / 2, width / 2, height / 2);
}

function starPath(points: number, outer: number, inner: number): Path2D {
  const path = new Path2D();
  for (let index = 0; index < points * 2; index++) {
    const radius = index % 2 === 0 ? outer : inner;
    const angle = (index * Math.PI) / points - Math.PI / 2;
    if (index === 0) path.moveTo(Math.cos(angle) * radius, Math.sin(angle) * radius);
    else path.lineTo(Math.cos(angle) * radius, Math.sin(angle) * radius);
  }
  path.closePath();
  return path;
}

function gearPath(teeth: number, outer: number, inner: number, hole: number): Path2D {
  const path = new Path2D();
  const step = (2 * Math.PI) / teeth;
  for (let index = 0; index < teeth; index++) {
    const start = index * step;
    const corners: [number, number][] = [
      [start, inner], [start + step * 0.18, outer], [start + step * 0.5, outer], [start + step * 0.68, inner],
    ];
    corners.forEach(([angle, radius], offset) => {
      if (index === 0 && offset === 0) path.moveTo(Math.cos(angle) * radius, Math.sin(angle) * radius);
      else path.lineTo(Math.cos(angle) * radius, Math.sin(angle) * radius);
    });
  }
  path.closePath();
  path.moveTo(hole, 0);
  path.ellipse(0, 0, hole, hole, 0, 0, Math.PI * 2);
  return path;
}

const HOOD_EXPONENT = 2 / 2.35;
const signedPow = (value: number, exponent: number) => (value < 0 ? -1 : 1) * Math.pow(Math.abs(value), exponent);

/// A point on the hood's outline and its outward normal, in unit coordinates.
function hoodEdge(theta: number): { x: number; y: number; nx: number; ny: number } {
  const x = 0.5 + 0.385 * signedPow(Math.cos(theta), HOOD_EXPONENT);
  const y = 0.69 + 0.5 * signedPow(Math.sin(theta), HOOD_EXPONENT);
  const dx = (x - 0.5) / Math.pow(0.385, 2);
  const dy = (y - 0.69) / Math.pow(0.5, 2);
  const length = Math.hypot(dx, dy);
  return { x, y, nx: dx / length, ny: dy / length };
}

/// The hood: a superellipse with a fluffy edge.
function hoodPath(s: number, amount: number): Path2D {
  const path = new Path2D();
  const steps = 240;
  for (let step = 0; step <= steps; step++) {
    const theta = (step / steps) * 2 * Math.PI;
    const fluff = 1 + amount * (0.014 * Math.sin(theta * 24) + 0.007 * Math.sin(theta * 37 + 1));
    const x = (0.5 + 0.385 * signedPow(Math.cos(theta), HOOD_EXPONENT) * fluff) * s;
    const y = (0.69 + 0.5 * signedPow(Math.sin(theta), HOOD_EXPONENT) * fluff) * s;
    if (step === 0) path.moveTo(x, y);
    else path.lineTo(x, y);
  }
  path.closePath();
  return path;
}

interface Tuft { x: number; y: number; angle: number; light: boolean }

/// Fixed pseudo-random fur so every frame and every launch matches (Swift's LCG and seed, bit for bit).
const TUFTS: readonly Tuft[] = (() => {
  const mask = (1n << 64n) - 1n;
  let seed = 0x00c0ffeen;
  const next = () => {
    seed = (seed * 6364136223846793005n + 1442695040888963407n) & mask;
    return Number(seed >> 11n) / 2 ** 53;
  };
  const result: Tuft[] = [];
  while (result.length < 110) {
    const x = 0.12 + next() * 0.76;
    const y = 0.16 + next() * 0.84;
    const hood = Math.pow((x - 0.5) / 0.385, 2) + Math.pow((y - 0.69) / 0.5, 2);
    const face = Math.pow((x - 0.5) / 0.235, 2) + Math.pow((y - 0.57) / 0.205, 2);
    if (!(hood < 0.93 && face > 1.1)) continue;
    result.push({ x, y, angle: Math.atan2(y - 0.69, x - 0.5) + Math.PI / 2, light: next() > 0.45 });
  }
  return result;
})();

// Offscreen layers stand in for SwiftUI's `drawLayer { $0.addFilter(...) }`: a group of shapes is
// drawn, then composited once through a filter. Grow-only canvases, reused per nesting depth.
const layerPool: HTMLCanvasElement[] = [];
let layerDepth = 0;

function withLayer(ctx: Ctx, filter: (deviceScale: number) => string, draw: (layer: Ctx) => void): void {
  const width = ctx.canvas.width;
  const height = ctx.canvas.height;
  let canvas = layerPool[layerDepth];
  if (!canvas) {
    canvas = document.createElement("canvas");
    layerPool[layerDepth] = canvas;
  }
  if (canvas.width < width || canvas.height < height) {
    canvas.width = Math.max(canvas.width, width);
    canvas.height = Math.max(canvas.height, height);
  }
  const layer = canvas.getContext("2d");
  if (!layer) return;
  layer.reset();
  const transform = ctx.getTransform();
  layer.setTransform(transform);
  layerDepth++;
  try {
    draw(layer);
  } finally {
    layerDepth--;
  }
  // Canvas filter lengths are device pixels; Swift's are in the (scaled) user space.
  const scale = Math.sqrt(Math.abs(transform.a * transform.d - transform.b * transform.c));
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.filter = filter(scale);
  ctx.drawImage(canvas, 0, 0, width, height, 0, 0, width, height);
  ctx.restore();
}

const blur = (radius: number) => (scale: number) => `blur(${radius * scale}px)`;

// Mood marks are glyphs in the rounded heavy system font. Each glyph's ink is fitted to the box
// SF Pro Rounded Heavy gives it on the Mac (text centered on its advance and line box, like
// `GraphicsContext.draw(Text, at:)`), so any fallback face lands at the same size and place.
const GLYPH_FONT = `800 100px ui-rounded, "SF Pro Rounded", "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif`;
const GLYPH_BOXES: Record<string, { cx: number; cy: number; height: number }> = {
  z: { cx: 0.0031, cy: 0.1121, height: 0.5317 },
  "?": { cx: -0.0007, cy: 0.0304, height: 0.7272 },
};
const glyphInk = new Map<string, { cx: number; cy: number; height: number }>();

function drawGlyph(ctx: Ctx, character: "z" | "?", x: number, y: number, size: number, fill: string): void {
  const box = GLYPH_BOXES[character];
  ctx.save();
  ctx.font = GLYPH_FONT;
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  let ink = glyphInk.get(character);
  if (!ink) {
    const metrics = ctx.measureText(character);
    const ascent = metrics.actualBoundingBoxAscent;
    const descent = metrics.actualBoundingBoxDescent;
    ink = {
      cx: (metrics.actualBoundingBoxRight - metrics.actualBoundingBoxLeft) / 2,
      cy: (descent - ascent) / 2,
      height: ascent + descent,
    };
    if (ink.height > 0) glyphInk.set(character, ink);
  }
  // Drawn at a fixed 100px and scaled, so the glyph cache sees one size however the mark animates.
  const scale = ink.height > 0 ? (box.height * size) / ink.height : size / 100;
  ctx.translate(x + box.cx * size, y + box.cy * size);
  ctx.scale(scale, scale);
  ctx.fillStyle = fill;
  ctx.fillText(character, -ink.cx, -ink.cy);
  ctx.restore();
}

// MARK: - Renderer

/// `CantripMascotRenderer`.
class Renderer {
  private readonly mood: MascotMood;
  private readonly outfit: Outfit;
  private readonly size: number;
  private readonly time: number;
  private readonly celebration: number | null;
  private readonly motion: boolean;
  private readonly dark: boolean;

  constructor(options: DrawMascotOptions) {
    this.mood = options.mood;
    this.outfit = outfitFor(options.outfit);
    this.size = options.size;
    this.motion = !options.reduceMotion;
    this.time = this.motion ? options.time : 1;
    this.celebration = options.celebration ?? null;
    this.dark = options.dark ?? true;
  }

  draw(ctx: Ctx): void {
    const s = this.size;
    if (!(s > 0)) return;
    ctx.save();
    // CantripMascotView: `.saturation(mood == .sleeping ? 0.72 : 1).clipShape(Circle())`.
    ctx.beginPath();
    ctx.arc(0.5 * s, 0.5 * s, 0.5 * s, 0, Math.PI * 2);
    ctx.clip();
    if (this.mood === "sleeping") withLayer(ctx, () => "saturate(0.72)", (layer) => this.drawScene(layer));
    else this.drawScene(ctx);
    ctx.restore();
    // `.overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }`, outside the clip.
    ctx.save();
    ctx.beginPath();
    ctx.arc(0.5 * s, 0.5 * s, Math.max(0, 0.5 * s - 0.5), 0, Math.PI * 2);
    ctx.strokeStyle = rgba(WHITE, 0.7);
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
  }

  private drawScene(ctx: Ctx): void {
    const s = this.size;
    const p = (unit: number) => unit * s;
    const { mood, outfit, motion } = this;
    const palette = outfit.palette;
    const isCat = outfit.isCat;

    ellipse(ctx, p(0.5), p(0.5), p(0.5), p(0.5));
    ctx.fillStyle = radial(ctx, this.dark ? palette.darkBackground : palette.background, p(0.36), p(0.28), 0.78 * s);
    ctx.fill();

    const t = this.time;
    const breathePeriod = mood === "sleeping" ? 4.6 : 3.2;
    const breathe = Math.sin((t * 2 * Math.PI) / breathePeriod);
    const progress = this.celebration === null ? null : this.celebration / CELEBRATION_DURATION;
    const hop = motion && progress !== null ? Math.abs(Math.sin(progress * 2 * Math.PI)) * 0.07 : 0;
    const tilt = this.tilt(t);

    ctx.save();
    ctx.translate(0.5 * s, 0.98 * s);
    ctx.rotate(deg(motion ? tilt : roundHalfAway(tilt)));
    ctx.scale(1 - breathe * 0.008, 1 + breathe * (mood === "sleeping" ? 0.03 : 0.018));
    ctx.translate(-0.5 * s, -0.98 * s - hop * s);

    if (outfit.id === "dinoHoodie") this.drawSpikes(ctx, s, progress);
    if (isCat) {
      this.drawTail(ctx, s, t, progress);
      this.drawPandaEars(ctx, s);
    }
    const hood = hoodPath(s, palette.fluff);
    withLayer(ctx, blur((palette.fur ? 0.0045 : 0.002) * s), (fluff) => {
      fluff.fillStyle = radial(fluff, palette.hood, p(0.36), p(0.3), 0.8 * s);
      fluff.fill(hood);
    });
    if (palette.fur) {
      withLayer(ctx, blur(0.005 * s), (fur) => {
        const light = rgba(WHITE, 0.2);
        const dark = rgba(palette.recess, isCat ? 0.07 : 0.13);
        for (const tuft of TUFTS) {
          fur.save();
          fur.translate(tuft.x * s, tuft.y * s);
          fur.rotate(tuft.angle);
          ellipse(fur, 0, 0, 0.026 * s, 0.007 * s);
          fur.fillStyle = tuft.light ? light : dark;
          fur.fill();
          fur.restore();
        }
      });
    }
    withLayer(ctx, blur(0.014 * s), (rim) => {
      rim.strokeStyle = rgba(WHITE, 0.4);
      rim.lineWidth = 0.02 * s;
      rim.stroke(hood);
    });

    if (outfit.id === "dinoHoodie") {
      ellipse(ctx, p(0.5), p(0.9), p(0.165), p(0.1));
      ctx.fillStyle = linear(ctx, [[0.9, 0.97, 0.7], [0.78, 0.9, 0.52]], p(0.5), p(0.8), p(0.5), p(1.0));
      ctx.fill();
      this.drawHoodEyes(ctx, s);
    }
    if (isCat) this.drawBambooClip(ctx, s, t, progress);
    withLayer(ctx, blur(0.03 * s), (shadow) => {
      ellipse(shadow, p(0.5), p(0.585), p(0.24), p(0.21));
      shadow.fillStyle = rgba(palette.recess, isCat ? 0.55 : 0.75);
      shadow.fill();
      ellipse(shadow, p(0.5), p(0.79), p(0.17), p(0.035));
      shadow.fillStyle = rgba(palette.recess, 0.35);
      shadow.fill();
    });
    if (isCat) {
      this.drawCatFace(ctx, s);
    } else {
      ellipse(ctx, p(0.5), p(0.57), p(0.205), p(0.178));
      ctx.fillStyle = radial(ctx, [[1.0, 0.97, 0.94], [0.99, 0.9, 0.84], [0.94, 0.8, 0.73]], p(0.45), p(0.49), 0.25 * s);
      ctx.fill();
    }
    if (outfit.id === "dinoHoodie") this.drawTeeth(ctx, s);

    withLayer(ctx, blur(0.018 * s), (blush) => {
      blush.fillStyle = rgba([1.0, 0.52, 0.62], isCat ? 0.55 : 0.6);
      for (const x of isCat ? [0.345, 0.655] : [0.37, 0.63]) {
        ellipse(blush, p(x), p(isCat ? 0.638 : 0.612), p(isCat ? 0.038 : 0.042), p(isCat ? 0.027 : 0.024));
        blush.fill();
      }
    });

    if (isCat) this.drawCatEyes(ctx, s, progress);
    else this.drawEyes(ctx, s, progress);
    this.drawBrows(ctx, s);
    this.drawMouth(ctx, s);
    if (isCat) this.drawWhiskers(ctx, s, t);

    for (const x of [0.375, 0.625]) {
      ellipse(ctx, p(x), p(0.905), p(0.066), p(0.05));
      ctx.fillStyle = linear(ctx, palette.paw, p(x), p(0.855), p(x), p(0.955));
      ctx.fill();
      ctx.strokeStyle = rgba(palette.recess, 0.18);
      ctx.lineWidth = 0.007 * s;
      ctx.stroke();
      if (outfit.id === "dinoHoodie") {
        ctx.fillStyle = rgba(WHITE, 0.95);
        for (const [dx, dy] of [[-0.03, 0.866], [0, 0.86], [0.03, 0.866]]) {
          ellipse(ctx, p(x + dx), p(dy), p(0.009), p(0.012));
          ctx.fill();
        }
      }
      if (isCat) {
        ctx.fillStyle = rgba([1.0, 0.7, 0.78]);
        ellipse(ctx, p(x), p(0.917), p(0.026), p(0.02));
        ctx.fill();
        for (const [dx, dy] of [[-0.033, 0.879], [0, 0.869], [0.033, 0.879]]) {
          ellipse(ctx, p(x + dx), p(dy), p(0.012), p(0.012));
          ctx.fill();
        }
      }
    }

    if (outfit.id === "starryPlush") this.drawStar(ctx, s, t, progress);
    ctx.restore();

    this.drawAccents(ctx, s, t, progress);
  }

  private tilt(t: number): number {
    switch (this.mood) {
      case "idle": return 1.5 * Math.sin((t * 2 * Math.PI) / 7);
      case "thinking": return 4 * Math.sin((t * 2 * Math.PI) / 2.6);
      case "searching": return 3 * Math.sin(t * 2.2);
      case "working": return 1.6 * Math.sin(t * 7);
      case "writing": return -2 + 1.2 * Math.sin(t * 1.8);
      case "listening": return 6 + 1.5 * Math.sin(t * 2);
      case "speaking": return 2 * Math.sin(t * 3);
      case "curious": return -9 + 1.5 * Math.sin(t * 1.7);
      case "concerned": return -4 + Math.sin(t * 1.3);
      case "sleeping": return 5;
    }
  }

  private drawStar(ctx: Ctx, s: number, t: number, progress: number | null): void {
    const { mood, motion } = this;
    ctx.save();
    const twinkle = 1 + 0.07 * Math.sin(t * 2.2);
    const spin = progress !== null ? progress * 360 : mood === "thinking" ? t * 60 : 0;
    ctx.translate(0.61 * s, 0.205 * s);
    ctx.rotate(deg(14 + (motion ? spin : 0)));
    ctx.scale(twinkle, twinkle);
    const star = starPath(5, 0.074 * s, 0.034 * s);
    withLayer(ctx, blur(0.03 * s), (glow) => {
      glow.fillStyle = rgba([1.0, 0.85, 0.4], mood === "thinking" || progress !== null ? 0.9 : 0.45);
      glow.fill(star);
    });
    ctx.fillStyle = linear(ctx, [[1.0, 0.93, 0.58], [1.0, 0.78, 0.3], [0.95, 0.62, 0.2]], 0, -0.074 * s, 0, 0.074 * s);
    ctx.fill(star);
    ctx.strokeStyle = rgba([0.85, 0.55, 0.16]);
    ctx.lineWidth = 0.008 * s;
    ctx.stroke(star);
    ellipseIn(ctx, -0.03 * s, -0.035 * s, 0.02 * s, 0.02 * s);
    ctx.fillStyle = rgba(WHITE, 0.85);
    ctx.fill();
    ctx.restore();
  }

  /// Soft felt plates along the hood's crown, drawn behind the hood so their bases tuck in.
  private drawSpikes(ctx: Ctx, s: number, progress: number | null): void {
    const wiggle = this.motion && progress !== null ? Math.sin(progress * 4 * Math.PI) * 0.12 : 0;
    const fill = linear(ctx, [[1.0, 0.88, 0.45], [0.98, 0.68, 0.26]], 0, 0.1 * s, 0, 0.26 * s);
    [0.052, 0.07, 0.082, 0.07, 0.052].forEach((height, index) => {
      const theta = 1.5 * Math.PI + (index - 2) * 0.34 + wiggle * (index - 2);
      const { x: bx, y: by, nx, ny } = hoodEdge(theta);
      const tx = -ny;
      const ty = nx;
      const point = (along: number, out: number): [number, number] =>
        [(bx + tx * along + nx * out) * s, (by + ty * along + ny * out) * s];
      ctx.beginPath();
      ctx.moveTo(...point(-0.042, -0.02));
      ctx.lineTo(...point(-0.011, height - 0.012));
      ctx.quadraticCurveTo(...point(0, height + 0.006), ...point(0.011, height - 0.012));
      ctx.lineTo(...point(0.042, -0.02));
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.strokeStyle = rgba([0.86, 0.52, 0.16], 0.7);
      ctx.lineWidth = 0.006 * s;
      ctx.stroke();
    });
  }

  /// The hoodie's own felt eyes, glancing down at the wearer.
  private drawHoodEyes(ctx: Ctx, s: number): void {
    for (const [x, lean] of [[0.405, 0.008], [0.595, -0.008]]) {
      ellipseIn(ctx, (x - 0.04) * s, 0.262 * s, 0.08 * s, 0.076 * s);
      ctx.fillStyle = rgba(WHITE);
      ctx.fill();
      ctx.strokeStyle = rgba([0.12, 0.38, 0.18], 0.35);
      ctx.lineWidth = 0.006 * s;
      ctx.stroke();
      ellipseIn(ctx, (x + lean - 0.019) * s, 0.293 * s, 0.038 * s, 0.04 * s);
      ctx.fillStyle = rgba(INK);
      ctx.fill();
      ellipseIn(ctx, (x + lean - 0.006) * s, 0.297 * s, 0.013 * s, 0.013 * s);
      ctx.fillStyle = rgba(WHITE, 0.9);
      ctx.fill();
    }
  }

  /// Rounded felt teeth framing the face like the hoodie's open jaw.
  private drawTeeth(ctx: Ctx, s: number): void {
    const tooth = (degrees: number, length: number, width: number) => {
      const theta = deg(degrees);
      const ex = 0.5 + 0.205 * Math.cos(theta);
      const ey = 0.57 + 0.178 * Math.sin(theta);
      const span = Math.hypot(0.5 - ex, 0.57 - ey);
      const ix = (0.5 - ex) / span;
      const iy = (0.57 - ey) / span;
      const sx = -iy;
      const sy = ix;
      const point = (along: number, into: number): [number, number] =>
        [(ex + sx * along + ix * into) * s, (ey + sy * along + iy * into) * s];
      ctx.beginPath();
      ctx.moveTo(...point(-width / 2, -0.012));
      ctx.lineTo(...point(-width * 0.12, length - 0.006));
      ctx.quadraticCurveTo(...point(0, length + 0.004), ...point(width * 0.12, length - 0.006));
      ctx.lineTo(...point(width / 2, -0.012));
      ctx.closePath();
      ctx.fillStyle = rgba(WHITE);
      ctx.fill();
      ctx.strokeStyle = rgba([0.12, 0.38, 0.18], 0.22);
      ctx.lineWidth = 0.005 * s;
      ctx.stroke();
    };
    // `stride(from: 212.0, through: 328.0, by: 23.2)`
    for (let index = 0; 212 + 23.2 * index <= 328; index++) tooth(212 + 23.2 * index, 0.036, 0.05);
    for (const degrees of [62, 90, 118]) tooth(degrees, 0.026, 0.04);
  }

  /// A plush blue-grey tail curling up from behind the onesie. It sways with the mood and puffs up when worried.
  private drawTail(ctx: Ctx, s: number, t: number, progress: number | null): void {
    const { mood } = this;
    let sway: number;
    if (progress !== null) sway = 0.05 * Math.sin(progress * 4 * Math.PI);
    else if (!this.motion) sway = 0;
    else {
      switch (mood) {
        case "sleeping": sway = 0; break;
        case "working": case "searching": sway = 0.028 * Math.sin(t * 5); break;
        case "thinking": case "writing": sway = 0.024 * Math.sin(t * 2.4); break;
        case "curious": case "listening": sway = 0.014 * Math.sin(t * 1.6); break;
        case "concerned": sway = 0.008 * Math.sin(t * 9); break;
        default: sway = 0.034 * Math.sin((t * 2 * Math.PI) / 3.4);
      }
    }
    const width = mood === "concerned" ? 0.07 : 0.052;
    const tipY = mood === "sleeping" ? 0.6 : 0.46;
    const tail = new Path2D();
    tail.moveTo(0.26 * s, 0.88 * s);
    tail.bezierCurveTo(0.04 * s, 0.9 * s, (0.05 + sway * 0.5) * s, (tipY + 0.16) * s, (0.08 + sway) * s, tipY * s);
    // A question-mark hook at the tip, curling outward like a friendly cat's tail.
    tail.quadraticCurveTo((0.09 + sway) * s, (tipY - 0.07) * s, (0.035 + sway * 1.3) * s, (tipY - 0.03) * s);
    ctx.save();
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = rgba([0.36, 0.4, 0.48]);
    ctx.lineWidth = (width + 0.012) * s;
    ctx.stroke(tail);
    ctx.strokeStyle = linear(ctx, [[0.8, 0.83, 0.89], [0.6, 0.64, 0.72]], 0.06 * s, 0.42 * s, 0.22 * s, 0.86 * s);
    ctx.lineWidth = width * s;
    ctx.stroke(tail);
    ctx.restore();
  }

  /// Big round plush-black ears on the panda hood with a soft velvet sheen, drawn behind it so their bases tuck in.
  private drawPandaEars(ctx: Ctx, s: number): void {
    const centers = [-1, 1].map((side) => {
      const edge = hoodEdge(1.5 * Math.PI + side * 0.62);
      return { x: edge.x + edge.nx * 0.024, y: edge.y + edge.ny * 0.024 };
    });
    const radius = 0.086;
    withLayer(ctx, blur(0.0018 * s), (ears) => {
      for (const center of centers) {
        ellipse(ears, center.x * s, center.y * s, radius * s, radius * s);
        ears.fillStyle = radial(ears, [[0.3, 0.3, 0.35], [0.12, 0.12, 0.15]],
          (center.x - 0.025) * s, (center.y - 0.035) * s, radius * 1.4 * s);
        ears.fill();
      }
    });
    withLayer(ctx, blur(0.012 * s), (sheen) => {
      sheen.fillStyle = rgba(WHITE, 0.28);
      for (const center of centers) {
        ellipse(sheen, (center.x - 0.022) * s, (center.y - 0.03) * s, 0.03 * s, 0.02 * s);
        sheen.fill();
      }
    });
  }

  /// A little bamboo-leaf clip pinned to the hood beside the left ear, swaying gently.
  private drawBambooClip(ctx: Ctx, s: number, t: number, progress: number | null): void {
    const sway = progress !== null ? 8 * Math.sin(progress * 4 * Math.PI) : this.motion ? 3 * Math.sin(t * 1.6) : 0;
    const outline = rgba([0.16, 0.42, 0.2], 0.55);
    ctx.save();
    ctx.translate(0.375 * s, 0.29 * s);
    for (const [angle, length, width] of [[-64, 0.082, 0.024], [-22, 0.1, 0.029], [22, 0.074, 0.022]]) {
      ctx.save();
      ctx.rotate(deg(angle + sway));
      const blade = new Path2D();
      blade.moveTo(0, 0);
      blade.quadraticCurveTo(width * s, -length * 0.42 * s, 0, -length * s);
      blade.quadraticCurveTo(-width * s, -length * 0.58 * s, 0, 0);
      ctx.fillStyle = linear(ctx, [[0.6, 0.86, 0.42], [0.26, 0.6, 0.27]], 0, -length * s, 0, 0);
      ctx.fill(blade);
      ctx.strokeStyle = outline;
      ctx.lineWidth = 0.004 * s;
      ctx.stroke(blade);
      ctx.beginPath();
      ctx.moveTo(0, -0.01 * s);
      ctx.lineTo(0, -length * 0.72 * s);
      ctx.strokeStyle = rgba(WHITE, 0.45);
      ctx.lineCap = "round";
      ctx.stroke();
      ctx.restore();
    }
    ctx.beginPath();
    ctx.roundRect(-0.014 * s, -0.01 * s, 0.028 * s, 0.024 * s, 0.009 * s);
    ctx.fillStyle = linear(ctx, [[0.72, 0.86, 0.45], [0.44, 0.66, 0.28]], 0, -0.01 * s, 0, 0.014 * s);
    ctx.fill();
    ctx.strokeStyle = outline;
    ctx.lineWidth = 0.004 * s;
    ctx.stroke();
    ctx.restore();
  }

  /// A round, cartoony British Shorthair face in plush blue-grey with a soft outline, rounded ears
  /// peeking out of the hood and lighter whisker pads.
  private drawCatFace(ctx: Ctx, s: number): void {
    const fur = radial(ctx, [[0.84, 0.87, 0.92], [0.7, 0.74, 0.81], [0.55, 0.59, 0.67]], 0.44 * s, 0.5 * s, 0.28 * s);
    for (const mirror of [false, true]) {
      const px = (x: number) => (mirror ? 1 - x : x) * s;
      const py = (y: number) => y * s;
      ctx.beginPath();
      ctx.moveTo(px(0.312), py(0.52));
      ctx.quadraticCurveTo(px(0.298), py(0.45), px(0.318), py(0.39));
      ctx.quadraticCurveTo(px(0.326), py(0.34), px(0.37), py(0.362));
      ctx.quadraticCurveTo(px(0.42), py(0.378), px(0.47), py(0.425));
      ctx.closePath();
      ctx.fillStyle = fur;
      ctx.fill();
      ctx.save();
      ctx.strokeStyle = CAT_OUTLINE;
      ctx.lineWidth = 0.008 * s;
      ctx.lineJoin = "round";
      ctx.stroke();
      ctx.restore();
      ctx.beginPath();
      ctx.moveTo(px(0.335), py(0.49));
      ctx.quadraticCurveTo(px(0.326), py(0.44), px(0.337), py(0.405));
      ctx.quadraticCurveTo(px(0.343), py(0.375), px(0.37), py(0.39));
      ctx.quadraticCurveTo(px(0.41), py(0.4), px(0.44), py(0.44));
      ctx.closePath();
      ctx.fillStyle = linear(ctx, [[1.0, 0.72, 0.78], [0.88, 0.62, 0.7]], px(0.345), py(0.39), px(0.4), py(0.47));
      ctx.fill();
    }
    ellipse(ctx, 0.5 * s, 0.585 * s, 0.205 * s, 0.193 * s);
    ctx.fillStyle = fur;
    ctx.fill();
    ctx.strokeStyle = CAT_OUTLINE;
    ctx.lineWidth = 0.008 * s;
    ctx.stroke();
    withLayer(ctx, blur(0.006 * s), (pads) => {
      pads.fillStyle = rgba([0.9, 0.92, 0.95]);
      for (const x of [0.476, 0.524]) {
        ellipse(pads, x * s, 0.627 * s, 0.033 * s, 0.024 * s);
        pads.fill();
      }
    });
  }

  /** The eyes' pose for the mood: gaze x and y in about -1...1, and a size scale. */
  private gaze(t: number, cat: boolean): [number, number, number] {
    switch (this.mood) {
      case "thinking": return [0.7, -0.8 + 0.1 * Math.sin(t * 3), 1];
      case "searching": return [1.1 * Math.sin(t * 2.2), -0.2, cat ? 1.03 : 1.06];
      case "working": return [0.2, 0.7, cat ? 0.95 : 0.92];
      case "writing": return [-0.5 + 0.25 * Math.sin(t * 1.4), 0.8, 1];
      case "listening": return [-0.15, 0, cat ? 1.06 : 1.12];
      case "curious": return [0.35, -0.35, cat ? 1.1 : 1.16];
      case "concerned": return [0, -0.2, cat ? 0.97 : 0.95];
      case "speaking": return [0, 0.1, 1];
      default: return [Math.sin(t * 0.55) * Math.sin(t * 0.21) * 1.4, 0, 1];
    }
  }

  /** Strokes the current path with a round cap, like `StrokeStyle(lineWidth:lineCap: .round)`. */
  private strokeRound(ctx: Ctx, width: number, color: string = rgba(INK), join: CanvasLineJoin = "miter"): void {
    ctx.save();
    ctx.lineWidth = width;
    ctx.lineCap = "round";
    ctx.lineJoin = join;
    ctx.strokeStyle = color;
    ctx.stroke();
    ctx.restore();
  }

  /// Big round copper cartoon eyes with two highlights; pupils widen when attentive and narrow
  /// when focused or worried.
  private drawCatEyes(ctx: Ctx, s: number, progress: number | null): void {
    const t = this.time;
    const line = 0.017 * s;
    for (const x of [0.415, 0.585]) {
      const y = 0.568;
      if (progress !== null || this.mood === "sleeping") {
        const lift = progress !== null ? -0.034 : 0.026;
        const baseline = y + (progress !== null ? 0.01 : -0.004);
        ctx.beginPath();
        ctx.moveTo((x - 0.034) * s, baseline * s);
        ctx.quadraticCurveTo(x * s, (y + lift) * s, (x + 0.034) * s, baseline * s);
        this.strokeRound(ctx, line);
        continue;
      }
      const [gx, gy, scale] = this.gaze(t, true);
      const open = openness(t);
      const gazeX = Math.max(-1, Math.min(1, gx));
      const cx = x + gazeX * 0.004;
      const cy = y + gy * 0.005;
      if (open < 0.22) {
        ctx.beginPath();
        ctx.moveTo((cx - 0.032) * s, cy * s);
        ctx.lineTo((cx + 0.032) * s, cy * s);
        this.strokeRound(ctx, line);
        continue;
      }
      const radius = 0.046 * scale;
      ellipse(ctx, cx * s, cy * s, radius * s, radius * open * s);
      ctx.fillStyle = radial(ctx, [[1.0, 0.88, 0.45], [0.98, 0.64, 0.2], [0.8, 0.42, 0.12]], cx * s, (cy + 0.016) * s, radius * s);
      ctx.fill();
      ctx.strokeStyle = rgba(INK);
      ctx.lineWidth = 0.008 * s;
      ctx.stroke();
      const [pw, ph] = this.mood === "curious" || this.mood === "listening" ? [0.031, 0.034]
        : this.mood === "working" || this.mood === "concerned" || this.mood === "searching" ? [0.011, 0.032]
        : [0.025, 0.031];
      const px = cx + gazeX * 0.009;
      const py = cy + gy * 0.005;
      ellipse(ctx, px * s, py * s, pw * scale * s, ph * scale * open * s);
      ctx.fillStyle = rgba(INK);
      ctx.fill();
      ellipse(ctx, (cx - 0.015 * scale) * s, (cy - 0.016 * scale * open) * s, 0.013 * scale * s, 0.013 * scale * open * s);
      ctx.fillStyle = rgba(WHITE, 0.97);
      ctx.fill();
      ellipse(ctx, (cx + 0.015 * scale) * s, (cy + 0.016 * scale * open) * s, 0.0055 * scale * s, 0.0055 * scale * open * s);
      ctx.fillStyle = rgba(WHITE, 0.85);
      ctx.fill();
    }
  }

  private drawCatNose(ctx: Ctx, s: number): void {
    ctx.beginPath();
    ctx.moveTo(0.486 * s, 0.6 * s);
    ctx.quadraticCurveTo(0.5 * s, 0.594 * s, 0.514 * s, 0.6 * s);
    ctx.quadraticCurveTo(0.513 * s, 0.609 * s, 0.5 * s, 0.614 * s);
    ctx.quadraticCurveTo(0.487 * s, 0.609 * s, 0.486 * s, 0.6 * s);
    ctx.fillStyle = linear(ctx, [[1.0, 0.74, 0.8], [0.94, 0.52, 0.62]], 0.5 * s, 0.595 * s, 0.5 * s, 0.614 * s);
    ctx.fill();
    ctx.save();
    ctx.strokeStyle = rgba([0.6, 0.3, 0.38], 0.7);
    ctx.lineWidth = 0.004 * s;
    ctx.lineJoin = "round";
    ctx.stroke();
    ctx.restore();
  }

  /// Short white whiskers poking out past the cheeks; they twitch while listening, speaking or searching.
  private drawWhiskers(ctx: Ctx, s: number, t: number): void {
    const twitches = this.mood === "listening" || this.mood === "speaking" || this.mood === "searching";
    const twitch = this.motion && twitches ? 0.006 * Math.sin(t * 8) : 0;
    for (const side of [-1, 1]) {
      [[0.628, 0.6], [0.642, 0.64], [0.656, 0.68]].forEach(([startY, endY], index) => {
        const end = endY + twitch * (index - 1);
        ctx.beginPath();
        ctx.moveTo((0.5 + side * 0.15) * s, startY * s);
        ctx.quadraticCurveTo((0.5 + side * 0.21) * s, ((startY + end) / 2 - 0.006) * s, (0.5 + side * 0.268) * s, end * s);
        this.strokeRound(ctx, 0.007 * s, rgba(WHITE, 0.92));
      });
    }
  }

  private drawEyes(ctx: Ctx, s: number, progress: number | null): void {
    const t = this.time;
    const line = 0.017 * s;
    for (const x of [0.42, 0.58]) {
      const y = 0.555;
      if (progress !== null || this.mood === "sleeping") {
        const lift = progress !== null ? -0.03 : 0.024;
        const baseline = y + (progress !== null ? 0.008 : -0.004);
        ctx.beginPath();
        ctx.moveTo((x - 0.027) * s, baseline * s);
        ctx.quadraticCurveTo(x * s, (y + lift) * s, (x + 0.027) * s, baseline * s);
        this.strokeRound(ctx, line);
        continue;
      }
      const [gx, gy, scale] = this.gaze(t, false);
      const open = openness(t);
      const cx = x + Math.max(-1, Math.min(1, gx)) * 0.012;
      const cy = y + gy * 0.01;
      if (open < 0.22) {
        ctx.beginPath();
        ctx.moveTo((cx - 0.024) * s, cy * s);
        ctx.lineTo((cx + 0.024) * s, cy * s);
        this.strokeRound(ctx, line);
        continue;
      }
      const rx = 0.026 * scale;
      const ry = 0.036 * scale * open;
      ellipse(ctx, cx * s, cy * s, rx * s, ry * s);
      ctx.fillStyle = rgba(INK);
      ctx.fill();
      ellipseIn(ctx, (cx - 0.003) * s, (cy - ry * 0.75) * s, 0.019 * s, 0.019 * s * open);
      ctx.fillStyle = rgba(WHITE, 0.95);
      ctx.fill();
    }
  }

  /// Focused brows slope inward while working; worried brows lift inward when something went wrong.
  private drawBrows(ctx: Ctx, s: number): void {
    if (this.celebration !== null || (this.mood !== "working" && this.mood !== "concerned")) return;
    const inner = this.mood === "working" ? 0.503 : 0.484;
    const outer = this.mood === "working" ? 0.49 : 0.503;
    for (const [outerX, innerX] of [[0.392, 0.448], [0.608, 0.552]]) {
      ctx.beginPath();
      ctx.moveTo(outerX * s, outer * s);
      ctx.lineTo(innerX * s, inner * s);
      this.strokeRound(ctx, 0.011 * s, rgba(INK, 0.85));
    }
  }

  private drawMouth(ctx: Ctx, s: number): void {
    const t = this.time;
    const line = 0.013 * s;
    const { mood, motion, outfit, celebration } = this;
    if (outfit.isCat) this.drawCatNose(ctx, s);
    if (outfit.isCat && celebration === null && !["speaking", "curious", "thinking", "searching", "working", "writing", "concerned"].includes(mood)) {
      ctx.beginPath();
      ctx.moveTo(0.5 * s, 0.613 * s);
      ctx.lineTo(0.5 * s, 0.621 * s);
      ctx.moveTo(0.474 * s, 0.622 * s);
      ctx.quadraticCurveTo(0.486 * s, 0.637 * s, 0.5 * s, 0.621 * s);
      ctx.quadraticCurveTo(0.514 * s, 0.637 * s, 0.526 * s, 0.622 * s);
      this.strokeRound(ctx, 0.011 * s, rgba(INK), "round");
      return;
    }
    // The cat's mouth sits just under its nose, so its other mood mouths drop slightly.
    ctx.save();
    if (outfit.isCat) ctx.translate(0, 0.021 * s);
    const curve = (x0: number, y0: number, cx: number, cy: number, x1: number, y1: number) => {
      ctx.beginPath();
      ctx.moveTo(x0 * s, y0 * s);
      ctx.quadraticCurveTo(cx * s, cy * s, x1 * s, y1 * s);
      this.strokeRound(ctx, line);
    };
    switch (mood) {
      case "speaking": {
        const open = motion ? 0.35 + 0.65 * Math.abs(Math.sin(t * 9)) * Math.abs(Math.sin(t * 2.3 + 0.6)) : 0.6;
        const ry = 0.006 + 0.016 * open;
        ellipseIn(ctx, 0.483 * s, (0.616 - ry) * s, 0.034 * s, ry * 2 * s);
        ctx.fillStyle = rgba([0.45, 0.2, 0.3]);
        ctx.fill();
        break;
      }
      case "curious":
        ellipseIn(ctx, 0.489 * s, 0.602 * s, 0.022 * s, 0.026 * s);
        this.strokeRound(ctx, line);
        break;
      case "thinking":
        curve(0.49, 0.618, 0.51, 0.624, 0.53, 0.612);
        break;
      case "searching":
        curve(0.478, 0.613, 0.505, 0.628, 0.522, 0.606);
        break;
      case "working":
        ctx.beginPath();
        ctx.moveTo(0.484 * s, 0.616 * s);
        ctx.lineTo(0.518 * s, 0.613 * s);
        this.strokeRound(ctx, line);
        break;
      case "writing":
        curve(0.484, 0.609, 0.5, 0.624, 0.516, 0.609);
        break;
      case "concerned":
        curve(0.477, 0.624, 0.5, 0.604, 0.523, 0.624);
        break;
      default: {
        const wide = celebration !== null ? 0.034 : 0.024;
        curve(0.5 - wide, 0.607, 0.5, celebration !== null ? 0.645 : 0.632, 0.5 + wide, 0.607);
      }
    }
    ctx.restore();
  }

  private drawAccents(ctx: Ctx, s: number, t: number, progress: number | null): void {
    const { mood, motion } = this;
    const accent = this.outfit.palette.accent;
    if (mood === "thinking" || progress !== null) {
      const sparkle = starPath(4, 0.04 * s, 0.012 * s);
      for (const [x, y, phase] of [[0.8, 0.16, 0.0], [0.87, 0.33, 2.1], [0.2, 0.22, 4.2]]) {
        const pulse = motion ? Math.max(0, Math.sin(t * 3 + phase)) : 0.8;
        if (!(pulse > 0.05)) continue;
        ctx.save();
        ctx.translate(x * s, y * s);
        ctx.scale(pulse, pulse);
        ctx.fillStyle = rgba([1.0, 0.8, 0.32]);
        ctx.fill(sparkle);
        ctx.restore();
      }
    }
    switch (mood) {
      case "sleeping":
        for (let index = 0; index < 2; index++) {
          const phase = motion ? (t / 2.4 + index * 0.5) % 1 : 0.35 + index * 0.3;
          ctx.save();
          ctx.globalAlpha *= Math.sin(phase * Math.PI);
          drawGlyph(ctx, "z", (0.79 + 0.1 * phase) * s, (0.42 - 0.18 * phase) * s, (0.1 + 0.05 * phase) * s, rgba(accent));
          ctx.restore();
        }
        break;
      case "curious":
        drawGlyph(ctx, "?", 0.83 * s, (0.24 + (motion ? 0.015 * Math.sin(t * 3) : 0)) * s, 0.16 * s, rgba(accent));
        break;
      case "listening":
        for (let ring = 1; ring <= 2; ring++) {
          const pulse = motion ? 0.5 + 0.5 * Math.sin(t * 4 - ring) : 0.7;
          ctx.beginPath();
          ctx.arc(0.8 * s, 0.5 * s, (0.04 + 0.045 * ring) * s, deg(-40), deg(40), false);
          this.strokeRound(ctx, 0.018 * s, rgba(accent, 0.35 + 0.5 * pulse));
        }
        break;
      case "searching": {
        const lx = (0.79 + 0.025 * Math.cos(t * 2.2)) * s;
        const ly = (0.22 + 0.02 * Math.sin(t * 2.2)) * s;
        const radius = 0.048 * s;
        ctx.beginPath();
        ctx.moveTo(lx + radius * 0.72, ly + radius * 0.72);
        ctx.lineTo(lx + radius * 1.75, ly + radius * 1.75);
        this.strokeRound(ctx, 0.024 * s, rgba(accent));
        ellipse(ctx, lx, ly, radius, radius);
        ctx.fillStyle = rgba(WHITE, 0.55);
        ctx.fill();
        ctx.strokeStyle = rgba(accent);
        ctx.lineWidth = 0.017 * s;
        ctx.stroke();
        break;
      }
      case "working":
        for (const [x, y, outer, teeth, speed] of [[0.8, 0.19, 0.055, 8, 80], [0.885, 0.3, 0.036, 6, -120]]) {
          ctx.save();
          ctx.translate(x * s, y * s);
          ctx.rotate(deg(t * speed));
          ctx.fillStyle = rgba(accent);
          ctx.fill(gearPath(teeth, outer * s, outer * 0.74 * s, outer * 0.32 * s), "evenodd");
          ctx.restore();
        }
        break;
      case "writing": {
        const bx = 0.69 * s;
        const by = 0.16 * s;
        const bw = 0.17 * s;
        const bh = 0.095 * s;
        ctx.beginPath();
        ctx.roundRect(bx, by, bw, bh, Math.min(0.05 * s, bw / 2, bh / 2));
        ctx.fillStyle = rgba(WHITE, 0.92);
        ctx.fill();
        for (let index = 0; index < 3; index++) {
          const bounce = motion ? Math.max(0, Math.sin(t * 6 - index * 0.9)) : index === 1 ? 1 : 0;
          ellipse(ctx, bx + (0.035 + 0.05 * index) * s, by + bh / 2 - 0.014 * bounce * s, 0.014 * s, 0.014 * s);
          ctx.fillStyle = rgba(accent, 0.55 + 0.45 * bounce);
          ctx.fill();
        }
        break;
      }
      case "concerned": {
        const slide = motion ? (t / 2.2) % 1 : 0.4;
        ctx.save();
        ctx.globalAlpha *= 1 - slide * 0.6;
        ctx.translate(0.765 * s, (0.36 + 0.06 * slide) * s);
        ctx.beginPath();
        ctx.moveTo(0, -0.045 * s);
        ctx.quadraticCurveTo(0.02 * s, -0.015 * s, 0.024 * s, 0.01 * s);
        ctx.arc(0, 0.01 * s, 0.024 * s, 0, Math.PI, false);
        ctx.quadraticCurveTo(-0.02 * s, -0.015 * s, 0, -0.045 * s);
        ctx.fillStyle = rgba([0.55, 0.8, 1.0]);
        ctx.fill();
        ctx.strokeStyle = rgba(WHITE, 0.8);
        ctx.lineWidth = 0.006 * s;
        ctx.stroke();
        ctx.restore();
        break;
      }
      default:
        break;
    }
  }
}
