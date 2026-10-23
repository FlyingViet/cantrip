// The voice loop (the Mac's VoiceController): listening with on-device speech recognition and
// end-of-utterance detection, and replies spoken with the system's voices. Microphone audio never
// leaves this PC. No dependency on the Mac connection, so Settings can use it too.
import { effect, signal } from "@preact/signals";
import { cleanTranscript, concatSamples, EndOfUtteranceDetector, normalize, Resampler, SPEECH_RATE } from "./audio";
import * as recognizer from "./recognizer";
import { voiceID, voicePause } from "./settings";
import { pickVoice } from "./speech";
import { micLevel, voiceState, type VoiceState } from "./state";

function patch(change: Partial<VoiceState>): void {
  const current = voiceState.peek();
  if ((Object.keys(change) as (keyof VoiceState)[]).every((key) => current[key] === change[key])) return;
  voiceState.value = { ...current, ...change };
}

const IS_MAC = /Macintosh|Mac OS X/.test(navigator.userAgent);
/** Longest single utterance (the Mac's maximumListenTimer). */
const MAX_LISTEN_MS = 120_000;
/** Room kept around the detected speech for the recognizer. */
const LEAD_SECONDS = 0.35;
const TRAIL_SECONDS = 0.45;
/** Live partial results at most this often (slower PCs: 1.5× the last pass). */
const PARTIAL_INTERVAL_MS = 900;

// MARK: Listening

interface PartialPass {
  busy: boolean;
  startedAt: number;
  /** Audio range [start, end) the text covers. */
  start: number;
  end: number;
  text: string | null;
  promise: Promise<void> | null;
}

interface Capture {
  stream: MediaStream;
  context: AudioContext;
  nodes: AudioNode[];
  worklet: AudioWorkletNode | null;
  resampler: Resampler | null;
  detector: EndOfUtteranceDetector;
  chunks: Float32Array[];
  partial: PartialPass;
}

let capture: Capture | null = null;
let generation = 0;
/** The generation whose start (model load, microphone) is under way. */
let startingGeneration = -1;
/** Preparing means loading the model (not transcribing) for this generation. */
let loadingGeneration = -1;
let maxTimer: ReturnType<typeof setTimeout> | null = null;
let transcriptHandler: ((text: string) => void) | null = null;

/** Who gets the finished utterance: the composer (dictation) or Voice Mode (send). */
export function setTranscriptHandler(handler: ((text: string) => void) | null): void {
  transcriptHandler = handler;
}

export function setHandsFree(value: boolean): void {
  patch({ handsFree: value });
}

export function toggleListening(): void {
  if (voiceState.peek().listening) stopListening(true);
  else void startListening();
}

export async function startListening(): Promise<void> {
  const state = voiceState.peek();
  if (state.listening || state.speaking || state.preparing || startingGeneration === generation) return;
  const current = ++generation;
  startingGeneration = current;
  patch({ error: null, status: null, progress: null });
  try {
    if (!recognizer.isReady()) {
      loadingGeneration = current;
      patch({ preparing: true, status: "Preparing Whisper…", progress: null });
      showModelProgress();
      await recognizer.prepareIfNeeded();
      if (current !== generation) return;
      patch({ status: "Starting Whisper…", progress: null });
    }
    const session = await openCapture();
    if (current !== generation) {
      closeCapture(session);
      return;
    }
    capture = session;
    recognizer.hold(true);
    loadingGeneration = -1;
    patch({ preparing: false, status: null, progress: null, listening: true, partial: "" });
    maxTimer = setTimeout(() => {
      if (current === generation) stopListening(true);
    }, MAX_LISTEN_MS);
  } catch (error) {
    if (current !== generation) return;
    loadingGeneration = -1;
    patch({ preparing: false, status: null, progress: null, listening: false, error: describeError(error) });
  } finally {
    if (startingGeneration === current) startingGeneration = -1;
  }
}

function showModelProgress(): void {
  if (loadingGeneration !== generation) return;
  const model = recognizer.modelState.peek();
  if (model.kind === "preparing") {
    patch({ status: `${model.phase} · ${Math.round(model.progress * 100)}%`, progress: model.progress });
  }
}

effect(() => {
  void recognizer.modelState.value;
  showModelProgress();
});

/** Ends listening; `finalize` transcribes what was said and hands it over. */
export function stopListening(finalize: boolean): void {
  if (maxTimer) clearTimeout(maxTimer);
  maxTimer = null;
  const current = ++generation;
  loadingGeneration = -1;
  const session = capture;
  capture = null;
  if (session) {
    closeCapture(session);
    recognizer.hold(false);
  }
  micLevel.value = 0;
  const captured = voiceState.peek().partial.trim();
  patch({ listening: false, preparing: false, status: null, progress: null });
  const range = session && finalize ? session.detector.speechRange(session.detector.length, LEAD_SECONDS, TRAIL_SECONDS) : null;
  if (!session || !range) {
    patch({ partial: "" });
    return;
  }
  patch({ preparing: true, status: "Transcribing…" });
  void finish(session, range, current, captured);
}

async function finish(session: Capture, [start, end]: [number, number], current: number, captured: string): Promise<void> {
  try {
    const partial = session.partial;
    if (partial.promise) await partial.promise;
    const covered = partial.text !== null && partial.start === start
      && partial.end >= Math.min(end, session.detector.speechEnd + 0.2 * SPEECH_RATE);
    const text = covered && partial.text !== null
      ? partial.text
      : cleanTranscript(await recognizer.transcribe(normalize(concatSamples(session.chunks, start, end))));
    if (current !== generation) return;
    patch({ partial: "", preparing: false, status: null });
    const transcript = text || captured;
    if (transcript) transcriptHandler?.(transcript);
    // Only noise was heard: Voice Mode keeps listening.
    else if (voiceState.peek().handsFree) void startListening();
  } catch (error) {
    if (current !== generation) return;
    patch({ partial: "", preparing: false, status: null, error: describeError(error) });
    if (captured) transcriptHandler?.(captured);
  }
}

async function openCapture(): Promise<Capture> {
  const media = navigator.mediaDevices;
  if (!media?.getUserMedia) throw new Error("No microphone is available to Cantrip Gateway.");
  const stream = await media.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  let context: AudioContext;
  try {
    context = new AudioContext({ sampleRate: SPEECH_RATE, latencyHint: "interactive" });
  } catch {
    context = new AudioContext({ latencyHint: "interactive" });
  }
  const session: Capture = {
    stream, context, nodes: [], worklet: null,
    resampler: context.sampleRate === SPEECH_RATE ? null : new Resampler(context.sampleRate, SPEECH_RATE),
    detector: new EndOfUtteranceDetector({ pauseSeconds: voicePause.peek() }),
    chunks: [],
    partial: { busy: false, startedAt: 0, start: -1, end: -1, text: null, promise: null },
  };
  const receive = (samples: Float32Array) => {
    if (capture === session) accept(session, samples);
  };
  try {
    const source = context.createMediaStreamSource(stream);
    session.nodes.push(source);
    try {
      await context.audioWorklet.addModule(new URL("voice-capture.js", location.href).href);
      const node = new AudioWorkletNode(context, "cantrip-voice-capture", {
        numberOfInputs: 1, numberOfOutputs: 0, channelCount: 1, channelCountMode: "explicit",
      });
      node.port.onmessage = (event: MessageEvent<Float32Array>) => receive(event.data);
      source.connect(node);
      session.worklet = node;
      session.nodes.push(node);
    } catch {
      // No AudioWorklet: the older ScriptProcessor does the same on the page's thread.
      const processor = context.createScriptProcessor(2048, 1, 1);
      processor.onaudioprocess = (event) => receive(event.inputBuffer.getChannelData(0).slice());
      source.connect(processor);
      processor.connect(context.destination);
      session.nodes.push(processor);
    }
    if (context.state !== "running") await context.resume();
  } catch (error) {
    closeCapture(session);
    throw error;
  }
  return session;
}

function closeCapture(session: Capture): void {
  session.worklet?.port.postMessage("stop");
  for (const node of session.nodes) {
    try { node.disconnect(); } catch { /* already disconnected */ }
  }
  for (const track of session.stream.getTracks()) track.stop();
  void session.context.close().catch(() => undefined);
}

function accept(session: Capture, samples: Float32Array): void {
  const pcm = session.resampler ? session.resampler.process(samples) : samples;
  if (!pcm.length) return;
  session.chunks.push(pcm);
  const detector = session.detector;
  // "Pause before sending" applies at once, like the Mac reading it live.
  detector.pauseSeconds = voicePause.peek();
  const ended = detector.push(pcm);
  micLevel.value = detector.level;
  if (ended) stopListening(true);
  else updatePartial(session);
}

/** Live transcript while talking; once the speaker pauses, it doubles as the final text. */
function updatePartial(session: Capture): void {
  const { detector, partial } = session;
  if (!detector.speechStarted || partial.busy) return;
  if (partial.text !== null && partial.end >= detector.speechEnd) return;
  const quiet = detector.silenceSeconds >= 0.5;
  const interval = Math.max(PARTIAL_INTERVAL_MS, recognizer.lastTranscriptionMs * 1.5);
  if (!quiet && performance.now() - partial.startedAt < interval) return;
  const range = detector.speechRange(detector.length, LEAD_SECONDS, 0);
  if (!range) return;
  const start = range[0];
  const end = detector.length;
  partial.busy = true;
  partial.startedAt = performance.now();
  partial.promise = recognizer.transcribe(normalize(concatSamples(session.chunks, start, end)))
    .then((text) => {
      partial.text = cleanTranscript(text);
      partial.start = start;
      partial.end = end;
      if (capture === session && partial.text) patch({ partial: partial.text });
    })
    .catch(() => undefined)
    .finally(() => {
      partial.busy = false;
      partial.promise = null;
    });
}

function describeError(error: unknown): string {
  const name = (error as { name?: string } | null)?.name;
  if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError") {
    return IS_MAC
      ? "Cantrip Gateway can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone, then try again."
      : "Cantrip Gateway can't use the microphone. Allow microphone access in Windows Settings → Privacy & security → Microphone, then try again.";
  }
  if (name === "NotFoundError" || name === "OverconstrainedError" || name === "DevicesNotFoundError") {
    return "No microphone was found. Connect one and try again.";
  }
  if (name === "NotReadableError" || name === "TrackStartError" || name === "AbortError") {
    return "The microphone is unavailable. Another app may be using it.";
  }
  return (error as Error | null)?.message || String(error);
}

// MARK: Speaking

/** The system's voices (speechSynthesis), refreshed when Windows reports a change. */
export const systemVoices = signal<SpeechSynthesisVoice[]>([]);
const synth: SpeechSynthesis | null = typeof speechSynthesis === "undefined" ? null : speechSynthesis;

function loadVoices(): void {
  if (synth) systemVoices.value = synth.getVoices();
}
loadVoices();
synth?.addEventListener("voiceschanged", loadVoices);

/** The chosen reply voice, else the best installed English voice. */
export function selectedVoice(id = voiceID.peek()): SpeechSynthesisVoice | null {
  const voices = systemVoices.peek().length ? systemVoices.peek() : synth?.getVoices() ?? [];
  return pickVoice(voices, id);
}

// Streamed replies are spoken a chunk at a time; hands-free listening resumes only once the whole
// reply is spoken (`pending` counts queued utterances, `replyDone` bridges gaps while streaming).
let pending = 0;
let replyDone = true;
let speechGeneration = 0;
let lastCancel = 0;
/** Utterances in flight (Chromium drops events of collected ones). */
const live = new Set<SpeechSynthesisUtterance>();

/** Begins a streamed spoken reply: chunks arrive with `enqueue`, and `finishReply` ends it. */
export function beginReply(): void {
  replyDone = false;
}

/** Speaks the next chunk of a reply, after any chunk still playing. */
export function enqueue(text: string, voice: SpeechSynthesisVoice | null = selectedVoice()): void {
  const clean = text.trim();
  if (!clean || !synth) return;
  if (pending === 0 && voiceState.peek().listening) stopListening(false);
  pending++;
  patch({ speaking: true });
  const utterance = new SpeechSynthesisUtterance(clean);
  if (voice) {
    utterance.voice = voice;
    utterance.lang = voice.lang;
  }
  const owner = speechGeneration;
  const done = () => {
    live.delete(utterance);
    if (owner !== speechGeneration) return;
    pending = Math.max(0, pending - 1);
    finishSpeechIfIdle();
  };
  utterance.onend = done;
  utterance.onerror = done;
  live.add(utterance);
  const speak = () => {
    if (owner !== speechGeneration) return;
    synth.resume();
    synth.speak(utterance);
  };
  // Speaking right after cancel() is sometimes dropped on Windows.
  if (performance.now() - lastCancel < 120) setTimeout(speak, 120);
  else speak();
}

/** Marks the streamed reply finished; Voice Mode listens again once it's all spoken. */
export function finishReply(): void {
  replyDone = true;
  finishSpeechIfIdle();
}

/** Speaks a complete text (through begin/enqueue/finish, like streamed replies). */
export function speak(text: string): void {
  beginReply();
  enqueue(text);
  finishReply();
}

function cancelSpeech(): boolean {
  const wasSpeaking = voiceState.peek().speaking || pending > 0;
  speechGeneration++;
  if (synth && (synth.speaking || synth.pending || live.size)) {
    synth.cancel();
    lastCancel = performance.now();
  }
  live.clear();
  pending = 0;
  replyDone = true;
  patch({ speaking: false });
  return wasSpeaking;
}

/** Stops all speech at once and clears the queue; Voice Mode then listens (like the Mac's didCancel). */
export function stopSpeaking(): void {
  if (cancelSpeech()) setTimeout(resumeIfHandsFree, 0);
}

/** Speaks a short sample with a voice (Settings → Reply voice). */
export function preview(voice: SpeechSynthesisVoice): void {
  if (voiceState.peek().listening) stopListening(false);
  cancelSpeech();
  beginReply();
  enqueue("Hey, this is how I'll sound.", voice);
  finishReply();
}

function finishSpeechIfIdle(): void {
  if (pending > 0 || !replyDone) return;
  patch({ speaking: false });
  resumeIfHandsFree();
}

function resumeIfHandsFree(): void {
  if (voiceState.peek().handsFree) void startListening();
}

/** Stops listening and speaking (pause, leaving Voice Mode, switching conversations). */
export function stopAll(): void {
  stopListening(false);
  cancelSpeech();
}

/** Clears a shown recognition error. */
export function clearError(): void {
  patch({ error: null });
}
