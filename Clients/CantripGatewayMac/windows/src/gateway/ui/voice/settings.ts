// Voice settings, stored under the Mac app's @AppStorage names. Shared by every window of the
// app (same origin and storage partition); a change in one window reaches the others.
import { effect, signal, type Signal } from "@preact/signals";

export const PAUSE_KEY = "hermes.voicePause";
export const VOICE_KEY = "hermes.voiceId";
export const ENGINE_KEY = "hermes.sttEngine";

export const PAUSE_MIN = 1.5;
export const PAUSE_MAX = 5.0;
export const PAUSE_STEP = 0.5;
export const PAUSE_DEFAULT = 2.5;

/** On-device speech recognition engines (the Mac's SpeechInputEngine). */
export type EngineID = "whisper" | "whisper-tiny";

export interface EngineInfo {
  id: EngineID;
  /** Segmented picker title. */
  title: string;
  /** Hugging Face repository with the ONNX export. */
  model: string;
  /** One-time download, for the confirmation and Settings. */
  size: string;
}

export const ENGINES: readonly EngineInfo[] = [
  { id: "whisper", title: "Whisper Base", model: "onnx-community/whisper-base.en", size: "75 MB" },
  { id: "whisper-tiny", title: "Whisper Tiny", model: "onnx-community/whisper-tiny.en", size: "42 MB" },
];

export const DEFAULT_ENGINE: EngineID = "whisper";

export function engineInfo(id: EngineID): EngineInfo {
  return ENGINES.find((engine) => engine.id === id) ?? ENGINES[0];
}

export function clampPause(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return PAUSE_DEFAULT;
  const stepped = Math.round(value / PAUSE_STEP) * PAUSE_STEP;
  return Math.min(PAUSE_MAX, Math.max(PAUSE_MIN, stepped));
}

export function parseEngine(raw: string | null): EngineID {
  return ENGINES.some((engine) => engine.id === raw) ? (raw as EngineID) : DEFAULT_ENGINE;
}

function read(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}

function stored<T>(key: string, parse: (raw: string | null) => T, format: (value: T) => string): Signal<T> {
  const state = signal(parse(read(key)));
  effect(() => {
    const value = format(state.value);
    try {
      if (read(key) !== value) localStorage.setItem(key, value);
    } catch { /* storage unavailable */ }
  });
  addEventListener("storage", (event) => {
    if (event.key === key) state.value = parse(event.newValue);
  });
  return state;
}

/** Seconds of silence after speech before the utterance is sent (Settings → "Pause before sending"). */
export const voicePause = stored(PAUSE_KEY, (raw) => clampPause(raw === null ? PAUSE_DEFAULT : Number(raw)), String);
/** The reply voice's `voiceURI`; "" picks the best installed English voice. */
export const voiceID = stored(VOICE_KEY, (raw) => raw ?? "", (value) => value);
export const sttEngine = stored(ENGINE_KEY, parseEngine, (value) => value);
