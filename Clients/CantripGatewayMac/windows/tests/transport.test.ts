import { createServer as createHTTPServer, IncomingMessage, ServerResponse } from "node:http";
import { AddressInfo, createServer as createTCPServer, Server } from "node:net";
import { createServer as createTLSServer, TLSSocket } from "node:tls";
import { gzipSync } from "node:zlib";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { FetchLike, forwardedHeaders, PSK_CIPHERS, PSK_IDENTITY, pskKey, sendOverHTTPS, sendOverPSK, TransportError } from "../src/main/transport";

const TOKEN = "t".repeat(40);
let port = 0;
let seen: { method?: string; url?: string; body?: string; headers?: Record<string, unknown> } = {};
const tlsServer = createTLSServer({
  ciphers: PSK_CIPHERS,
  minVersion: "TLSv1.2",
  maxVersion: "TLSv1.2",
  pskCallback: (_socket: TLSSocket, identity: string) => (identity === PSK_IDENTITY ? pskKey(TOKEN) : null),
});
const httpServer = createHTTPServer((request: IncomingMessage, response: ServerResponse) => {
  const chunks: Buffer[] = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    seen = { method: request.method, url: request.url, body: Buffer.concat(chunks).toString(), headers: request.headers };
    if (request.url === "/gzip") {
      response.writeHead(200, { "content-type": "application/json", "content-encoding": "gzip" });
      return response.end(gzipSync(Buffer.from('{"zipped":true}')));
    }
    if (request.url === "/binary") {
      response.writeHead(200, { "content-type": "application/octet-stream" });
      return response.end(Buffer.from([0, 1, 2, 255]));
    }
    response.writeHead(201, { "content-type": "application/json", "x-cipher": (request.socket as TLSSocket).getCipher().name });
    response.end(JSON.stringify({ ok: true }));
  });
});
tlsServer.on("secureConnection", (socket) => httpServer.emit("connection", socket));

let stalled: Server;
let stalledPort = 0;

beforeAll(async () => {
  await new Promise<void>((resolve) => tlsServer.listen(0, "127.0.0.1", resolve));
  port = (tlsServer.address() as AddressInfo).port;
  // Accepts TCP but never answers the TLS handshake.
  stalled = createTCPServer(() => {});
  await new Promise<void>((resolve) => stalled.listen(0, "127.0.0.1", resolve));
  stalledPort = (stalled.address() as AddressInfo).port;
});

afterAll(() => {
  tlsServer.close();
  stalled.close();
});

describe("sendOverPSK", () => {
  it("round-trips a request over ECDHE-PSK with the pairing token", async () => {
    const response = await sendOverPSK({ host: "127.0.0.1", port }, TOKEN, {
      method: "POST", path: "/api/v1/sessions/x/messages?mode=auto",
      headers: { authorization: "Bearer abc", "content-type": "application/json" },
      body: Buffer.from('{"text":"hi"}'),
    });
    expect(response.status).toBe(201);
    expect(JSON.parse(response.body.toString())).toEqual({ ok: true });
    expect(response.headers["x-cipher"]).toBe(PSK_CIPHERS);
    expect(seen).toMatchObject({ method: "POST", url: "/api/v1/sessions/x/messages?mode=auto", body: '{"text":"hi"}' });
    expect(seen.headers).toMatchObject({ authorization: "Bearer abc", connection: "close" });
  });

  it("decodes gzip and keeps binary bodies intact", async () => {
    const zipped = await sendOverPSK({ host: "127.0.0.1", port }, TOKEN, { method: "GET", path: "/gzip", headers: {} });
    expect(JSON.parse(zipped.body.toString())).toEqual({ zipped: true });
    expect(zipped.headers["content-encoding"]).toBeUndefined();
    const binary = await sendOverPSK({ host: "127.0.0.1", port }, TOKEN, { method: "GET", path: "/binary", headers: {} });
    expect([...binary.body]).toEqual([0, 1, 2, 255]);
  });

  it("reports a wrong token as a handshake failure that never sent the request", async () => {
    const error = await sendOverPSK({ host: "127.0.0.1", port }, "w".repeat(40), { method: "POST", path: "/", headers: {} })
      .catch((caught) => caught);
    expect(error).toBeInstanceOf(TransportError);
    expect(error).toMatchObject({ kind: "handshake", requestSent: false });
  });

  it("reports refused and stalled connections as not sent", async () => {
    const refused = await sendOverPSK({ host: "127.0.0.1", port: 1 }, TOKEN, { method: "POST", path: "/", headers: {} })
      .catch((caught) => caught);
    expect(refused).toMatchObject({ kind: "connect", requestSent: false });
    const started = Date.now();
    const timedOut = await sendOverPSK({ host: "127.0.0.1", port: stalledPort }, TOKEN, { method: "GET", path: "/", headers: {} },
      { connectTimeoutMs: 300 }).catch((caught) => caught);
    expect(timedOut).toMatchObject({ kind: "timeout", requestSent: false });
    expect(Date.now() - started).toBeLessThan(2000);
  });
});

describe("sendOverHTTPS", () => {
  it("joins paths onto the origin and passes the response through", async () => {
    let requested = "";
    const fake = (async (url: string, init: RequestInit) => {
      requested = `${init.method} ${url}`;
      return new Response('{"sessions":[]}', { status: 200, headers: { "content-type": "application/json", "content-length": "15" } });
    }) as FetchLike;
    const response = await sendOverHTTPS("https://mac.example.ts.net/", { method: "GET", path: "/api/v1/sessions?x=1", headers: {} }, fake);
    expect(requested).toBe("GET https://mac.example.ts.net/api/v1/sessions?x=1");
    expect(response.status).toBe(200);
    expect(response.headers["content-length"]).toBeUndefined();
  });

  it("treats a refused connection as not sent, and an unknown failure as possibly sent", async () => {
    const refused = (async () => { throw Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNREFUSED" } }); }) as FetchLike;
    await expect(sendOverHTTPS("https://mac.example/", { method: "POST", path: "/x", headers: {} }, refused))
      .rejects.toMatchObject({ requestSent: false, kind: "connect" });
    const reset = (async () => { throw new TypeError("net::ERR_CONNECTION_RESET"); }) as FetchLike;
    await expect(sendOverHTTPS("https://mac.example/", { method: "POST", path: "/x", headers: {} }, reset))
      .rejects.toMatchObject({ requestSent: true });
  });
});

describe("forwardedHeaders", () => {
  it("forwards only what the Mac needs", () => {
    expect(forwardedHeaders([["Authorization", "Bearer a"], ["Cookie", "x"], ["Origin", "cantrip-host://mac"], ["Accept-Encoding", "gzip"], ["Content-Type", "application/json"]]))
      .toEqual({ authorization: "Bearer a", "content-type": "application/json" });
  });
});
