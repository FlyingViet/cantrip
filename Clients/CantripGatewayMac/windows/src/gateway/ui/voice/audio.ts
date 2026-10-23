// Microphone audio for on-device speech recognition: resampling to Whisper's 16 kHz, an energy-based
// end-of-utterance detector (the Mac's Parakeet EOU debounce, from "Pause before sending"), and
// cleanup of the recognizer's sound annotations.

export const SPEECH_RATE = 16000;

/** Root mean square of a block of samples. */
export function rms(samples: Float32Array, start = 0, end = samples.length): number {
  if (end <= start) return 0;
  let sum = 0;
  for (let i = start; i < end; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / (end - start));
}

/** Blackman-windowed sinc low-pass, `half` taps each side, cutoff as a fraction of the sample rate. */
function lowPass(half: number, cutoff: number): Float32Array {
  const size = half * 2 + 1;
  const taps = new Float32Array(size);
  let sum = 0;
  for (let i = 0; i < size; i++) {
    const n = i - half;
    const sinc = n === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * n) / (Math.PI * n);
    const window = 0.42 - 0.5 * Math.cos((2 * Math.PI * i) / (size - 1)) + 0.08 * Math.cos((4 * Math.PI * i) / (size - 1));
    taps[i] = sinc * window;
    sum += taps[i];
  }
  for (let i = 0; i < size; i++) taps[i] /= sum;
  return taps;
}

/**
 * Streaming sample-rate converter: an anti-aliasing low-pass when downsampling, then linear
 * interpolation. Chunks can be any size; the output is the same as converting all at once.
 */
export class Resampler {
  readonly ratio: number;
  private readonly taps: Float32Array | null;
  private readonly half: number;
  private buffer: Float32Array;
  /** Next output's position, in input samples from buffer[0]. */
  private position: number;

  constructor(readonly from: number, readonly to: number) {
    if (!(from > 0) || !(to > 0)) throw new RangeError("Sample rates must be positive.");
    this.ratio = from / to;
    if (this.ratio > 1) {
      this.half = Math.ceil(16 * this.ratio);
      const size = this.half * 2 + 1;
      // Stopband at the output's Nyquist frequency; the Blackman transition is about 5.5 / size.
      const cutoff = Math.max(0.05, 0.5 / this.ratio - 2.75 / size);
      this.taps = lowPass(this.half, cutoff);
    } else {
      this.half = 1;
      this.taps = null;
    }
    this.buffer = new Float32Array(this.half);
    this.position = this.half;
  }

  private sample(buffer: Float32Array, index: number): number {
    const taps = this.taps;
    if (!taps) return buffer[index];
    let sum = 0;
    const start = index - this.half;
    for (let k = 0; k < taps.length; k++) sum += taps[k] * buffer[start + k];
    return sum;
  }

  process(input: Float32Array): Float32Array {
    if (this.ratio === 1) return input.slice();
    const buffer = new Float32Array(this.buffer.length + input.length);
    buffer.set(this.buffer);
    buffer.set(input, this.buffer.length);
    const capacity = Math.max(0, Math.ceil((buffer.length - this.position) / this.ratio) + 1);
    const out = new Float32Array(capacity);
    let count = 0;
    for (;;) {
      const index = Math.floor(this.position);
      if (index + 1 + this.half >= buffer.length) break;
      const fraction = this.position - index;
      const a = this.sample(buffer, index);
      const b = fraction > 0 ? this.sample(buffer, index + 1) : a;
      out[count++] = a + (b - a) * fraction;
      this.position += this.ratio;
    }
    const drop = Math.max(0, Math.floor(this.position) - this.half);
    this.buffer = buffer.slice(drop);
    this.position -= drop;
    return out.subarray(0, count);
  }

  /** Converts what's still buffered (the end of the stream). */
  flush(): Float32Array {
    if (this.ratio === 1) return new Float32Array(0);
    return this.process(new Float32Array(this.half + 1));
  }
}

/** One-shot conversion (tests, short clips). */
export function resample(input: Float32Array, from: number, to: number): Float32Array {
  if (from === to) return input.slice();
  const resampler = new Resampler(from, to);
  const head = resampler.process(input);
  const tail = resampler.flush();
  const expected = Math.round((input.length * to) / from);
  const out = new Float32Array(expected);
  out.set(head.subarray(0, expected));
  if (head.length < expected) out.set(tail.subarray(0, expected - head.length), head.length);
  return out;
}

// MARK: End of utterance

export interface DetectorOptions {
  sampleRate?: number;
  /** Silence after speech that ends the utterance ("Pause before sending"). */
  pauseSeconds: number;
  frameMs?: number;
  /** Speech this long (in a row) starts the utterance; shorter clicks and taps don't. */
  minSpeechMs?: number;
  /** Quietest level counted as speech, whatever the room noise (about −44 dBFS). */
  minLevel?: number;
  /** Speech is this many times louder than the room's noise floor. */
  noiseRatio?: number;
}

/**
 * Energy-based voice activity: tracks the room's noise floor, starts the utterance after a short
 * run of louder frames, and ends it after `pauseSeconds` without speech.
 */
export class EndOfUtteranceDetector {
  pauseSeconds: number;
  readonly sampleRate: number;
  readonly frameSize: number;
  private readonly minSpeechFrames: number;
  private readonly minLevel: number;
  private readonly noiseRatio: number;
  private readonly pending: Float32Array;
  private pendingCount = 0;
  private floor: number | null = null;
  private run = 0;
  private runStart = 0;
  private silentSamples = 0;
  private processed = 0;
  /** Smoothed input level, 0…1, for the waveform. */
  level = 0;
  speechStarted = false;
  ended = false;
  /** Sample index where speech began, and just past the last speech frame. */
  speechStart = 0;
  speechEnd = 0;

  constructor(options: DetectorOptions) {
    this.sampleRate = options.sampleRate ?? SPEECH_RATE;
    this.pauseSeconds = options.pauseSeconds;
    this.frameSize = Math.round((this.sampleRate * (options.frameMs ?? 30)) / 1000);
    this.minSpeechFrames = Math.max(1, Math.round((options.minSpeechMs ?? 120) / (options.frameMs ?? 30)));
    this.minLevel = options.minLevel ?? 0.006;
    this.noiseRatio = options.noiseRatio ?? 3.2;
    this.pending = new Float32Array(this.frameSize);
  }

  /** Samples seen so far. */
  get length(): number {
    return this.processed + this.pendingCount;
  }

  get noiseFloor(): number {
    return this.floor ?? 0;
  }

  /** How long it's been quiet since the last speech (0 before speech starts). */
  get silenceSeconds(): number {
    return this.speechStarted ? this.silentSamples / this.sampleRate : 0;
  }

  /** Feeds audio; true once the utterance has ended (speech, then a long enough pause). */
  push(samples: Float32Array): boolean {
    let offset = 0;
    while (offset < samples.length) {
      const take = Math.min(this.frameSize - this.pendingCount, samples.length - offset);
      this.pending.set(samples.subarray(offset, offset + take), this.pendingCount);
      this.pendingCount += take;
      offset += take;
      if (this.pendingCount === this.frameSize) {
        this.frame(rms(this.pending));
        this.processed += this.frameSize;
        this.pendingCount = 0;
      }
    }
    return this.ended;
  }

  private frame(energy: number): void {
    const frameStart = this.processed;
    const frameEnd = frameStart + this.frameSize;
    const db = 20 * Math.log10(Math.max(energy, 1e-6));
    const target = Math.min(1, Math.max(0, (db + 60) / 48));
    this.level = target > this.level ? target : this.level * 0.82 + target * 0.18;

    if (this.floor === null) this.floor = energy;
    const floor = this.floor;
    const onset = energy > Math.max(this.minLevel, floor * this.noiseRatio);
    // Hysteresis: a word's quieter tail still counts once speech is under way.
    const sustained = energy > Math.max(this.minLevel * 0.7, floor * this.noiseRatio * 0.6);
    const isSpeech = this.speechStarted ? sustained : onset;

    if (isSpeech) {
      // Follows a louder room very slowly (a fan turning on), never a voice.
      this.floor = floor + (energy - floor) * 0.002;
    } else {
      this.floor = floor + (energy - floor) * (energy < floor ? 0.3 : 0.05);
    }

    if (this.ended) return;
    if (!this.speechStarted) {
      if (isSpeech) {
        if (this.run === 0) this.runStart = frameStart;
        this.run++;
        if (this.run >= this.minSpeechFrames) {
          this.speechStarted = true;
          this.speechStart = this.runStart;
          this.speechEnd = frameEnd;
          this.silentSamples = 0;
        }
      } else {
        this.run = 0;
      }
      return;
    }
    if (isSpeech) {
      this.speechEnd = frameEnd;
      this.silentSamples = 0;
    } else {
      this.silentSamples += this.frameSize;
      if (this.silentSamples >= this.pauseSeconds * this.sampleRate) this.ended = true;
    }
  }

  /** The stretch to transcribe: the speech with a little room around it, or null without speech. */
  speechRange(total = this.length, lead = 0.35, trail = 0.45): [number, number] | null {
    if (!this.speechStarted) return null;
    const start = Math.max(0, this.speechStart - Math.round(lead * this.sampleRate));
    const end = Math.min(total, this.speechEnd + Math.round(trail * this.sampleRate));
    return end > start ? [start, end] : null;
  }
}

// MARK: Transcripts

const ANNOTATION = /\[[^\]]*\]|\((?:[^)]*\b(?:music|silence|applause|laugh\w*|inaudible|noise|static|cough\w*|sigh\w*|breath\w*|wind|beep\w*|click\w*|blank|indistinct|background)\b[^)]*)\)|\*[^*]*\b(?:music|silence|laugh\w*|cough\w*|sigh\w*|noise)\b[^*]*\*|[♪♫]+/gi;

/** What Whisper says about noise or silence; nobody dictates just these. */
const HALLUCINATIONS = new Set(["you", "thanks for watching", "thank you for watching", "subtitles by the amara org community"]);

/** Removes the recognizer's sound annotations ("[BLANK_AUDIO]", "(music)") and tidies spacing. */
export function cleanTranscript(text: string): string {
  const cleaned = text.replace(ANNOTATION, " ").replace(/\s+/g, " ").trim();
  if (!/[\p{L}\p{N}]/u.test(cleaned)) return "";
  const words = cleaned.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").replace(/\s+/g, " ").trim();
  return HALLUCINATIONS.has(words) ? "" : cleaned;
}

/** Joins captured chunks into one buffer. */
export function concatSamples(chunks: readonly Float32Array[], start = 0, end?: number): Float32Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const to = Math.min(end ?? total, total);
  const from = Math.max(0, Math.min(start, to));
  const out = new Float32Array(to - from);
  let position = 0;
  for (const chunk of chunks) {
    const chunkStart = position;
    const chunkEnd = position + chunk.length;
    position = chunkEnd;
    if (chunkEnd <= from || chunkStart >= to) continue;
    const a = Math.max(from, chunkStart) - chunkStart;
    const b = Math.min(to, chunkEnd) - chunkStart;
    out.set(chunk.subarray(a, b), Math.max(from, chunkStart) - from);
  }
  return out;
}

/** Peak-normalizes quiet speech for the recognizer (never boosts noise more than 8×). */
export function normalize(samples: Float32Array, target = 0.7): Float32Array {
  let peak = 0;
  for (let i = 0; i < samples.length; i++) peak = Math.max(peak, Math.abs(samples[i]));
  if (peak <= 0) return samples;
  const gain = Math.min(8, target / peak);
  if (gain <= 1) return samples;
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) out[i] = samples[i] * gain;
  return out;
}
