// The speech model's lifecycle on the page (the Mac's ParakeetSpeechEngine): download once, load on
// first use, transcribe in the worker, release after a while unused. Works in any window of the app;
// a download finished in one window shows as downloaded in the others.
import { effect, signal } from "@preact/signals";
import { engineInfo, sttEngine, type EngineID } from "./settings";
import type { WorkerRequest, WorkerResponse } from "./worker";

export type ModelState =
  | { kind: "idle" }
  | { kind: "cached" }
  | { kind: "preparing"; progress: number; phase: string }
  | { kind: "ready"; device: "webgpu" | "wasm" }
  | { kind: "failed"; message: string };

/** transformers.js's Cache API store (its default `cacheKey`). */
const CACHE_NAME = "transformers-cache";
/** Mirrors the Mac's "hermes.parakeetPrepared": the model finished downloading and loaded once. */
const preparedKey = (engine: EngineID) => `hermes.sttPrepared.${engine}`;
/** Unused for this long, the model leaves memory (it stays downloaded). */
const IDLE_RELEASE_MS = 10 * 60_000;

function knownPrepared(engine: EngineID): boolean {
  try { return localStorage.getItem(preparedKey(engine)) === "1"; } catch { return false; }
}

function setPrepared(engine: EngineID, value: boolean): void {
  try {
    if (value) localStorage.setItem(preparedKey(engine), "1");
    else localStorage.removeItem(preparedKey(engine));
  } catch { /* storage unavailable */ }
}

export const modelState = signal<ModelState>(knownPrepared(sttEngine.peek()) ? { kind: "cached" } : { kind: "idle" });

let worker: Worker | null = null;
let workerEngine: EngineID | null = null;
let loading: Promise<void> | null = null;
let settle: { resolve: () => void; reject: (error: Error) => void } | null = null;
let nextID = 1;
const pending = new Map<number, { resolve: (text: string) => void; reject: (error: Error) => void }>();
let holds = 0;
let releaseTimer: ReturnType<typeof setTimeout> | null = null;
/** How long the last transcription took, to pace live partial results. */
export let lastTranscriptionMs = 0;

/** Downloaded (or loaded): using it needs no download. */
export function isPrepared(): boolean {
  const kind = modelState.value.kind;
  return kind === "cached" || kind === "ready" || knownPrepared(sttEngine.peek());
}

export function isReady(): boolean {
  return modelState.value.kind === "ready" && workerEngine === sttEngine.peek();
}

/** Troubleshooting override: localStorage "hermes.sttDevice" = "wasm" (or "webgpu"). */
function forcedDevice(): "webgpu" | "wasm" | undefined {
  try {
    const value = localStorage.getItem("hermes.sttDevice");
    return value === "webgpu" || value === "wasm" ? value : undefined;
  } catch { return undefined; }
}

function idleState(engine: EngineID): ModelState {
  return knownPrepared(engine) ? { kind: "cached" } : { kind: "idle" };
}

function friendly(message: string): string {
  if (/fetch|network|Failed to load|ERR_|Unable to get model file|offline/i.test(message)) {
    return `Couldn't download the speech model. Check your internet connection and try again. (${message})`;
  }
  return message;
}

function onMessage(event: MessageEvent<WorkerResponse>): void {
  const message = event.data;
  switch (message.type) {
    case "progress":
      if (loading) modelState.value = { kind: "preparing", progress: message.progress, phase: message.phase };
      break;
    case "ready": {
      if (workerEngine) setPrepared(workerEngine, true);
      modelState.value = { kind: "ready", device: message.device };
      const done = settle;
      settle = null;
      loading = null;
      done?.resolve();
      scheduleRelease();
      break;
    }
    case "result": {
      lastTranscriptionMs = message.ms;
      const request = pending.get(message.id);
      pending.delete(message.id);
      request?.resolve(message.text);
      scheduleRelease();
      break;
    }
    case "error":
      if (message.id !== undefined) {
        const request = pending.get(message.id);
        pending.delete(message.id);
        request?.reject(new Error(message.message));
      } else {
        fail(friendly(message.message));
      }
      break;
  }
}

function fail(message: string): void {
  const done = settle;
  settle = null;
  loading = null;
  terminate();
  modelState.value = { kind: "failed", message };
  done?.reject(new Error(message));
}

function terminate(): void {
  worker?.terminate();
  worker = null;
  workerEngine = null;
  for (const request of pending.values()) request.reject(new Error("Speech recognition stopped."));
  pending.clear();
}

/** Downloads (first time) and loads the selected engine's model. */
export function prepareIfNeeded(): Promise<void> {
  const engine = sttEngine.peek();
  if (worker && workerEngine === engine && modelState.value.kind === "ready") return Promise.resolve();
  if (loading && workerEngine === engine) return loading;
  if (worker) {
    settle?.reject(new Error("Speech recognition changed engines."));
    settle = null;
    loading = null;
    terminate();
  }
  // The Mac's initialPreparationPhase(isKnownCached:).
  modelState.value = { kind: "preparing", progress: 0, phase: knownPrepared(engine) ? "Loading speech model" : "Checking speech model" };
  let created: Worker;
  try {
    created = new Worker(new URL("voice-worker.js", location.href), { type: "module", name: "Speech recognition" });
  } catch (error) {
    modelState.value = { kind: "failed", message: (error as Error).message };
    return Promise.reject(error);
  }
  worker = created;
  workerEngine = engine;
  created.addEventListener("message", onMessage);
  created.addEventListener("error", (event) => {
    if (worker === created) fail(event.message || "Speech recognition stopped unexpectedly.");
  });
  loading = new Promise<void>((resolve, reject) => { settle = { resolve, reject }; });
  // A failed preparation is reported through modelState; callers that don't wait on it shouldn't throw.
  loading.catch(() => undefined);
  const request: WorkerRequest = { type: "load", model: engineInfo(engine).model, device: forcedDevice() };
  created.postMessage(request);
  return loading;
}

/** Text for 16 kHz mono audio. */
export async function transcribe(audio: Float32Array): Promise<string> {
  await prepareIfNeeded();
  const target = worker;
  if (!target) throw new Error("Speech recognition isn't available.");
  const id = nextID++;
  return new Promise<string>((resolve, reject) => {
    pending.set(id, { resolve, reject });
    const request: WorkerRequest = { type: "transcribe", id, audio };
    target.postMessage(request, [audio.buffer]);
  });
}

/** While held (listening), the model stays in memory. */
export function hold(active: boolean): void {
  holds = Math.max(0, holds + (active ? 1 : -1));
  scheduleRelease();
}

function scheduleRelease(): void {
  if (releaseTimer) clearTimeout(releaseTimer);
  releaseTimer = null;
  if (!worker || holds > 0) return;
  releaseTimer = setTimeout(() => {
    if (holds === 0 && !loading && pending.size === 0) release();
  }, IDLE_RELEASE_MS);
}

/** Frees the model's memory; it stays downloaded. */
export function release(): void {
  if (loading) {
    settle?.reject(new Error("Speech recognition stopped."));
    settle = null;
    loading = null;
  }
  const engine = workerEngine ?? sttEngine.peek();
  terminate();
  modelState.value = idleState(engine);
}

/** Removes the downloaded model files for an engine. */
export async function deleteModel(engine: EngineID = sttEngine.peek()): Promise<void> {
  if (workerEngine === engine || loading) release();
  setPrepared(engine, false);
  modelState.value = { kind: "idle" };
  if (typeof caches === "undefined") return;
  const cache = await caches.open(CACHE_NAME);
  const marker = `/${engineInfo(engine).model}/`;
  for (const request of await cache.keys()) {
    if (request.url.includes(marker)) await cache.delete(request);
  }
}

/** Checks the Cache API for the engine's model, correcting "downloaded" if the files were cleared. */
export async function verifyCache(engine: EngineID = sttEngine.peek()): Promise<void> {
  if (typeof caches === "undefined" || loading || (worker && workerEngine === engine)) return;
  try {
    const cache = await caches.open(CACHE_NAME);
    const marker = `/${engineInfo(engine).model}/`;
    const files = (await cache.keys()).filter((request) => request.url.includes(marker));
    const present = files.some((request) => request.url.includes("encoder_model_q4.onnx"))
      && files.some((request) => request.url.includes("decoder_model_merged_quantized.onnx"));
    if (loading || (worker && workerEngine === engine) || sttEngine.peek() !== engine) return;
    if (!present && knownPrepared(engine)) setPrepared(engine, false);
    modelState.value = present && knownPrepared(engine) ? { kind: "cached" } : { kind: "idle" };
  } catch { /* the stored flag stands */ }
}

// Switching engines frees the other model and shows the new one's state.
let shownEngine = sttEngine.peek();
effect(() => {
  const engine = sttEngine.value;
  if (engine === shownEngine) return;
  shownEngine = engine;
  if (worker && workerEngine !== engine) release();
  else if (!worker) modelState.value = idleState(engine);
});

// Another window downloaded or deleted the model.
addEventListener("storage", (event) => {
  if (event.key !== preparedKey(sttEngine.peek()) || worker || loading) return;
  modelState.value = idleState(sttEngine.peek());
});
