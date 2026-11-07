import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer as createHTTPServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { createServer as createTLSServer } from "node:tls";
import type { TLSSocket } from "node:tls";
import { gzipSync } from "node:zlib";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { PairingError, parsePairingLink } from "../src/main/home/pairing";
import { HomeService, errorMessage, homeReadPath } from "../src/main/home/service";
import type { SendWithToken } from "../src/main/home/service";
import { PairingStore } from "../src/main/home/store";
import type { SecretBox } from "../src/main/home/store";
import { PSK_CIPHERS, PSK_IDENTITY, TransportError, pskKey, sendOverPSK } from "../src/main/home/transport";
import type { HostRequest, HostResponse } from "../src/main/home/transport";
import type { Route } from "../src/main/home/router";
import {
  appleDate,
  buildDetail,
  buildOrigin,
  buildQueueNote,
  buildExtra,
  cardsOf,
  listedBuilds,
  listedTabTasks,
  ordinal,
  tabTaskDetail,
  hasRecordCards,
  recordDetails,
  recordTitle,
  statusLabel,
  statusTone,
} from "../src/shared/home";
import type { HomeTaskWorkspace } from "../src/shared/home";

const TOKEN = "test-pairing-token-0123456789abcdefghijk";
const TASK = "0D8032A8-1111-4222-8333-944455556666";
const RECORD = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
const LOG = "12345678-1234-4123-8123-123456789ABC";
const LINK = `cantripagent://pair?v=1&name=Studio&token=${TOKEN}&url=https://mac.tailnet.ts.net&direct=192.168.0.20:8766`;

/** Reversible stand-in for DPAPI that never stores the token as plain text. */
const box: SecretBox = {
  isEncryptionAvailable: () => true,
  encryptString: (text) => Buffer.from([...Buffer.from(text)].map((byte) => byte ^ 0x5a)),
  decryptString: (data) => Buffer.from([...data].map((byte) => byte ^ 0x5a)).toString(),
};

const cleanup: string[] = [];
afterEach(async () => {
  await Promise.all(cleanup.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempStore(secretBox: SecretBox = box): Promise<{ store: PairingStore; file: string }> {
  const dir = await mkdtemp(path.join(tmpdir(), "cantrip-home-"));
  cleanup.push(dir);
  const file = path.join(dir, "home-pairing.json");
  return { store: new PairingStore(file, secretBox), file };
}

function json(status: number, value: unknown): HostResponse {
  return { status, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(value)) };
}

/** A fake Mac: records each request and answers from `answer`. */
function fakeMac(answer: (route: Route, request: HostRequest) => HostResponse | Promise<HostResponse>) {
  const seen: { route: Route; token: string; request: HostRequest }[] = [];
  const send: SendWithToken = async (route, token, request) => {
    seen.push({ route, token, request });
    return answer(route, request);
  };
  return { seen, send };
}

describe("pairing links", () => {
  it("accepts the Mac's cantrip pair link and keeps its routes", () => {
    expect(parsePairingLink(LINK)).toEqual({
      name: "Studio",
      url: "https://mac.tailnet.ts.net/",
      directAddress: "192.168.0.20:8766",
      tailscaleOnly: false,
      token: TOKEN,
    });
  });

  it("rejects other schemes, plain HTTP to another computer and bad tokens", () => {
    expect(() => parsePairingLink("https://example.com/pair")).toThrow(PairingError);
    expect(() => parsePairingLink(`cantripagent://pair?v=1&token=${TOKEN}&url=http://mac.local`)).toThrow(/https/);
    expect(() => parsePairingLink("cantripagent://pair?v=1&token=short&direct=192.168.0.20:8766")).toThrow(/token/);
    expect(() => parsePairingLink(`cantripagent://pair?v=1&token=${TOKEN}`)).toThrow(/direct address/);
  });
});

describe("homeReadPath", () => {
  it("builds only Home's read-only GET paths", () => {
    expect(homeReadPath({ kind: "home" }, null)).toBe("/api/v1/home?history=recent&recentExchanges=3");
    expect(homeReadPath({ kind: "background" }, null)).toBe("/api/v1/home/background");
    expect(homeReadPath({ kind: "tasks" }, null)).toBe("/api/v1/home/tasks");
    expect(homeReadPath({ kind: "tasks", revision: "r-42" }, null)).toBe("/api/v1/home/tasks?revision=r-42");
    expect(homeReadPath({ kind: "recordCards", taskID: TASK, recordID: RECORD }, null))
      .toBe(`/api/v1/home/tasks/${TASK}/records/${RECORD}/cards`);
    expect(homeReadPath({ kind: "log" }, LOG)).toBe(`/api/v1/sessions/${LOG}?history=recent&recentExchanges=3`);
  });

  it("refuses anything else: other kinds, traversal, query injection, a log before Background", () => {
    for (const bad of [
      null, "home", {}, { kind: "sessions" }, { kind: "artifacts" },
      { kind: "recordCards", taskID: "../../memory", recordID: RECORD },
      { kind: "recordCards", taskID: TASK, recordID: `${RECORD}/../x` },
      { kind: "tasks", revision: "1&history=all" },
      { kind: "tasks", revision: 7 },
    ]) {
      expect(() => homeReadPath(bad, LOG)).toThrow();
    }
    expect(() => homeReadPath({ kind: "log" }, null)).toThrow(/Background/);
  });
});

describe("PairingStore", () => {
  it("saves the token encrypted and loads it back", async () => {
    const { store, file } = await tempStore();
    const { token, ...server } = parsePairingLink(LINK);
    store.save(server, token);
    expect(await readFile(file, "utf8")).not.toContain(TOKEN);
    expect(store.load()).toEqual({ server, token });
    store.clear();
    expect(store.load()).toBeNull();
  });

  it("refuses to save without encryption and treats an unreadable token as unpaired", async () => {
    const { store } = await tempStore({ ...box, isEncryptionAvailable: () => false });
    const { token, ...server } = parsePairingLink(LINK);
    expect(() => store.save(server, token)).toThrow(/encrypt/);
    expect(store.load()).toBeNull();

    const other = await tempStore();
    other.store.save(server, token);
    const otherAccount = new PairingStore(other.file, { ...box, decryptString: () => { throw new Error("DPAPI"); } });
    expect(otherAccount.load()).toBeNull();
  });
});

describe("HomeService", () => {
  const background = {
    sessionID: LOG,
    runs: [{
      id: "R1", kind: "task", label: "Daily briefing", startedAt: 815_000_000, finishedAt: 815_000_060,
      status: "succeeded", summary: "Sunny all week.",
      cards: [{ version: 1, blocks: [{ type: "header", title: "Seattle" }], fallbackText: "Seattle forecast" }],
    }],
    queued: [], revision: "b1", maxParallel: 3, runningCount: 0, supportsStop: true,
  };

  it("pairs after the Mac answers, then reads with the token over the first route", async () => {
    const mac = fakeMac(() => json(200, background));
    const { store } = await tempStore();
    const service = new HomeService(store, mac.send);
    expect(service.status()).toEqual({ paired: false, server: "", route: "" });
    expect(await service.read({ kind: "home" })).toMatchObject({ ok: false });
    expect(mac.seen).toHaveLength(0);

    const paired = await service.pair(LINK);
    expect(paired).toMatchObject({ ok: true, status: { paired: true, server: "Studio", route: "Direct, encrypted (192.168.0.20:8766)" } });
    expect(store.load()?.token).toBe(TOKEN);

    const read = await service.read({ kind: "background" });
    expect(read).toEqual({ ok: true, data: background });
    const last = mac.seen.at(-1)!;
    expect(last.token).toBe(TOKEN);
    expect(last.request).toEqual({
      method: "GET", path: "/api/v1/home/background",
      headers: { authorization: `Bearer ${TOKEN}`, accept: "application/json" },
    });
    // A new service (the next launch) loads the saved pairing.
    expect(new HomeService(store, mac.send).status().paired).toBe(true);
  });

  it("opens the Full Log only for the background log session the Mac named", async () => {
    const mac = fakeMac((_route, request) =>
      request.path.startsWith("/api/v1/sessions/") ? json(200, { session: { id: LOG, messages: [] } }) : json(200, background));
    const { store } = await tempStore();
    const service = new HomeService(store, mac.send);
    await service.pair(LINK);
    expect(await service.read({ kind: "log" })).toEqual({ ok: false, error: "Open Background first." });
    await service.read({ kind: "background" });
    expect(await service.read({ kind: "log" })).toMatchObject({ ok: true });
    expect(mac.seen.at(-1)!.request.path).toBe(`/api/v1/sessions/${LOG}?history=recent&recentExchanges=3`);
  });

  it("doesn't save a link the Mac rejects, and pairs with a notice while Home is off", async () => {
    const rejected = fakeMac(() => json(401, { error: "unauthorized" }));
    const first = await tempStore();
    const result = await new HomeService(first.store, rejected.send).pair(LINK);
    expect(result).toMatchObject({ ok: false, error: expect.stringMatching(/rejected/) });
    expect(first.store.load()).toBeNull();

    const off = fakeMac(() => json(409, { error: "Turn on Cantrip Home in the Mac's Cantrip settings first." }));
    const second = await tempStore();
    expect(await new HomeService(second.store, off.send).pair(LINK))
      .toMatchObject({ ok: true, notice: "Turn on Cantrip Home in the Mac's Cantrip settings first." });
    expect(second.store.load()).not.toBeNull();
  });

  it("falls back to the HTTPS route when the direct one can't connect", async () => {
    const mac = fakeMac((route) => {
      if (route.kind === "direct") throw new TransportError("Couldn't reach 192.168.0.20:8766 (ECONNREFUSED).", false, "connect");
      return json(200, background);
    });
    const { store } = await tempStore();
    const service = new HomeService(store, mac.send);
    expect(await service.pair(LINK)).toMatchObject({ ok: true });
    expect(service.status().route).toBe("HTTPS (mac.tailnet.ts.net)");
    expect(await service.read({ kind: "tasks" })).toMatchObject({ ok: true });
  });

  it("reports the Mac's errors and transport failures without throwing", async () => {
    let answer: () => HostResponse = () => json(200, background);
    const mac = fakeMac(() => answer());
    const { store } = await tempStore();
    const service = new HomeService(store, mac.send);
    await service.pair(LINK);
    answer = () => json(404, { error: "task not found" });
    expect(await service.read({ kind: "recordCards", taskID: TASK, recordID: RECORD }))
      .toEqual({ ok: false, status: 404, error: "task not found" });
    answer = () => ({ status: 200, headers: {}, body: Buffer.from("<html>") });
    expect(await service.read({ kind: "home" })).toMatchObject({ ok: false, error: expect.stringMatching(/can't read/) });
    answer = () => { throw new TransportError("The Mac stopped responding.", true, "timeout"); };
    expect(await service.read({ kind: "home" })).toEqual({ ok: false, error: "The Mac stopped responding." });
    const before = mac.seen.length;
    expect(await service.read({ kind: "recordCards", taskID: "x", recordID: RECORD })).toMatchObject({ ok: false });
    expect(mac.seen).toHaveLength(before);
  });

  it("unpairs by deleting the saved token", async () => {
    const mac = fakeMac(() => json(200, background));
    const { store, file } = await tempStore();
    const service = new HomeService(store, mac.send);
    await service.pair(LINK);
    expect(service.unpair()).toEqual({ paired: false, server: "", route: "" });
    await expect(readFile(file)).rejects.toThrow();
  });

  it("phrases HTTP errors for people", () => {
    expect(errorMessage(json(401, {}))).toMatch(/pair again/);
    expect(errorMessage({ status: 503, headers: {}, body: Buffer.from("down") })).toBe("The Mac answered with HTTP 503.");
  });
});

describe("sendOverPSK", () => {
  const key = pskKey(TOKEN);
  let port = 0;
  let seen: { url?: string; headers?: Record<string, unknown> } = {};
  const tlsServer = createTLSServer({
    ciphers: PSK_CIPHERS,
    minVersion: "TLSv1.2",
    maxVersion: "TLSv1.2",
    pskCallback: (_socket: TLSSocket, identity: string) => (identity === PSK_IDENTITY ? key : null),
  });
  const httpServer = createHTTPServer((request: IncomingMessage, response: ServerResponse) => {
    seen = { url: request.url, headers: request.headers };
    response.writeHead(200, { "content-type": "application/json", "content-encoding": "gzip" });
    response.end(gzipSync(Buffer.from(JSON.stringify({ runs: [] }))));
  });
  tlsServer.on("secureConnection", (socket) => httpServer.emit("connection", socket));

  beforeAll(async () => {
    await new Promise<void>((resolve) => tlsServer.listen(0, "127.0.0.1", resolve));
    port = (tlsServer.address() as AddressInfo).port;
  });
  afterAll(() => {
    tlsServer.close();
  });

  it("reads Home over the Mac's encrypted LAN listener with the pairing token", async () => {
    const response = await sendOverPSK({ host: "127.0.0.1", port }, TOKEN, {
      method: "GET", path: "/api/v1/home/background", headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(response.status).toBe(200);
    expect(JSON.parse(response.body.toString())).toEqual({ runs: [] });
    expect(seen).toMatchObject({ url: "/api/v1/home/background", headers: { "accept-encoding": "gzip", connection: "close" } });
  });

  it("fails the handshake with another token before sending anything", async () => {
    const error = await sendOverPSK({ host: "127.0.0.1", port }, "w".repeat(40), { method: "GET", path: "/", headers: {} })
      .catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(TransportError);
    expect(error).toMatchObject({ kind: "handshake", requestSent: false });
  });
});

describe("Home helpers", () => {
  const workspace: HomeTaskWorkspace = {
    recordLabel: "Bill",
    recordLabelPlural: "Bills",
    fields: [
      { key: "name", label: "Name", kind: "text" },
      { key: "due", label: "Due", kind: "date" },
      { key: "amount", label: "Amount", kind: "number" },
    ],
    list: { titleField: "name", subtitleFields: ["due"] },
    detailSections: [{ title: "Payment", fields: ["due", "amount"] }],
    records: [],
    cards: [{ kind: "list" }],
  };

  it("converts the Mac's dates and labels statuses", () => {
    expect(appleDate(0)?.toISOString()).toBe("2001-01-01T00:00:00.000Z");
    expect(appleDate("soon")).toBeNull();
    expect(statusLabel("succeeded")).toBe("Succeeded");
    expect(statusLabel("interrupted")).toBe("Interrupted");
    expect(statusLabel("newState")).toBe("NewState");
    expect(statusTone("failed")).toBe("negative");
    expect(statusTone("running")).toBe("accent");
  });

  it("lists the Mac's build queue like Cantrip Agent", () => {
    const builds = {
      enabled: true, slots: 2, limit: 1, reason: "macOS reports memory pressure",
      running: [{ pid: 101, title: "xcodebuild archive · App", source: "tab", since: 1_000_000, tabID: RECORD, tabTitle: "Docs site" }],
      waiting: [
        { pid: 102, title: "swift build · App", source: "ci", since: 1_000_030, job: "app · TestFlight" },
        { pid: 103, title: "swift test · Docs", source: "child", since: 1_000_040, tabTitle: "Docs" },
      ],
    };
    expect(listedBuilds({ builds })).toBe(builds);
    expect(listedBuilds({ builds: { ...builds, running: [], waiting: [] } })).toBeNull();
    expect(listedBuilds({})).toBeNull();
    const time = (date: Date) => String(date.getTime() / 1000);
    expect(buildDetail(builds.running[0], 0, time)).toBe("Docs site · started 1000000");
    expect(buildDetail(builds.waiting[0], 1, time)).toBe("Waiting · Next · CI · app · TestFlight · since 1000030");
    expect(buildDetail(builds.waiting[1], 2, time)).toBe("Waiting · 2nd in line · Child tab · Docs · since 1000040");
    expect(buildOrigin({ pid: 1, title: "swift build", source: "background", since: 0 })).toBe("Home background run");
    expect([1, 2, 3, 11, 12, 21, 103].map(ordinal)).toEqual(["1st", "2nd", "3rd", "11th", "12th", "21st", "103rd"]);
    expect(buildQueueNote(builds)).toBe(
      "1 build at a time while macOS reports memory pressure (normally 2). Your tabs go first, then child tabs and CI, then Home's background runs.");
    expect(buildQueueNote({ ...builds, limit: 2 })).toBe(
      "Up to 2 builds at once on your Mac. Your tabs go first, then child tabs and CI, then Home's background runs.");
    expect(buildQueueNote({ ...builds, enabled: false })).toBe(
      "Long jobs running on your Mac. The build queue is off, so builds don't take turns.");
    // Other long work on the Mac
    const job = { pid: 104, title: "build-atlas.py", source: "other", since: 1_000_000, kind: "job", state: "waitingOnDisk",
      project: "atlas", step: "compile_shaders.py", logFile: "b.log", logLine: "[5/6] shaders 99%" };
    expect(buildDetail(job, 0, time)).toBe("Waiting on disk · Started outside Cantrip · atlas · started 1000000");
    expect(buildExtra(job)).toBe("Now: compile_shaders.py\nb.log: [5/6] shaders 99%");
    expect(buildExtra(builds.running[0])).toBeNull();
    expect(buildDetail({ ...job, source: "tab", tabTitle: "Docs", state: "paused", project: undefined }, 2, time))
      .toBe("Paused · Docs · started 1000000");
  });

  it("lists tabs' running background tasks", () => {
    const tabTasks = [
      { tabID: RECORD, tabTitle: "Docs site", tasks: [{ id: "w", name: "watch-testflight", status: "running", startedAt: 1_000_000 }] },
      { tabID: "x", tabTitle: "Empty", tasks: [] },
    ];
    expect(listedTabTasks({ tabTasks }).map((tab) => tab.tabTitle)).toEqual(["Docs site"]);
    expect(listedTabTasks({})).toEqual([]);
    const time = (date: Date) => String(date.getTime() / 1000);
    expect(tabTaskDetail(tabTasks[0].tasks[0], time)).toBe("Running · since 1000000");
    expect(tabTaskDetail({ id: "q", name: "side-docs", status: "queued" }, time)).toBe("Queued");
  });

  it("keeps only card documents and finds record cards", () => {
    expect(cardsOf([{ blocks: [] }, null, "x", { title: "no blocks" }])).toEqual([{ blocks: [] }]);
    expect(cardsOf(undefined)).toEqual([]);
    expect(hasRecordCards(workspace)).toBe(false);
    expect(hasRecordCards({ cards: [{ kind: "weather" }] })).toBe(true);
  });

  it("titles and details a record by the workspace's fields", () => {
    const record = { id: RECORD, values: { name: "Electric", due: "2026-11-08", amount: "84.12" } };
    expect(recordTitle(workspace, record)).toBe("Electric");
    expect(recordTitle(workspace, { id: RECORD, values: { name: " ", due: "2026-11-08" } })).toBe("2026-11-08");
    expect(recordDetails(workspace, record)).toEqual([
      { title: "Payment", rows: [{ label: "Due", value: "2026-11-08" }, { label: "Amount", value: "84.12" }] },
    ]);
  });
});
