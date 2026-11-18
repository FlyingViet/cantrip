import { CELEBRATION_DURATION, isBusy, type MascotMood } from "./mascot";

export interface PrivateMascotPack {
  revision: string;
  sparkX: number;
  sparkY: number;
  portrait: CanvasImageSource;
  blink: CanvasImageSource;
  dispose(): void;
}

export const privateRevision = (value: unknown): string | null =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value) ? value : null;

function png(value: unknown): { bytes: Uint8Array; size: number } {
  if (typeof value !== "string" || !value.length || value.length > 2666668
    || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw Error("Invalid personal mascot PNG.");
  const raw = atob(value);
  const bytes = Uint8Array.from(raw, (char) => char.charCodeAt(0));
  if (bytes.length > 2000000 || bytes.length < 33
    || [137, 80, 78, 71, 13, 10, 26, 10].some((byte, index) => bytes[index] !== byte)) throw Error("Invalid personal mascot PNG.");
  const header = new DataView(bytes.buffer);
  const size = header.getUint32(16);
  if (header.getUint32(8) !== 13 || header.getUint32(12) !== 0x49484452
    || size < 1 || size > 1024 || size !== header.getUint32(20)) throw Error("Personal mascot images must be square, up to 1024 pixels.");
  return { bytes, size };
}

/** Validate before decoding; never hand an arbitrary URL or a huge image to the browser. */
export async function decodePrivateMascot(value: unknown, revision: string): Promise<PrivateMascotPack> {
  const data = value as Record<string, unknown> | null;
  if (!data || data.version !== 1 || privateRevision(data.revision) !== revision
    || ![data.sparkX, data.sparkY].every((point) => typeof point === "number" && Number.isFinite(point) && point >= 0 && point <= 1)) {
    throw Error("Invalid personal mascot pack or revision.");
  }
  const portrait = png(data.portrait), blink = png(data.blink);
  if (portrait.size !== blink.size) throw Error("Personal mascot images must have matching sizes.");
  const decoded: ImageBitmap[] = [];
  try {
    // Blobs and decoded bitmaps live only in memory; no image URLs, browser cache or localStorage.
    for (const image of [portrait, blink]) {
      const bitmap = await createImageBitmap(new Blob([image.bytes as BlobPart], { type: "image/png" }));
      decoded.push(bitmap);
      if (bitmap.width !== image.size || bitmap.height !== image.size) throw Error("Invalid personal mascot image size.");
    }
    return {
      revision, sparkX: data.sparkX as number, sparkY: data.sparkY as number,
      portrait: decoded[0], blink: decoded[1], dispose: () => decoded.forEach((image) => image.close()),
    };
  } catch {
    decoded.forEach((image) => image.close());
    throw Error("Could not decode personal mascot PNGs.");
  }
}

export interface PersonalMascotState {
  revision: string | null;
  pack: PrivateMascotPack | null;
  loading: boolean;
  error: string | null;
}

/** One memory-only pack per authenticated connection. Polling drives bounded backoff, never chat. */
export class PrivateMascotLoader {
  state: PersonalMascotState = { revision: null, pack: null, loading: false, error: null };
  connection = "";
  connectionEpoch = 0;
  private generation = 0;
  private enabled = true;
  private attempts = 0;
  private retryAt = 0;
  private controller: AbortController | null = null;
  private hostError: string | null = null;

  constructor(
    private readonly request: (revision: string, signal: AbortSignal) => Promise<unknown>,
    private readonly changed: (state: PersonalMascotState) => void,
    private readonly decode = decodePrivateMascot,
    private readonly now = Date.now,
  ) {}

  private clear(revision: string | null = null): void {
    this.generation++;
    this.controller?.abort();
    this.controller = null;
    this.state.pack?.dispose();
    this.state = { revision, pack: null, loading: false, error: null };
    this.attempts = 0;
    this.retryAt = 0;
  }

  setConnection(connection: string): void {
    if (connection === this.connection) return;
    this.connection = connection;
    this.connectionEpoch++;
    this.clear();
    this.hostError = null;
    this.changed(this.state);
  }

  setEnabled(enabled: boolean): void {
    if (enabled === this.enabled) return;
    this.enabled = enabled;
    this.clear(this.state.revision);
    this.observe(this.state.revision, this.hostError);
  }

  reset(): void {
    this.connectionEpoch++;
    this.clear();
    this.hostError = null;
    this.changed(this.state);
  }

  observe(revision: unknown, error?: unknown): void {
    const next = privateRevision(revision);
    const hostError = typeof error === "string" && error ? error : null;
    if (next !== this.state.revision || hostError !== this.hostError) this.clear(next);
    this.hostError = hostError;
    if (hostError) this.state = { ...this.state, error: `Personal mascot: ${hostError}` };
    this.changed(this.state);
    if (!this.enabled || !this.connection || !next || hostError || this.state.pack || this.state.loading
      || this.attempts >= 3 || this.now() < this.retryAt) return;
    void this.load(next);
  }

  private async load(revision: string): Promise<void> {
    const generation = this.generation;
    const controller = this.controller = new AbortController();
    this.attempts++;
    this.state = { ...this.state, loading: true };
    this.changed(this.state);
    try {
      const data = await this.request(revision, controller.signal);
      if (generation !== this.generation) return;
      const pack = await this.decode(data, revision);
      if (generation !== this.generation) { pack.dispose(); return; }
      this.state = { revision, pack, loading: false, error: null };
    } catch (error) {
      if (generation !== this.generation) return;
      const status = (error as { status?: number })?.status;
      // A stale/removed pack waits for a new listing revision, not repeated image requests.
      if (status === 404 || status === 409) this.attempts = 3;
      this.retryAt = this.now() + (this.attempts === 1 ? 2000 : 8000);
      this.state = { revision, pack: null, loading: false, error: `Personal mascot unavailable: ${error instanceof Error ? error.message : "Could not load the pack."}` };
    }
    if (generation === this.generation) {
      this.controller = null;
      this.changed(this.state);
    }
  }
}

export function personalMascotPose(mood: MascotMood, time: number, reduceMotion: boolean, celebration: number | null) {
  const active = isBusy(mood) || mood === "listening" || mood === "speaking";
  return {
    closed: mood === "sleeping" || (!reduceMotion && ((time % 4.8) + 4.8) % 4.8 >= 4.65),
    scale: reduceMotion ? 1 : 1 + 0.012 * Math.sin(time * Math.PI * 2 / 3.2),
    tilt: reduceMotion ? 0 : (mood === "thinking" ? 4 : 1.5) * Math.PI / 180 * Math.sin(time * Math.PI * 2 / (mood === "thinking" ? 2.6 : 7)),
    hop: reduceMotion || celebration === null || celebration >= CELEBRATION_DURATION ? 0
      : -0.065 * Math.sin(Math.PI * Math.max(0, celebration) / CELEBRATION_DURATION),
    spark: active ? (reduceMotion ? 0.8 : 0.7 + 0.3 * Math.sin(time * Math.PI * 2 / 1.2)) : 0,
  };
}

export function drawPrivateMascot(ctx: CanvasRenderingContext2D, pack: PrivateMascotPack, options: {
  mood: MascotMood; time: number; reduceMotion: boolean; celebration: number | null; size: number; dark: boolean;
}): void {
  const pose = personalMascotPose(options.mood, options.time, options.reduceMotion, options.celebration);
  ctx.save();
  ctx.scale(options.size, options.size);
  ctx.beginPath();
  ctx.arc(0.5, 0.5, 0.5, 0, Math.PI * 2);
  ctx.fillStyle = options.dark ? "#30213f" : "#fff4df";
  ctx.fill();
  ctx.clip();
  ctx.translate(0.5, 0.5 + pose.hop);
  ctx.rotate(pose.tilt);
  ctx.scale(pose.scale, pose.scale);
  ctx.drawImage(pose.closed ? pack.blink : pack.portrait, -0.5, -0.5, 1, 1);
  if (pose.spark) {
    ctx.translate(pack.sparkX - 0.5, pack.sparkY - 0.5);
    ctx.scale(pose.spark, pose.spark);
    ctx.beginPath();
    for (let index = 0; index < 8; index++) {
      const angle = index * Math.PI / 4, radius = index % 2 ? 0.015 : 0.06;
      const x = Math.sin(angle) * radius, y = -Math.cos(angle) * radius;
      if (!index) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fillStyle = "#ffd777";
    ctx.fill();
  }
  ctx.restore();
}
