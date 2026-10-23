import { describe, expect, it } from "vitest";
import { cleanTranscript, concatSamples, EndOfUtteranceDetector, normalize, resample, Resampler, rms } from "../src/gateway/ui/voice/audio";

const RATE = 16000;

/** Deterministic white noise. */
function noise(seconds: number, amplitude: number, seed = 1): Float32Array {
  let state = seed;
  const out = new Float32Array(Math.round(seconds * RATE));
  for (let i = 0; i < out.length; i++) {
    state = (state * 1664525 + 1013904223) >>> 0;
    out[i] = ((state / 0xffffffff) * 2 - 1) * amplitude;
  }
  return out;
}

/** Voiced harmonics with a syllable-rate envelope, over light noise. */
function speech(seconds: number, amplitude: number): Float32Array {
  const out = noise(seconds, amplitude * 0.05, 7);
  for (let i = 0; i < out.length; i++) {
    const t = i / RATE;
    const envelope = 0.55 + 0.45 * Math.sin(2 * Math.PI * 4 * t);
    const voiced = Math.sin(2 * Math.PI * 140 * t) + 0.6 * Math.sin(2 * Math.PI * 280 * t) + 0.3 * Math.sin(2 * Math.PI * 560 * t);
    out[i] += (amplitude * envelope * voiced) / 1.9;
  }
  return out;
}

function join(...parts: Float32Array[]): Float32Array {
  return concatSamples(parts);
}

/** Feeds audio in 20 ms microphone-sized chunks; returns the time (s) the utterance ended, or null. */
function feed(detector: EndOfUtteranceDetector, audio: Float32Array, chunk = 320): number | null {
  for (let offset = 0; offset < audio.length; offset += chunk) {
    if (detector.push(audio.subarray(offset, offset + chunk))) return detector.length / RATE;
  }
  return null;
}

describe("EndOfUtteranceDetector", () => {
  it("ends the utterance after the configured pause following speech", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 1.5 });
    const ended = feed(detector, join(noise(1, 0.002), speech(1.5, 0.12), noise(3, 0.002, 3)));
    expect(detector.speechStarted).toBe(true);
    expect(detector.speechStart / RATE).toBeGreaterThan(0.9);
    expect(detector.speechStart / RATE).toBeLessThan(1.1);
    expect(detector.speechEnd / RATE).toBeGreaterThan(2.35);
    expect(detector.speechEnd / RATE).toBeLessThan(2.6);
    expect(ended).not.toBeNull();
    expect(detector.silenceSeconds).toBeGreaterThanOrEqual(1.5);
    expect(ended!).toBeGreaterThan(3.9);
    expect(ended!).toBeLessThan(4.15);
  });

  it("waits through pauses shorter than the setting", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 2.5 });
    const audio = join(noise(0.5, 0.002), speech(1, 0.1), noise(2, 0.002, 5), speech(1, 0.1), noise(1, 0.002, 9));
    expect(feed(detector, audio)).toBeNull();
    expect(detector.speechEnd / RATE).toBeGreaterThan(4.4);
    expect(feed(detector, noise(2, 0.002, 11))).not.toBeNull();
  });

  it("applies a changed pause at once", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 5 });
    expect(feed(detector, join(noise(0.5, 0.002), speech(1, 0.1), noise(2, 0.002, 2)))).toBeNull();
    expect(detector.silenceSeconds).toBeGreaterThan(1.8);
    detector.pauseSeconds = 1.5;
    expect(feed(detector, noise(0.1, 0.002, 4))).not.toBeNull();
  });

  it("ignores clicks and silence", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 1.5 });
    const audio = noise(6, 0.002);
    for (const at of [1, 2.5, 4]) audio.fill(0.5, at * RATE, at * RATE + 160);
    expect(feed(detector, audio)).toBeNull();
    expect(detector.speechStarted).toBe(false);
    expect(detector.speechRange()).toBeNull();
  });

  it("learns a noisy room and still hears speech over it", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 1.5 });
    expect(feed(detector, noise(3, 0.02))).toBeNull();
    expect(detector.speechStarted).toBe(false);
    expect(detector.noiseFloor).toBeGreaterThan(0.008);
    const ended = feed(detector, join(speech(1.2, 0.25), noise(2, 0.02, 13)));
    expect(detector.speechStarted).toBe(true);
    expect(ended).not.toBeNull();
  });

  it("reports the speech with some room around it and a level for the waveform", () => {
    const detector = new EndOfUtteranceDetector({ pauseSeconds: 1.5 });
    feed(detector, join(noise(1, 0.002), speech(1, 0.12)));
    expect(detector.level).toBeGreaterThan(0.5);
    const [start, end] = detector.speechRange()!;
    expect(start / RATE).toBeCloseTo(detector.speechStart / RATE - 0.35, 2);
    expect(end).toBe(Math.min(detector.length, detector.speechEnd + 0.45 * RATE));
    feed(detector, noise(1, 0.002, 2));
    expect(detector.level).toBeLessThan(0.3);
  });
});

describe("Resampler", () => {
  const sine = (rate: number, seconds: number, hz: number) =>
    Float32Array.from({ length: Math.round(rate * seconds) }, (_, i) => Math.sin((2 * Math.PI * hz * i) / rate));

  it("converts 48 kHz to 16 kHz without shifting or distorting speech frequencies", () => {
    const out = resample(sine(48000, 0.5, 1000), 48000, 16000);
    const ideal = sine(16000, 0.5, 1000);
    expect(out.length).toBe(8000);
    let worst = 0;
    for (let i = 200; i < out.length - 200; i++) worst = Math.max(worst, Math.abs(out[i] - ideal[i]));
    expect(worst).toBeLessThan(0.02);
  });

  it("filters out what 16 kHz can't hold instead of aliasing it", () => {
    const out = resample(sine(48000, 0.5, 12000), 48000, 16000);
    expect(rms(out, 200, out.length - 200)).toBeLessThan(0.02);
    const near = resample(sine(48000, 0.5, 9000), 48000, 16000);
    expect(rms(near, 200, near.length - 200)).toBeLessThan(0.1);
  });

  it("handles 44.1 kHz and upsampling", () => {
    const out = resample(sine(44100, 0.5, 440), 44100, 16000);
    const ideal = sine(16000, 0.5, 440);
    expect(out.length).toBe(8000);
    let worst = 0;
    for (let i = 200; i < out.length - 200; i++) worst = Math.max(worst, Math.abs(out[i] - ideal[i]));
    expect(worst).toBeLessThan(0.02);
    const up = resample(sine(8000, 0.25, 200), 8000, 16000);
    expect(up.length).toBe(4000);
    const upIdeal = sine(16000, 0.25, 200);
    for (let i = 10; i < up.length - 10; i++) expect(Math.abs(up[i] - upIdeal[i])).toBeLessThan(0.01);
  });

  it("gives the same samples whatever the chunk sizes", () => {
    const input = noise(0.4, 0.5).map((value, i) => value + Math.sin(i / 7));
    const whole = new Resampler(48000, 16000).process(input);
    for (const sizes of [[128], [1, 1000, 3], [4096]]) {
      const resampler = new Resampler(48000, 16000);
      const parts: Float32Array[] = [];
      let offset = 0;
      let index = 0;
      while (offset < input.length) {
        const size = sizes[index++ % sizes.length];
        parts.push(resampler.process(input.subarray(offset, offset + size)));
        offset += size;
      }
      const joined = concatSamples(parts);
      expect(joined.length).toBe(whole.length);
      for (let i = 0; i < whole.length; i++) expect(Math.abs(joined[i] - whole[i])).toBeLessThan(1e-5);
    }
  });

  it("passes 16 kHz through unchanged", () => {
    const input = noise(0.1, 0.3);
    expect(Array.from(resample(input, 16000, 16000))).toEqual(Array.from(input));
    expect(Array.from(new Resampler(16000, 16000).process(input))).toEqual(Array.from(input));
  });
});

describe("transcripts and buffers", () => {
  it("drops sound annotations but keeps real parentheses", () => {
    expect(cleanTranscript(" [BLANK_AUDIO]")).toBe("");
    expect(cleanTranscript(" (music) Hello there. ♪")).toBe("Hello there.");
    expect(cleanTranscript("Thanks (laughs) a lot")).toBe("Thanks a lot");
    expect(cleanTranscript("Open the file (the big one)")).toBe("Open the file (the big one)");
    expect(cleanTranscript("*sighs* ...")).toBe("");
    expect(cleanTranscript(" you")).toBe("");
    expect(cleanTranscript("Thanks for watching!")).toBe("");
    expect(cleanTranscript("Thank you, you too.")).toBe("Thank you, you too.");
  });

  it("joins a range across chunks", () => {
    const chunks = [Float32Array.of(1, 2, 3), Float32Array.of(4, 5), Float32Array.of(6, 7, 8)];
    expect(Array.from(concatSamples(chunks))).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(Array.from(concatSamples(chunks, 2, 7))).toEqual([3, 4, 5, 6, 7]);
    expect(Array.from(concatSamples(chunks, 6, 99))).toEqual([7, 8]);
  });

  it("boosts quiet speech up to 8×", () => {
    expect(Array.from(normalize(Float32Array.of(0.05, -0.1)))).toEqual([0.35000000000000003, -0.7].map((v) => Math.fround(v)));
    expect(Array.from(normalize(Float32Array.of(0.001)))).toEqual([Math.fround(0.008)]);
    const loud = Float32Array.of(0.9);
    expect(normalize(loud)).toBe(loud);
  });
});
