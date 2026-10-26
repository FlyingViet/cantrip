// Calls to the paired Mac's API. The main process adds the pairing token and picks the route
// (encrypted direct, then HTTPS); this page only proves it is the Gateway window (bridge.key).
import { bridge } from "../bridge";
import type { ImageDataResponse, RemoteThread, ThreadResponse } from "./types";

export class APIError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
  /** The Mac couldn't be reached (the main process answers 502/503 for route failures). */
  get isUnreachable(): boolean {
    return this.status === 0 || this.status === 502 || this.status === 503 || this.status === 504;
  }
}

export interface RequestOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE" | "PUT";
  body?: unknown;
  /** Raw body (chunk uploads); sent as application/octet-stream. */
  raw?: Uint8Array;
  timeoutMs?: number;
  /** Adds recentExchanges=3 (session reads and session-returning writes). */
  recent?: boolean;
  signal?: AbortSignal;
}

let activeWrites = 0;
const writeListeners = new Set<(count: number) => void>();
export function onWritesChanged(listener: (count: number) => void): () => void {
  writeListeners.add(listener);
  return () => writeListeners.delete(listener);
}

/** Content reads get longer deadlines, like the Mac client (CantripRemote.swift:1332-1341). */
function defaultTimeout(path: string, method: string, bytes: number): number {
  if (method !== "GET") return bytes > 256 * 1024 ? 60000 : 30000;
  const bare = path.split("?")[0];
  if (/^\/api\/v1\/(maintenance|home|memory)/.test(bare)) return 25000;
  if (/^\/api\/v1\/sessions\/[^/]+(\/messages\/[^/]+|\/threads\/[^/]+|\/apps\/[^/]+|\/attachments\/.+|\/previews\/.+)?$/.test(bare)) return 25000;
  return 15000;
}

export async function api<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const method = options.method ?? "GET";
  let url = path + (path.includes("?") ? "&" : "?") + "history=recent";
  if (options.recent) url += "&recentExchanges=3";
  const headers: Record<string, string> = { accept: "application/json", "x-cantrip-gateway": bridge.key };
  let body: BodyInit | undefined;
  if (options.raw) {
    headers["content-type"] = "application/octet-stream";
    body = options.raw as unknown as BodyInit;
  } else if (options.body !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(options.body);
  }
  const controller = new AbortController();
  const bytes = options.raw?.byteLength ?? (typeof body === "string" ? body.length : 0);
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? defaultTimeout(path, method, bytes));
  options.signal?.addEventListener("abort", () => controller.abort(), { once: true });
  const write = method !== "GET";
  if (write) {
    activeWrites++;
    for (const listener of writeListeners) listener(activeWrites);
  }
  try {
    let response: Response;
    try {
      response = await fetch(url, { method, headers, body, signal: controller.signal });
    } catch (error) {
      if (controller.signal.aborted) {
        throw new APIError(write ? "The Mac didn't answer in time. Check before trying again; it may have gone through." : "The Mac didn't answer in time.", 0);
      }
      throw new APIError((error as Error).message || "Couldn't reach the Mac.", 0);
    }
    let data: unknown = null;
    const text = await response.text();
    if (text) {
      try { data = JSON.parse(text); } catch { data = null; }
    }
    if (!response.ok) {
      const message = (data as { error?: string } | null)?.error ?? `The Mac answered with HTTP ${response.status}.`;
      throw new APIError(message, response.status);
    }
    return data as T;
  } finally {
    clearTimeout(timer);
    if (write) {
      activeWrites--;
      for (const listener of writeListeners) listener(activeWrites);
    }
  }
}

export function pathComponent(value: string): string {
  return encodeURIComponent(value);
}

// MARK: Threads (Cantrip Home thread tags)

export function threadPath(sessionID: string, threadID: string, before?: string): string {
  const path = `/api/v1/sessions/${pathComponent(sessionID)}/threads/${pathComponent(threadID)}`;
  return before ? `${path}?before=${encodeURIComponent(before)}` : path;
}

/** A thread: its prompt and the messages in it (only those before `before` when given); works while its prompt is in history not loaded yet. */
export async function thread(sessionID: string, threadID: string, before?: string): Promise<RemoteThread> {
  const data = await api<ThreadResponse>(threadPath(sessionID, threadID, before));
  const value = data?.thread;
  if (!value?.prompt || typeof value.prompt.text !== "string") throw new APIError("The Mac sent an incomplete thread.", 200);
  return { ...value, messages: Array.isArray(value.messages) ? value.messages : [], hasEarlier: value.hasEarlier === true };
}

// MARK: Images (JSON with base64 JPEG), cached as data URLs so re-renders never refetch.

const imageCache = new Map<string, string>();
const imageLoads = new Map<string, Promise<string>>();

export function imagePath(sessionID: string, imageID: string, full: boolean): string {
  const prefix = imageID.startsWith("previews/") ? "" : "attachments/";
  return `/api/v1/sessions/${pathComponent(sessionID)}/${prefix}${imageID.split("/").map(pathComponent).join("/")}${full ? "" : "/thumbnail"}`;
}

export function cachedImage(key: string): string | undefined {
  return imageCache.get(key);
}

export function loadImage(sessionID: string, imageID: string, full = false): Promise<string> {
  const key = `${sessionID}:${imageID}:${full ? "full" : "thumb"}`;
  const cached = imageCache.get(key);
  if (cached) return Promise.resolve(cached);
  const pending = imageLoads.get(key);
  if (pending) return pending;
  const load = api<ImageDataResponse>(imagePath(sessionID, imageID, full))
    .then((data) => {
      const url = `data:${(data as { mimeType?: string }).mimeType ?? "image/jpeg"};base64,${data.data}`;
      imageCache.delete(key);
      imageCache.set(key, url);
      while (imageCache.size > 60) imageCache.delete(imageCache.keys().next().value!);
      return url;
    })
    .finally(() => imageLoads.delete(key));
  imageLoads.set(key, load);
  return load;
}

export function clearImageCache(): void {
  imageCache.clear();
}

export function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let result = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    result += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(result);
}
