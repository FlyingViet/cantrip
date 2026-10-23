// The on-device speech recognizer (a module Web Worker, bundled to voice-worker.js): Whisper through
// transformers.js and ONNX Runtime Web, on WebGPU when the PC has it, else WebAssembly. The model is
// downloaded once from Hugging Face and kept in the Cache API; audio never leaves this PC.
import { env, pipeline, type AutomaticSpeechRecognitionPipeline } from "@huggingface/transformers";

export type WorkerRequest =
  | { type: "load"; model: string; device?: "webgpu" | "wasm" }
  | { type: "transcribe"; id: number; audio: Float32Array };

export type WorkerResponse =
  | { type: "progress"; progress: number; phase: string }
  | { type: "ready"; device: "webgpu" | "wasm"; ms: number }
  | { type: "result"; id: number; text: string; ms: number }
  | { type: "error"; id?: number; message: string };

interface WorkerScope {
  postMessage(message: WorkerResponse): void;
  addEventListener(type: "message", listener: (event: MessageEvent<WorkerRequest>) => void): void;
  location: { href: string };
}

const scope = self as unknown as WorkerScope;
const ORT_DIRECTORY = new URL("ort/", scope.location.href);
const SAMPLE_RATE = 16000;

env.allowLocalModels = false;
env.allowRemoteModels = true;
env.useBrowserCache = true;
// The runtime ships with the app (dist/gateway/ort), never from a CDN. Its binary is handed over
// directly, so loading doesn't depend on the server's content types; the loader script is bundled
// here and only fetched separately for worker threads (cross-origin isolated pages only).
env.useWasmCache = false;
const onnx = env.backends.onnx;
const threads = (globalThis as { crossOriginIsolated?: boolean }).crossOriginIsolated
  ? Math.min(4, Math.max(1, (navigator.hardwareConcurrency || 2) - 1)) : 1;
const WASM_URL = new URL("ort-wasm-simd-threaded.asyncify.wasm", ORT_DIRECTORY).href;
if (onnx.wasm) {
  onnx.wasm.wasmPaths = threads > 1
    ? { wasm: WASM_URL, mjs: new URL("ort-wasm-simd-threaded.asyncify.js", ORT_DIRECTORY).href }
    : { wasm: WASM_URL };
  onnx.wasm.numThreads = threads;
  onnx.wasm.proxy = false;
}

let asr: AutomaticSpeechRecognitionPipeline | null = null;
let device: "webgpu" | "wasm" = "wasm";
let loadedModel = "";
let queue: Promise<unknown> = Promise.resolve();

function post(message: WorkerResponse): void {
  scope.postMessage(message);
}

async function loadRuntime(): Promise<void> {
  if (!onnx.wasm || onnx.wasm.wasmBinary) return;
  const response = await fetch(WASM_URL);
  if (!response.ok) throw new Error(`The speech runtime is missing (${response.status}).`);
  onnx.wasm.wasmBinary = await response.arrayBuffer();
}

async function hasWebGPU(): Promise<boolean> {
  try {
    const gpu = (navigator as { gpu?: { requestAdapter(): Promise<unknown | null> } }).gpu;
    return Boolean(gpu && (await gpu.requestAdapter()));
  } catch {
    return false;
  }
}

/**
 * The same files on every PC, so the model is downloaded once (Whisper Base: a 4-bit encoder and
 * 8-bit decoder, ~75 MB). The encoder, the heavy part, runs on the GPU when there is one (about
 * 0.6 s per pass, 2.3 s on the CPU); the decoder's small steps are fastest on the CPU.
 */
const DTYPE = { encoder_model: "q4", decoder_model_merged: "q8" } as const;

/** transformers.js's Cache API store. */
const CACHE_NAME = "transformers-cache";

async function cached(model: string): Promise<boolean> {
  try {
    const cache = await caches.open(CACHE_NAME);
    const marker = `/${model}/`;
    const urls = (await cache.keys()).map((request) => request.url).filter((url) => url.includes(marker));
    return urls.some((url) => url.includes("encoder_model_q4.onnx")) && urls.some((url) => url.includes("decoder_model_merged_quantized.onnx"));
  } catch {
    return false;
  }
}

async function create(model: string, target: "webgpu" | "wasm", phase: string): Promise<AutomaticSpeechRecognitionPipeline> {
  return pipeline("automatic-speech-recognition", model, {
    device: target === "webgpu" ? { encoder_model: "webgpu", decoder_model_merged: "wasm" } : "wasm",
    dtype: DTYPE,
    progress_callback: (info) => {
      if (info.status === "progress_total") {
        post({ type: "progress", progress: Math.min(1, Math.max(0, info.progress / 100)), phase });
      }
    },
  });
}

async function load(model: string, requested?: "webgpu" | "wasm"): Promise<void> {
  const started = performance.now();
  const phase = (await cached(model)) ? "Loading speech model" : "Downloading speech model";
  post({ type: "progress", progress: 0, phase });
  await loadRuntime();
  const preferred = requested ?? ((await hasWebGPU()) ? "webgpu" : "wasm");
  try {
    asr = await create(model, preferred, phase);
    device = preferred;
  } catch (error) {
    if (preferred !== "webgpu") throw error;
    asr = await create(model, "wasm", "Loading speech model");
    device = "wasm";
  }
  loadedModel = model;
  post({ type: "progress", progress: 1, phase: "Starting Whisper" });
  // Compiles the kernels now, so the first real request isn't the slow one.
  await run(new Float32Array(SAMPLE_RATE));
  post({ type: "ready", device, ms: Math.round(performance.now() - started) });
}

async function run(audio: Float32Array): Promise<string> {
  if (!asr) throw new Error("The speech model isn't loaded.");
  const long = audio.length > 30 * SAMPLE_RATE;
  const output = await asr(audio, long ? { chunk_length_s: 30, stride_length_s: 5 } : {});
  const results = Array.isArray(output) ? output : [output];
  return results.map((result) => (result as { text?: string }).text ?? "").join(" ").trim();
}

function message(error: unknown): string {
  if (error instanceof Error) return error.message || error.name;
  return String(error);
}

scope.addEventListener("message", (event) => {
  const request = event.data;
  if (request.type === "load") {
    queue = queue.then(() => load(request.model, request.device)).catch((error) => post({ type: "error", message: message(error) }));
  } else if (request.type === "transcribe") {
    queue = queue.then(async () => {
      const started = performance.now();
      try {
        let text: string;
        try {
          text = await run(request.audio);
        } catch (error) {
          // A lost GPU (driver reset, sleep) falls back to the CPU instead of failing every request.
          if (device !== "webgpu" || !loadedModel) throw error;
          asr = await create(loadedModel, "wasm", "Loading speech model");
          device = "wasm";
          text = await run(request.audio);
        }
        post({ type: "result", id: request.id, text, ms: Math.round(performance.now() - started) });
      } catch (error) {
        post({ type: "error", id: request.id, message: message(error) });
      }
    });
  }
});
