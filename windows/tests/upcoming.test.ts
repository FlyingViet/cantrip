import { describe, expect, it } from "vitest";
import { HomeService, homeReadPath, homeWriteRequest } from "../src/main/home/service";
import type { SendWithToken } from "../src/main/home/service";
import type { Pairing, PairingStore } from "../src/main/home/store";
import type { HostRequest, HostResponse } from "../src/main/home/transport";
import { parseUpcoming, upcomingMeta, upcomingSections, upcomingWhen, type UpcomingItem } from "../src/renderer/upcoming";
import { sectionCount } from "../src/renderer/viewsGrid";

const TOKEN = "test-pairing-token-0123456789abcdefghijk";
const LINK = `cantripagent://pair?v=1&name=Studio&token=${TOKEN}&url=https://mac.example.com&direct=10.0.0.0:8766`;

function json(status: number, value: unknown): HostResponse {
  return { status, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(value)) };
}

function memoryStore(): PairingStore {
  let saved: Pairing | null = null;
  return {
    load: () => saved,
    save: (server: Pairing["server"], token: string) => (saved = { server, token }),
    clear: () => { saved = null; },
  } as unknown as PairingStore;
}

async function pairedService(answer: (request: HostRequest) => HostResponse) {
  const seen: HostRequest[] = [];
  const send: SendWithToken = async (_route, _token, request) => {
    seen.push(request);
    return request.path === "/api/v1/home/background" ? json(200, { sessionID: "", runs: [], queued: [] }) : answer(request);
  };
  const service = new HomeService(memoryStore(), send);
  expect(await service.pair(LINK)).toMatchObject({ ok: true });
  seen.length = 0;
  return { service, seen };
}

// Synthetic items in the Mac's shape and order.
const item = (id: string, extra: Partial<UpcomingItem> & Record<string, unknown> = {}): UpcomingItem & Record<string, unknown> => ({
  id, kind: "step", title: `Item ${id}`, schedule: "Once", owner: "Kitchen tab", state: "scheduled", group: "next", ...extra,
});
const ITEMS = [
  ...Array.from({ length: 8 }, (_, index) => item(`step:S${index}`, { nextRunAt: 1_795_070_100 + index * 600, cancelLabel: "Cancel", confirm: "Cancel it?", canResume: false })),
  item("wait:W1", { group: "waiting", state: "waiting", schedule: "Waiting, until Fri Nov 20, 9:50 AM", cancelLabel: "Stop" }),
  item("mac:com.example.backup", { group: "repeating", schedule: "Every 15 minutes", owner: "This Mac", cancelLabel: "Pause" }),
  item("task:T1", { group: "paused", state: "paused", schedule: "Every day at 8:00 AM", owner: "Cantrip Home", canResume: true }),
];

describe("Upcoming in the read-only Home window: the main process", () => {
  it("reads the list with its revision, and refuses bad revisions", () => {
    expect(homeReadPath({ kind: "upcoming" }, null)).toBe("/api/v1/home/upcoming");
    expect(homeReadPath({ kind: "upcoming", revision: "d4d33720" }, null)).toBe("/api/v1/home/upcoming?revision=d4d33720");
    for (const revision of ["a\nb", "1&id=step:A", "x".repeat(200), 7, null]) {
      expect(() => homeReadPath({ kind: "upcoming", revision }, null)).toThrow();
    }
  });

  it("never builds Upcoming's cancel or resume", () => {
    const lookup = () => new Set(["cancel", "resume"]);
    for (const write of [
      { kind: "cancel", id: "step:A" }, { kind: "resume", id: "task:T1" },
      { kind: "cancel", viewID: "V", id: "step:A" }, { kind: "upcoming", viewID: "V" },
      { kind: "action", viewID: "../upcoming", actionID: "cancel" },
    ]) {
      expect(() => homeWriteRequest(write, lookup)).toThrow();
    }
    for (const read of [{ kind: "upcomingCancel" }, { kind: "upcoming/cancel" }, { kind: "cancel", id: "step:A" }]) {
      expect(() => homeReadPath(read, null)).toThrow();
    }
  });

  it("sends only the GET, with the pairing token; cancel and resume never reach the Mac", async () => {
    const { service, seen } = await pairedService((request) =>
      request.method === "GET" && request.path.startsWith("/api/v1/home/upcoming") ? json(200, { items: ITEMS, revision: "u1" }) : json(500, {}));
    expect(await service.read({ kind: "upcoming" })).toEqual({ ok: true, data: { items: ITEMS, revision: "u1" } });
    expect(seen).toEqual([{ method: "GET", path: "/api/v1/home/upcoming", headers: { authorization: `Bearer ${TOKEN}`, accept: "application/json" } }]);
    for (const write of [{ kind: "cancel", id: "step:S0" }, { kind: "resume", id: "task:T1" }]) {
      expect(await service.viewWrite(write as never)).toMatchObject({ ok: false });
    }
    expect(await service.read({ kind: "upcomingCancel" } as never)).toEqual({ ok: false, error: "Invalid Home request." });
    expect(seen).toHaveLength(1);
  });

  it("hands an older Mac's 404 to the window as a status", async () => {
    const { service } = await pairedService(() => json(404, { error: "not found" }));
    expect(await service.read({ kind: "upcoming" })).toEqual({ ok: false, status: 404, error: "not found" });
  });
});

describe("Upcoming in the read-only Home window: the list", () => {
  // Wednesday, Nov 18 2026, 9:56 AM in Los Angeles.
  const now = new Date("2026-11-18T17:56:00Z");
  const zone = "America/Los_Angeles";
  const at = (iso: string) => new Date(iso).getTime() / 1000;
  // ICU versions differ in the space before AM/PM (some use a narrow no-break space).
  const plain = (value: string) => value.replace(/[\u202f\u00a0]/g, " ");

  it("reads the Mac's answer leniently, without its buttons", () => {
    const parsed = parseUpcoming({ revision: "u1", items: [ITEMS[0], { title: "no id" }, null, { id: "x", nextRunAt: "soon" }] });
    expect(parsed && !parsed.unchanged ? parsed.items.map((entry) => entry.id) : null).toEqual(["step:S0", "x"]);
    const first = parsed && !parsed.unchanged ? parsed.items[0] : null;
    expect(first).not.toHaveProperty("cancelLabel");
    expect(first).not.toHaveProperty("confirm");
    expect(parsed && !parsed.unchanged ? parsed.items[1] : null).toMatchObject({ title: "Untitled", group: "next", nextRunAt: undefined });
    expect(parseUpcoming({ unchanged: true, revision: "u1" })).toEqual({ unchanged: true, revision: "u1" });
    expect(parseUpcoming({ error: "nope" })).toBeNull();
    expect(parseUpcoming(null)).toBeNull();
  });

  it("groups in order, hides empty groups and cuts Next up to 6 until Show all", () => {
    const shape = (showAll: boolean, items: UpcomingItem[] = ITEMS) =>
      upcomingSections(items, showAll).map((section) => `${section.title}:${section.items.length}/${section.total}`);
    expect(shape(false)).toEqual(["Next up:6/8", "Waiting:1/1", "Repeating:1/1", "Paused:1/1"]);
    expect(shape(true)).toEqual(["Next up:8/8", "Waiting:1/1", "Repeating:1/1", "Paused:1/1"]);
    expect(shape(false, [item("a", { group: "paused" }), item("b", { group: "someday" })])).toEqual(["Next up:1/1", "Paused:1/1"]);
    expect(upcomingSections([], false)).toEqual([]);
  });

  it("says when relative to this PC's today, then the schedule and owner once each", () => {
    expect(plain(upcomingWhen(at("2026-11-19T06:35:00Z"), now, "en-US", zone))).toBe("Today 10:35 PM");
    expect(plain(upcomingWhen(at("2026-11-19T11:00:00Z"), now, "en-US", zone))).toBe("Tomorrow 3:00 AM");
    expect(plain(upcomingWhen(at("2026-11-20T17:50:00Z"), now, "en-US", zone))).toBe("Friday 9:50 AM");
    expect(plain(upcomingWhen(at("2026-11-25T17:50:00Z"), now, "en-US", zone))).toBe("Nov 25, 9:50 AM");
    expect(plain(upcomingWhen(at("2027-01-05T17:50:00Z"), now, "en-US", zone))).toBe("Jan 5, 2027, 9:50 AM");
    expect(plain(upcomingWhen(at("2026-11-19T07:30:00Z"), now, "en-US", "Asia/Tokyo"))).toBe("Today 4:30 PM");
    expect(upcomingWhen(undefined, now)).toBe("");
    expect(plain(upcomingMeta(item("a", { nextRunAt: at("2026-11-19T06:35:00Z") }), now, "en-US", zone))).toBe("Today 10:35 PM · Once · Kitchen tab");
    expect(upcomingMeta(ITEMS[9], now, "en-US", zone)).toBe("Every 15 minutes · This Mac");
    expect(upcomingMeta(item("b", { schedule: "Cantrip Home", owner: "Cantrip Home" }), now)).toBe("Cantrip Home");
  });

  it("keeps Upcoming's count showing while expanded", () => {
    expect(sectionCount(12, false, true)).toBe("· 12");
    expect(sectionCount(12, false)).toBe("");
  });
});
