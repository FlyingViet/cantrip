// Voice state shared with Pip's mood and the composer.
import { signal } from "@preact/signals";

export interface VoiceState {
  listening: boolean;
  speaking: boolean;
  /** Downloading or loading the speech model, or transcribing what was said. */
  preparing: boolean;
  /** Live transcript while listening. */
  partial: string;
  /** Preparation step ("Downloading speech model · 42%"), shown while `preparing`. */
  status: string | null;
  error: string | null;
  /** Voice Mode: listen again after each spoken reply. */
  handsFree: boolean;
  /** Model download/load progress (0…1) while preparing, when known. */
  progress: number | null;
}

export const voiceState = signal<VoiceState>({
  listening: false,
  speaking: false,
  preparing: false,
  partial: "",
  status: null,
  error: null,
  handsFree: false,
  progress: null,
});

/** Microphone level (0…1) while listening, for the live waveform; kept apart so it doesn't re-render readers of `voiceState`. */
export const micLevel = signal(0);
