import { createHash } from "node:crypto";
import * as http from "node:http";
import * as tls from "node:tls";
import { gunzipSync } from "node:zlib";

/** Shared with the Mac host's LAN listener (RemoteLANProtocol.swift). */
export const PSK_IDENTITY = "cantrip-remote-v1";
/**
 * Electron's BoringSSL has no DHE-PSK or PSK-AES-GCM suites (what Apple clients negotiate), so
 * this client uses ECDHE-PSK with ChaCha20-Poly1305, which the host accepts since v1.0-161.
 */
export const PSK_CIPHERS = "ECDHE-PSK-CHACHA20-POLY1305";

export interface HostRequest {
  method: string;
  /** Path and query, starting with "/". */
  path: string;
  headers: Record<string, string>;
  body?: Buffer;
}

export interface HostResponse {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
}

export type FailureKind = "connect" | "handshake" | "timeout" | "protocol";

export class TransportError extends Error {
  constructor(
    message: string,
    /** True once the request may have reached the Mac; such mutations are never retried. */
    readonly requestSent: boolean,
    readonly kind: FailureKind,
  ) {
    super(message);
  }
}

export function pskKey(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

/** Request headers forwarded to the Mac; everything else (cookies, Origin, Accept-Encoding) stays local. */
const FORWARDED = new Set(["authorization", "content-type", "accept", "if-none-match", "if-modified-since", "x-cantrip-client"]);

export function forwardedHeaders(headers: Iterable<[string, string]>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [name, value] of headers) {
    const key = name.toLowerCase();
    if (FORWARDED.has(key)) result[key] = value;
  }
  return result;
}

export const DROPPED_RESPONSE_HEADERS = new Set(["connection", "keep-alive", "transfer-encoding", "content-length", "content-encoding"]);

export function responseHeaders(headers: http.IncomingHttpHeaders): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined || DROPPED_RESPONSE_HEADERS.has(name)) continue;
    result[name] = Array.isArray(value) ? value.join(", ") : value;
  }
  return result;
}

function decode(body: Buffer, encoding: string | undefined): Buffer {
  return encoding?.toLowerCase() === "gzip" ? gunzipSync(body) : body;
}

export interface PSKOptions {
  connectTimeoutMs?: number;
  /** Fails the request when the connection is silent this long after the handshake. */
  idleTimeoutMs?: number;
}

/** One request per TLS-PSK connection (the host closes after each response). */
export function sendOverPSK(
  target: { host: string; port: number },
  token: string,
  request: HostRequest,
  options: PSKOptions = {},
): Promise<HostResponse> {
  return requestOverPSK(target, token, request, options, async (incoming) => {
    const chunks: Buffer[] = [];
    for await (const chunk of incoming) chunks.push(chunk as Buffer);
    let body: Buffer;
    try {
      body = decode(Buffer.concat(chunks), incoming.headers["content-encoding"] as string | undefined);
    } catch (error) {
      throw new TransportError(`The Mac sent a damaged response: ${(error as Error).message}`, true, "protocol");
    }
    return { status: incoming.statusCode ?? 502, headers: responseHeaders(incoming.headers), body };
  });
}

/**
 * Sends `request` over a fresh TLS-PSK connection and hands the response stream to `consume`. The
 * connection's idle timeout keeps applying while `consume` reads, so a stalled body fails too.
 */
export function requestOverPSK<T>(
  target: { host: string; port: number },
  token: string,
  request: HostRequest,
  options: PSKOptions,
  consume: (incoming: http.IncomingMessage) => Promise<T>,
): Promise<T> {
  const connectTimeoutMs = options.connectTimeoutMs ?? 4000;
  const idleTimeoutMs = options.idleTimeoutMs ?? 30000;
  const key = pskKey(token);
  return new Promise<T>((resolve, reject) => {
    let secure = false;
    let settled = false;
    const fail = (error: TransportError) => {
      if (settled) return;
      settled = true;
      clearTimeout(connectTimer);
      socket.destroy();
      reject(error);
    };
    const socket = tls.connect({
      host: target.host,
      port: target.port,
      ciphers: PSK_CIPHERS,
      minVersion: "TLSv1.2",
      maxVersion: "TLSv1.2",
      pskCallback: () => ({ identity: PSK_IDENTITY, psk: key }),
      // PSK authenticates both sides; there is no certificate to check.
      checkServerIdentity: () => undefined,
    });
    const connectTimer = setTimeout(
      () => fail(new TransportError(`Timed out connecting to ${target.host}:${target.port}.`, false, "timeout")),
      connectTimeoutMs,
    );
    socket.once("secureConnect", () => {
      secure = true;
      clearTimeout(connectTimer);
      socket.setTimeout(idleTimeoutMs, () =>
        fail(new TransportError("The Mac stopped responding.", true, "timeout")),
      );
    });
    socket.on("error", (error: NodeJS.ErrnoException) => {
      if (secure) return fail(new TransportError(error.message, true, "protocol"));
      const handshake = /alert|handshake|ssl|tls|psk/i.test(`${error.code ?? ""} ${error.message}`);
      fail(new TransportError(
        handshake
          ? `The Mac at ${target.host}:${target.port} refused the secure connection. Check the pairing token, and that Cantrip on the Mac is up to date.`
          : `Couldn't reach ${target.host}:${target.port} (${error.code ?? error.message}).`,
        false,
        handshake ? "handshake" : "connect",
      ));
    });

    const headers: Record<string, string> = { ...request.headers, host: `${target.host}:${target.port}`, connection: "close" };
    if (request.body) headers["content-length"] = String(request.body.length);
    const outgoing = http.request({
      method: request.method,
      path: request.path,
      headers,
      createConnection: () => socket,
    });
    outgoing.on("error", (error: NodeJS.ErrnoException) => {
      if (!secure) return; // reported by the socket handler
      fail(new TransportError(error.message, true, "protocol"));
    });
    outgoing.on("response", (incoming) => {
      consume(incoming).then((value) => {
        if (settled) return;
        settled = true;
        clearTimeout(connectTimer);
        socket.destroy();
        resolve(value);
      }, (error: Error) => {
        fail(error instanceof TransportError ? error : new TransportError(error.message, true, "protocol"));
      });
    });
    outgoing.end(request.body);
  });
}

export const NOT_SENT = /ERR_(NAME_NOT_RESOLVED|CONNECTION_REFUSED|ADDRESS_UNREACHABLE|INTERNET_DISCONNECTED|NETWORK_CHANGED|CONNECTION_TIMED_OUT|NAME_RESOLUTION_FAILED)|ECONNREFUSED|ENOTFOUND|EHOSTUNREACH|ENETUNREACH|EAI_AGAIN/;

/**
 * The Mac's HTTPS address (Tailscale Serve). `fetchImpl` is Electron's net.fetch in the app
 * (Chromium's network stack and certificate checks) and Node's fetch in tests.
 */
export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export async function sendOverHTTPS(
  origin: string,
  request: HostRequest,
  fetchImpl: FetchLike,
  headersTimeoutMs = 20000,
): Promise<HostResponse> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), headersTimeoutMs);
  const idempotent = request.method === "GET" || request.method === "HEAD";
  let response: Response;
  try {
    response = await fetchImpl(new URL(request.path.replace(/^\//, ""), origin).toString(), {
      method: request.method,
      headers: request.headers,
      body: request.body && request.body.length ? new Uint8Array(request.body) : undefined,
      signal: controller.signal,
      redirect: "manual",
    });
  } catch (error) {
    const text = `${(error as Error).message} ${String((error as { cause?: { code?: string } }).cause?.code ?? "")}`;
    if (controller.signal.aborted) {
      throw new TransportError(`${new URL(origin).host} didn't answer in time.`, !idempotent, "timeout");
    }
    throw new TransportError(`Couldn't reach ${new URL(origin).host} (${(error as Error).message}).`, !NOT_SENT.test(text), "connect");
  } finally {
    clearTimeout(timer);
  }
  const headers: Record<string, string> = {};
  response.headers.forEach((value, name) => {
    if (!DROPPED_RESPONSE_HEADERS.has(name)) headers[name] = value;
  });
  return { status: response.status, headers, body: Buffer.from(await response.arrayBuffer()) };
}
