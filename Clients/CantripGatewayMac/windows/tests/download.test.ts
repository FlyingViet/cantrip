import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { createServer as createHTTPServer, IncomingMessage, ServerResponse } from "node:http";
import { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer as createTLSServer, TLSSocket } from "node:tls";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { artifactSaveRequest, downloadError, downloadOverHTTPS, downloadOverPSK, safeFileName } from "../src/main/download";
import { HostRouter, Route } from "../src/main/router";
import { FetchLike, PSK_CIPHERS, PSK_IDENTITY, pskKey, TransportError } from "../src/main/transport";
import { artifactFolder, artifactOriginalName } from "../src/gateway/ui/home/homeLogic";

const TOKEN = "d".repeat(40);
const ID = "20000000-0000-0000-0000-000000000001";
const BODY = Buffer.from(Array.from({ length: 3 * 1024 * 1024 + 11 }, (_, index) => (index * 31 + (index >> 9)) & 0xff));
let port = 0;
let seenHeaders: Record<string, unknown> = {};
const folder = mkdtempSync(join(tmpdir(), "gateway-download-"));

const tlsServer = createTLSServer({
  ciphers: PSK_CIPHERS, minVersion: "TLSv1.2", maxVersion: "TLSv1.2",
  pskCallback: (_socket: TLSSocket, identity: string) => (identity === PSK_IDENTITY ? pskKey(TOKEN) : null),
});
const httpServer = createHTTPServer((request: IncomingMessage, response: ServerResponse) => {
  seenHeaders = request.headers;
  if (request.url === `/api/v1/home/artifacts/${ID}/file`) {
    response.writeHead(200, {
      "content-type": "video/mp4", "content-length": String(BODY.length),
      "content-disposition": `attachment; filename="clip.mp4"; filename*=UTF-8''clip.mp4`,
    });
    // In pieces, like the host's streamed send.
    let offset = 0;
    const next = () => {
      if (offset >= BODY.length) return response.end();
      const piece = BODY.subarray(offset, offset + 256 * 1024);
      offset += piece.length;
      if (response.write(piece)) setImmediate(next);
      else response.once("drain", next);
    };
    return next();
  }
  if (request.url === `/api/v1/home/artifacts/${ID}/folder`) {
    response.writeHead(404, { "content-type": "application/json" });
    return response.end(JSON.stringify({ error: "This artifact isn't in a folder." }));
  }
  // Truncated: promises 5000 bytes, sends 1000, then drops the connection.
  response.writeHead(200, { "content-length": "5000" });
  response.write(Buffer.alloc(1000, 1));
  setTimeout(() => request.socket.destroy(), 20);
});
tlsServer.on("secureConnection", (socket) => httpServer.emit("connection", socket));

beforeAll(async () => {
  await new Promise<void>((resolve) => tlsServer.listen(0, "127.0.0.1", resolve));
  port = (tlsServer.address() as AddressInfo).port;
});

afterAll(() => {
  tlsServer.close();
  rmSync(folder, { recursive: true, force: true });
});

describe("downloadOverPSK", () => {
  it("streams the body to disk over ECDHE-PSK with the pairing token", async () => {
    const destination = join(folder, "clip.mp4");
    const result = await downloadOverPSK({ host: "127.0.0.1", port }, TOKEN, {
      method: "GET", path: `/api/v1/home/artifacts/${ID}/file`, headers: { authorization: `Bearer ${TOKEN}` },
    }, destination);
    expect(result).toMatchObject({ status: 200, bytes: BODY.length });
    expect(result.headers["content-disposition"]).toContain("clip.mp4");
    expect(readFileSync(destination).equals(BODY)).toBe(true);
    expect(seenHeaders).toMatchObject({ authorization: `Bearer ${TOKEN}` });
    expect(seenHeaders["accept-encoding"]).toBeUndefined();
  });

  it("keeps a refusal's error text and writes nothing", async () => {
    const destination = join(folder, "refused.zip");
    const result = await downloadOverPSK({ host: "127.0.0.1", port }, TOKEN, {
      method: "GET", path: `/api/v1/home/artifacts/${ID}/folder`, headers: {},
    }, destination);
    expect(result.status).toBe(404);
    expect(downloadError(result)).toBe("This artifact isn't in a folder.");
    expect(existsSync(destination)).toBe(false);
  });

  it("fails a body that ends early", async () => {
    const error = await downloadOverPSK({ host: "127.0.0.1", port }, TOKEN, {
      method: "GET", path: "/truncated", headers: {},
    }, join(folder, "short.bin")).catch((caught) => caught);
    expect(error).toBeInstanceOf(TransportError);
    expect(error).toMatchObject({ requestSent: true });
  });
});

describe("downloadOverHTTPS", () => {
  const stream = (pieces: Buffer[], hang = false, signal?: AbortSignal) => new ReadableStream<Uint8Array>({
    start(controller) {
      for (const piece of pieces) controller.enqueue(new Uint8Array(piece));
      if (!hang) controller.close();
      signal?.addEventListener("abort", () => controller.error(new Error("aborted")));
    },
  });

  it("writes the body as it arrives and checks its length", async () => {
    let requested = "";
    const fake = (async (url: string, init: RequestInit) => {
      requested = `${init.method} ${url}`;
      return new Response(stream([BODY.subarray(0, 100), BODY.subarray(100)]), {
        status: 200, headers: { "content-length": String(BODY.length), "content-disposition": "attachment; filename=\"a.bin\"" },
      });
    }) as FetchLike;
    const destination = join(folder, "https.bin");
    const result = await downloadOverHTTPS("https://mac.example/", {
      method: "GET", path: `/api/v1/home/artifacts/${ID}/file`, headers: {},
    }, fake, destination);
    expect(requested).toBe(`GET https://mac.example/api/v1/home/artifacts/${ID}/file`);
    expect(result).toMatchObject({ status: 200, bytes: BODY.length });
    expect(readFileSync(destination).equals(BODY)).toBe(true);
  });

  it("fails a stalled body instead of waiting forever", async () => {
    const fake = (async (_url: string, init: RequestInit) =>
      new Response(stream([Buffer.alloc(10)], true, init.signal ?? undefined), { status: 200, headers: { "content-length": "100" } })) as FetchLike;
    const started = Date.now();
    const error = await downloadOverHTTPS("https://mac.example/", { method: "GET", path: "/x", headers: {} }, fake,
      join(folder, "stalled.bin"), { idleTimeoutMs: 200 }).catch((caught) => caught);
    expect(error).toMatchObject({ kind: "timeout", requestSent: true });
    expect(Date.now() - started).toBeLessThan(2000);
  });

  it("refuses an encoded body and reports a refused connection as not sent", async () => {
    const zipped = (async () => new Response("x", { status: 200, headers: { "content-encoding": "gzip" } })) as FetchLike;
    await expect(downloadOverHTTPS("https://mac.example/", { method: "GET", path: "/x", headers: {} }, zipped, join(folder, "z")))
      .rejects.toMatchObject({ kind: "protocol" });
    const refused = (async () => { throw Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNREFUSED" } }); }) as FetchLike;
    await expect(downloadOverHTTPS("https://mac.example/", { method: "GET", path: "/x", headers: {} }, refused, join(folder, "r")))
      .rejects.toMatchObject({ requestSent: false, kind: "connect" });
  });
});

describe("artifactSaveRequest", () => {
  it("sends only an artifact ID, never a path", () => {
    expect(artifactSaveRequest({ id: ID, folder: false, name: "Report.pdf" }))
      .toEqual({ path: `/api/v1/home/artifacts/${ID}/file`, folder: false, name: "Report.pdf" });
    expect(artifactSaveRequest({ id: ID, folder: true, name: "ddia-knowledge-graph" }))
      .toEqual({ path: `/api/v1/home/artifacts/${ID}/folder`, folder: true, name: "ddia-knowledge-graph.zip" });
    expect(artifactSaveRequest({ id: "../../etc/passwd", folder: false, name: "x" })).toHaveProperty("error");
    expect(artifactSaveRequest({ id: ID, folder: "yes", name: "x" })).toHaveProperty("error");
    expect(artifactSaveRequest(null)).toHaveProperty("error");
  });

  it("makes default names safe for Windows", () => {
    expect(safeFileName("..\\..\\Windows\\win.ini")).toBe("win.ini");
    expect(safeFileName("a<b>:c?.md")).toBe("a_b__c_.md");
    expect(safeFileName("notes. ")).toBe("notes");
    expect(safeFileName("CON.txt")).toBe("_CON.txt");
    expect(safeFileName(".env")).toBe("_env");
    expect(safeFileName("")).toBe("Artifact");
  });
});

describe("HostRouter.perform", () => {
  it("falls back to the next route for a download that never started", async () => {
    const routes: Route[] = [{ kind: "direct", address: "192.0.2.10:1", host: "192.0.2.10", port: 1 }, { kind: "https", origin: "https://mac.example/" }];
    const router = new HostRouter(routes, async () => { throw new Error("unused"); });
    const tried: string[] = [];
    const result = await router.perform(true, async (route) => {
      tried.push(route.kind);
      if (route.kind === "direct") throw new TransportError("refused", false, "connect");
      return "saved";
    });
    expect(result).toBe("saved");
    expect(tried).toEqual(["direct", "https"]);
    expect(router.current.kind).toBe("https");
  });
});

describe("artifact folders", () => {
  it("groups by the top-level artifacts folder and keeps the original name", () => {
    expect(artifactFolder({ relativePath: "report.md" })).toBeNull();
    expect(artifactFolder({ relativePath: "ddia-knowledge-graph/data/graph.json" })).toBe("ddia-knowledge-graph");
    expect(artifactOriginalName({ title: "Graph", relativePath: "ddia-knowledge-graph/graph.html" })).toBe("graph.html");
  });
});
