// Home artifact downloads (Save As…): the Mac's response body goes straight to a file on disk over
// the paired routes, so a long video or a folder zip never sits whole in memory.
import { createWriteStream } from "node:fs";
import type * as http from "node:http";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import {
  DROPPED_RESPONSE_HEADERS, FetchLike, HostRequest, LocalFileError, NOT_SENT, PSKOptions, requestOverPSK, responseHeaders,
  TransportError,
} from "./transport";

export interface DownloadResult {
  status: number;
  headers: Record<string, string>;
  /** A refusal's (JSON) body, at most 64 KB; empty after a successful download. */
  errorBody: Buffer;
  /** Bytes written to the destination (2xx only). */
  bytes: number;
}

const ERROR_BODY_LIMIT = 64 * 1024;

function expectedLength(headers: Record<string, string | string[] | undefined>): number | null {
  const value = Number(headers["content-length"]);
  return Number.isInteger(value) && value >= 0 ? value : null;
}

function encoded(headers: Record<string, string | string[] | undefined>): boolean {
  const value = String(headers["content-encoding"] ?? "identity").toLowerCase();
  return value !== "identity" && value !== "";
}

/**
 * Writes `source` to `destination` (owner-only) with backpressure, failing when it ends short of
 * `expected` bytes. A file that can't be opened or written (no permission, disk full) rejects with
 * a `LocalFileError`: it isn't the Mac's fault, so no other route is tried.
 */
async function writeBody(source: AsyncIterable<Uint8Array>, destination: string, expected: number | null,
  touch: () => void): Promise<number> {
  let bytes = 0;
  const counter = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      touch();
      bytes += chunk.length;
      callback(null, chunk);
    },
  });
  try {
    await pipeline(source, counter, createWriteStream(destination, { flags: "w", mode: 0o600 }));
  } catch (error) {
    const fileError = error as NodeJS.ErrnoException;
    if (fileError.path !== undefined && ["open", "write", "close", "fsync"].includes(fileError.syscall ?? "")) {
      throw new LocalFileError(fileError.message, fileError.code);
    }
    throw error;
  }
  if (expected !== null && bytes !== expected) throw new TransportError("The download ended early.", true, "protocol");
  return bytes;
}

async function readSmall(source: AsyncIterable<Uint8Array>): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of source) {
    if (size < ERROR_BODY_LIMIT) chunks.push(Buffer.from(chunk).subarray(0, ERROR_BODY_LIMIT - size));
    size += chunk.length;
  }
  return Buffer.concat(chunks);
}

/** GET over the direct TLS-PSK route; a 2xx body is written to `destination` as it arrives. */
export function downloadOverPSK(
  target: { host: string; port: number },
  token: string,
  request: HostRequest,
  destination: string,
  options: PSKOptions = {},
): Promise<DownloadResult> {
  return requestOverPSK(target, token, request, options, async (incoming: http.IncomingMessage) => {
    const status = incoming.statusCode ?? 502;
    if (encoded(incoming.headers)) throw new TransportError("The Mac sent an encoded download.", true, "protocol");
    const headers = responseHeaders(incoming.headers);
    if (status < 200 || status >= 300) return { status, headers, errorBody: await readSmall(incoming), bytes: 0 };
    const bytes = await writeBody(incoming, destination, expectedLength(incoming.headers), () => {});
    return { status, headers, errorBody: Buffer.alloc(0), bytes };
  });
}

/** GET over the Mac's HTTPS (Tailscale) address; fails when no bytes arrive for `idleTimeoutMs`. */
export async function downloadOverHTTPS(
  origin: string,
  request: HostRequest,
  fetchImpl: FetchLike,
  destination: string,
  options: { headersTimeoutMs?: number; idleTimeoutMs?: number } = {},
): Promise<DownloadResult> {
  const idleTimeoutMs = options.idleTimeoutMs ?? 30000;
  const controller = new AbortController();
  let timer = setTimeout(() => controller.abort(), options.headersTimeoutMs ?? 20000);
  const touch = () => {
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(), idleTimeoutMs);
  };
  let response: Response;
  try {
    response = await fetchImpl(new URL(request.path.replace(/^\//, ""), origin).toString(), {
      method: "GET", headers: request.headers, signal: controller.signal, redirect: "manual",
    });
  } catch (error) {
    clearTimeout(timer);
    const text = `${(error as Error).message} ${String((error as { cause?: { code?: string } }).cause?.code ?? "")}`;
    if (controller.signal.aborted) throw new TransportError(`${new URL(origin).host} didn't answer in time.`, false, "timeout");
    throw new TransportError(`Couldn't reach ${new URL(origin).host} (${(error as Error).message}).`, !NOT_SENT.test(text), "connect");
  }
  touch();
  try {
    const raw: Record<string, string> = {};
    response.headers.forEach((value, name) => { raw[name] = value; });
    const headers: Record<string, string> = {};
    for (const [name, value] of Object.entries(raw)) if (!DROPPED_RESPONSE_HEADERS.has(name)) headers[name] = value;
    if (encoded(raw)) throw new TransportError("The Mac sent an encoded download.", true, "protocol");
    const source: AsyncIterable<Uint8Array> = response.body
      ? Readable.fromWeb(response.body as unknown as import("node:stream/web").ReadableStream<Uint8Array>)
      : Readable.from([]);
    if (response.status < 200 || response.status >= 300) {
      return { status: response.status, headers, errorBody: await readSmall(source), bytes: 0 };
    }
    const bytes = await writeBody(source, destination, expectedLength(raw), touch);
    return { status: response.status, headers, errorBody: Buffer.alloc(0), bytes };
  } catch (error) {
    if (error instanceof TransportError || error instanceof LocalFileError) throw error;
    if (controller.signal.aborted) throw new TransportError("The download stalled.", true, "timeout");
    throw new TransportError((error as Error).message, true, "protocol");
  } finally {
    clearTimeout(timer);
  }
}

export interface ArtifactSaveRequest {
  /** `/api/v1/home/artifacts/<id>/file` or `…/folder`. */
  path: string;
  folder: boolean;
  /** A safe default file name for the Save dialog. */
  name: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/i;

/** A file name Windows (and macOS) accept: no separators, reserved characters or names, or trailing dots. */
export function safeFileName(name: string, fallback = "Artifact"): string {
  const last = name.split(/[\\/]/).pop() ?? "";
  // eslint-disable-next-line no-control-regex
  let cleaned = last.replace(/[\u0000-\u001f\u007f<>:"|?*]/g, "_").trim().replace(/[. ]+$/, "");
  if (cleaned.startsWith(".")) cleaned = `_${cleaned.slice(1)}`;
  if (!cleaned || RESERVED.test(cleaned)) cleaned = cleaned ? `_${cleaned}` : fallback;
  return cleaned.slice(0, 200);
}

/** Validates the page's Save As request: only a registered artifact's ID reaches the Mac, never a path. */
export function artifactSaveRequest(input: unknown): ArtifactSaveRequest | { error: string } {
  if (!input || typeof input !== "object") return { error: "Choose an artifact to save." };
  const { id, folder, name } = input as { id?: unknown; folder?: unknown; name?: unknown };
  if (typeof id !== "string" || !UUID.test(id)) return { error: "That artifact can't be saved." };
  if (folder !== undefined && typeof folder !== "boolean") return { error: "That artifact can't be saved." };
  const wantsFolder = folder === true;
  let file = safeFileName(typeof name === "string" ? name : "", wantsFolder ? "Artifacts.zip" : "Artifact");
  if (wantsFolder && !file.toLowerCase().endsWith(".zip")) file += ".zip";
  return { path: `/api/v1/home/artifacts/${id}/${wantsFolder ? "folder" : "file"}`, folder: wantsFolder, name: file };
}

/** The Mac's error text for a refused download. */
export function downloadError(result: DownloadResult): string {
  try {
    const error = (JSON.parse(result.errorBody.toString("utf8")) as { error?: unknown }).error;
    if (typeof error === "string" && error) return error;
  } catch { /* not JSON */ }
  return `The Mac answered with HTTP ${result.status}.`;
}
