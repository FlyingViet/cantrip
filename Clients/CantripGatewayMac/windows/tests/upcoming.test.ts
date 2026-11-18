import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Home state, the kit and the card renderer touch the page and the preload bridge when they load.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  const stored = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: { getItem: (key: string) => stored.get(key) ?? null, setItem: (key: string, value: string) => void stored.set(key, value), removeItem: (key: string) => void stored.delete(key) },
  });
  scope.document = { addEventListener: noop, removeEventListener: noop, visibilityState: "visible" };
  scope.window = scope;
  scope.addEventListener = noop;
  scope.removeEventListener = noop;
});
vi.mock("../src/gateway/bridge", () => ({
  bridge: {
    key: "gateway-key", version: "test", platform: "win32", server: "", focused: true,
    status: { connected: true, route: "", message: "", server: "" },
    openSettings() {}, openExternal() {}, showLog() {}, onStatus() {}, onCommand() {}, onActive() {},
  },
  isWindows: true,
  primaryKeyLabel: "Ctrl+",
  shortcut: (keys: string) => keys,
}));
vi.mock("../src/gateway/api/client", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/gateway/api/client")>()),
  api: vi.fn(),
}));
vi.mock("../src/gateway/ui/kit", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/gateway/ui/kit")>()),
  confirmDialog: vi.fn(),
  toast: vi.fn(),
}));

import { api, APIError } from "../src/gateway/api/client";
import type { HomeUpcomingItem } from "../src/gateway/api/types";
import * as remote from "../src/gateway/state/remote";
import {
  parseUpcoming, upcomingAction, upcomingActionRequest, upcomingMeta, upcomingPath, upcomingQuestion, upcomingSections, upcomingWhen,
} from "../src/gateway/state/upcoming";
import * as tasksNav from "../src/gateway/ui/home/tasksNav";
import { runUpcomingAction, showAllUpcoming, upcomingActionError, UpcomingSection } from "../src/gateway/ui/home/UpcomingView";
import { confirmDialog, toast } from "../src/gateway/ui/kit";

const apiMock = vi.mocked(api);
const confirmMock = vi.mocked(confirmDialog);
const toastMock = vi.mocked(toast);

// A small VNode walker (no DOM): components are called with their props, like a shallow render.
interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function render(value: unknown): Node[] {
  if (value == null || typeof value === "boolean") return [];
  if (Array.isArray(value)) return value.flatMap(render);
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (typeof value !== "object" || !("type" in value) || !("props" in value)) return [];
  const node = value as VNode;
  if (typeof node.type === "function") return render((node.type as (props: unknown) => unknown)(node.props));
  const { children, ...props } = node.props;
  return [{ tag: String(node.type), props, children: render(children) }];
}
const text = (nodes: Node[]): string => nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
const elements = (nodes: Node[]): Element[] => nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
const find = (nodes: Node[], test: (element: Element) => boolean): Element[] => elements(nodes).filter(test);
const withClass = (name: string) => (element: Element) => String(element.props.class ?? "").split(" ").includes(name);

// Synthetic items in the Mac's shape and order.
const SOON = Date.now() / 1000 + 3600;
const item = (id: string, extra: Partial<HomeUpcomingItem> = {}): HomeUpcomingItem => ({
  id, kind: "step", title: `Item ${id}`, schedule: "Once", owner: "Kitchen tab", state: "scheduled", group: "next", canResume: false, ...extra,
});
const ITEMS: HomeUpcomingItem[] = [
  ...Array.from({ length: 8 }, (_, index) => item(`step:S${index}`, {
    title: `Synthetic step ${index}`, nextRunAt: SOON + index * 600, cancelLabel: "Cancel",
    confirm: `Cancel “Synthetic step ${index}”? The Kitchen tab won't get this step.`, ...(index === 0 ? { detail: "Once the oven is free" } : {}),
  })),
  item("wait:W1", { kind: "wait", title: "Wait for the laptop", group: "waiting", state: "waiting", schedule: "Waiting, until Fri Nov 20, 9:50 AM",
    cancelLabel: "Stop", confirm: "Stop “Wait for the laptop”? It won't do what it was waiting to do." }),
  item("mac:com.example.backup", { kind: "macJob", title: "Example backup", group: "repeating", schedule: "Every 15 minutes", owner: "This Mac",
    cancelLabel: "Pause", confirm: "Pause “Example backup”?" }),
  item("task:T1", { kind: "task", title: "Synthetic tracker", group: "paused", state: "paused", schedule: "Every day at 8:00 AM", owner: "Cantrip Home", canResume: true }),
];

beforeEach(() => {
  apiMock.mockReset();
  confirmMock.mockReset();
  toastMock.mockReset();
});

afterEach(() => {
  remote.reset();
  showAllUpcoming.value = false;
  upcomingActionError.value = null;
  localStorage.removeItem("cantrip.home.upcoming.collapsed");
  vi.useRealTimers();
});

describe("upcoming API", () => {
  it("builds the list, cancel and resume requests", () => {
    expect(upcomingPath()).toBe("/api/v1/home/upcoming");
    expect(upcomingPath("r 7")).toBe("/api/v1/home/upcoming?revision=r%207");
    expect(upcomingActionRequest("cancel", "step:A/1")).toEqual({ path: "/api/v1/home/upcoming/cancel", body: { id: "step:A/1" } });
    expect(upcomingActionRequest("resume", "mac:com.example.job")).toEqual({ path: "/api/v1/home/upcoming/resume", body: { id: "mac:com.example.job" } });
  });

  it("reads answers leniently", () => {
    const parsed = parseUpcoming({ revision: "r1", message: "Paused “X”.", items: [ITEMS[0], { title: "no id" }, null, { id: "x", nextRunAt: "soon", canResume: "yes" }] });
    expect(parsed).toMatchObject({ unchanged: false, revision: "r1", message: "Paused “X”." });
    const items = parsed.unchanged ? [] : parsed.items;
    expect(items.map((entry) => entry.id)).toEqual(["step:S0", "x"]);
    expect(items[1]).toMatchObject({ title: "Untitled", group: "next", nextRunAt: undefined, canResume: false });
    expect(parseUpcoming({ unchanged: true, revision: "r1" })).toEqual({ unchanged: true, revision: "r1" });
    expect(() => parseUpcoming({ revision: "r1" })).toThrow();
  });
});

describe("upcoming rows", () => {
  // Wednesday, Nov 18 2026, 9:56 AM in Los Angeles.
  const now = new Date("2026-11-18T17:56:00Z");
  const zone = "America/Los_Angeles";
  const at = (iso: string) => new Date(iso).getTime() / 1000;

  it("says when relative to the viewer's today", () => {
    // ICU versions differ in the space before AM/PM (some use a narrow no-break space).
    const when = (iso: string, locale = "en-US", timeZone = zone) => upcomingWhen(at(iso), now, locale, timeZone).replace(/[\u202f\u00a0]/g, " ");
    expect(when("2026-11-19T06:35:00Z")).toBe("Today 10:35 PM");
    expect(when("2026-11-19T11:00:00Z")).toBe("Tomorrow 3:00 AM");
    expect(when("2026-11-18T07:00:00Z")).toBe("Yesterday 11:00 PM");
    expect(when("2026-11-20T17:50:00Z")).toBe("Friday 9:50 AM");
    expect(when("2026-11-24T17:50:00Z")).toBe("Tuesday 9:50 AM");
    expect(when("2026-11-25T17:50:00Z")).toBe("Nov 25, 9:50 AM");
    expect(when("2027-01-05T17:50:00Z")).toBe("Jan 5, 2027, 9:50 AM");
    // The same moment is today in Tokyo; a 24-hour locale writes its own clock.
    expect(when("2026-11-19T07:30:00Z", "en-US", "Asia/Tokyo")).toBe("Today 4:30 PM");
    expect(when("2026-11-19T07:30:00Z", "en-GB", "Europe/London")).toMatch(/^Tomorrow 0?7:30$/);
    expect(upcomingWhen(undefined, now)).toBe("");
  });

  it("lists when, schedule and owner once each, and the right button", () => {
    expect(upcomingMeta({ ...ITEMS[0], nextRunAt: at("2026-11-19T06:35:00Z") }, now, "en-US", zone).replace(/[\u202f\u00a0]/g, " "))
      .toBe("Today 10:35 PM · Once · Kitchen tab");
    expect(upcomingMeta(ITEMS[9], now, "en-US", zone)).toBe("Every 15 minutes · This Mac");
    expect(upcomingMeta(item("x", { schedule: "Cantrip Home", owner: "Cantrip Home" }), now)).toBe("Cantrip Home");
    expect(ITEMS.map((entry) => upcomingAction(entry)?.label ?? "")).toEqual([...Array(8).fill("Cancel"), "Stop", "Pause", "Resume"]);
    expect(upcomingAction(item("x"))).toBeNull();
    expect(upcomingAction(ITEMS[10])).toEqual({ kind: "resume", label: "Resume" });
    expect(upcomingQuestion(ITEMS[8], "Stop")).toBe("Stop “Wait for the laptop”? It won't do what it was waiting to do.");
    expect(upcomingQuestion(item("x", { title: "Plain" }), "Cancel")).toBe("Cancel “Plain”?");
  });

  it("groups in order, hides empty groups and cuts Next up to 6 until Show all", () => {
    const shape = (showAll: boolean, items = ITEMS) => upcomingSections(items, showAll).map((section) => `${section.title}:${section.items.length}/${section.total}`);
    expect(shape(false)).toEqual(["Next up:6/8", "Waiting:1/1", "Repeating:1/1", "Paused:1/1"]);
    expect(shape(true)).toEqual(["Next up:8/8", "Waiting:1/1", "Repeating:1/1", "Paused:1/1"]);
    expect(shape(false, [item("a", { group: "paused" }), item("b", { group: "someday" })])).toEqual(["Next up:1/1", "Paused:1/1"]);
    expect(upcomingSections(ITEMS, false)[0].items.map((entry) => entry.id)).toEqual(ITEMS.slice(0, 6).map((entry) => entry.id));
    expect(upcomingSections([], false)).toEqual([]);
  });
});

describe("upcoming section", () => {
  const toggle = (nodes: Node[]) => find(nodes, withClass("hm-section-toggle"))[0];

  it("shows nothing until the Mac serves the list", () => {
    expect(UpcomingSection()).toBeNull();
  });

  it("draws the heading with its count, the groups, Show all and each row's button", () => {
    remote.homeUpcoming.value = ITEMS;
    let nodes = render(UpcomingSection());
    expect(toggle(nodes).props).toMatchObject({ "aria-expanded": "true", "aria-controls": "hm-upcoming-body", "aria-label": "Upcoming, 11 items" });
    expect(text([toggle(nodes)])).toBe("Upcoming· 11");
    expect(find(nodes, withClass("hm-upcoming-group-title")).map((title) => text([title]))).toEqual(["Next up", "Waiting", "Repeating", "Paused"]);
    const lists = find(nodes, withClass("hm-upcoming-list"));
    expect(lists[0].props["aria-labelledby"]).toBe("hm-upcoming-next");
    let rows = find(nodes, withClass("hm-upcoming-row"));
    expect(rows).toHaveLength(9);
    expect(text(find([rows[0]], withClass("hm-upcoming-title")))).toBe("Synthetic step 0");
    expect(text(find([rows[0]], withClass("hm-upcoming-meta")))).toMatch(/^(Today|Tomorrow) .+ · Once · Kitchen tab$/);
    expect(text(find([rows[0]], withClass("hm-upcoming-detail")))).toBe("Once the oven is free");
    expect(text(find([rows[7]], withClass("hm-upcoming-meta")))).toBe("Every 15 minutes · This Mac");
    const buttons = find(nodes, withClass("hm-upcoming-action"));
    expect(buttons.map((button) => text([button]))).toEqual([...Array(6).fill("Cancel"), "Stop", "Pause", "Resume"]);
    expect(buttons[0].props).toMatchObject({ "aria-label": "Cancel Synthetic step 0", "aria-haspopup": "dialog", "data-focus-key": "upcoming:step:S0" });
    expect(buttons[8].props["aria-haspopup"]).toBeUndefined();
    const more = find(nodes, withClass("hm-upcoming-more"))[0];
    expect(text([more])).toBe("Show all 8");
    expect(more.props["aria-label"]).toBe("Show all 8 in Next up");

    (more.props.onClick as () => void)();
    nodes = render(UpcomingSection());
    rows = find(nodes, withClass("hm-upcoming-row"));
    expect(rows).toHaveLength(11);
    expect(find(nodes, withClass("hm-upcoming-more"))).toHaveLength(0);
  });

  it("collapses, remembered on this PC, and says when nothing is scheduled", () => {
    remote.homeUpcoming.value = ITEMS;
    (toggle(render(UpcomingSection())).props.onClick as () => void)();
    expect(localStorage.getItem("cantrip.home.upcoming.collapsed")).toBe("1");
    let nodes = render(UpcomingSection());
    expect(toggle(nodes).props["aria-expanded"]).toBe("false");
    expect(find(nodes, (element) => element.props.id === "hm-upcoming-body")[0].props.hidden).toBe(true);
    expect(find(nodes, withClass("hm-upcoming-row"))).toHaveLength(0);
    tasksNav.setSectionCollapsed("upcoming", false);

    remote.homeUpcoming.value = [];
    nodes = render(UpcomingSection());
    expect(text(find(nodes, withClass("hm-upcoming-empty")))).toBe("Nothing scheduled");
    expect(toggle(nodes).props["aria-label"]).toBe("Upcoming, 0 items");
  });
});

describe("upcoming polling", () => {
  it("asks with the last revision and keeps the list when unchanged", async () => {
    apiMock.mockResolvedValueOnce({ items: ITEMS, revision: "u1" });
    await remote.refreshUpcoming();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/upcoming");
    expect(remote.homeUpcoming.value).toHaveLength(11);
    apiMock.mockResolvedValueOnce({ unchanged: true, revision: "u1" });
    await remote.refreshUpcoming();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/upcoming?revision=u1");
    expect(remote.homeUpcoming.value).toHaveLength(11);
  });

  it("polls with Home's data only while Tasks shows", async () => {
    apiMock.mockResolvedValue({ unchanged: true, revision: "x" });
    await remote.refreshHomeData();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/api/v1/home/upcoming"))).toBe(false);
    remote.setUpcomingWanted(true);
    await remote.refreshHomeData();
    remote.setUpcomingWanted(false);
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/api/v1/home/upcoming"))).toBe(true);
  });

  it("hides the section on a Mac without Upcoming and asks again only minutes later", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-11-18T18:00:00Z"));
    remote.homeUpcoming.value = ITEMS;
    apiMock.mockRejectedValueOnce(new APIError("not found", 404));
    await remote.refreshUpcoming();
    expect(remote.homeUpcoming.value).toBeNull();
    expect(remote.homeUpcomingError.value).toBeNull();
    await remote.refreshUpcoming();
    expect(apiMock).toHaveBeenCalledTimes(1);
    vi.setSystemTime(new Date("2026-11-18T18:06:00Z"));
    apiMock.mockResolvedValueOnce({ items: [], revision: "u0" });
    await remote.refreshUpcoming();
    expect(apiMock).toHaveBeenCalledTimes(2);
    expect(remote.homeUpcoming.value).toEqual([]);
  });

  it("reports other failures and keeps the last list", async () => {
    remote.homeUpcoming.value = ITEMS;
    apiMock.mockRejectedValueOnce(new APIError("The Mac didn't answer in time.", 0));
    await remote.refreshUpcoming();
    expect(remote.homeUpcoming.value).toHaveLength(11);
    expect(remote.homeUpcomingError.value).toBe("Couldn't load Upcoming: The Mac didn't answer in time.");
  });
});

describe("upcoming actions", () => {
  const answer = (items: HomeUpcomingItem[], message: string) => ({ items, revision: "after", message });

  it("asks before Cancel with the Mac's question, Cancel and Keep, and sends nothing on Keep", async () => {
    remote.homeUpcoming.value = ITEMS;
    confirmMock.mockResolvedValueOnce(false);
    expect(await runUpcomingAction(ITEMS[1])).toBe(false);
    expect(confirmMock).toHaveBeenCalledWith({
      title: "Cancel “Synthetic step 1”? The Kitchen tab won't get this step.", confirm: "Cancel", cancel: "Keep", destructive: true,
    });
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("posts the item's id once confirmed, replaces the list and shows the Mac's message", async () => {
    remote.homeUpcoming.value = ITEMS;
    confirmMock.mockResolvedValueOnce(true);
    const left = ITEMS.filter((entry) => entry.id !== "step:S1");
    apiMock.mockResolvedValueOnce(answer(left, "Cancelled “Synthetic step 1”."));
    expect(await runUpcomingAction(ITEMS[1])).toBe(true);
    expect(apiMock).toHaveBeenCalledWith("/api/v1/home/upcoming/cancel", { method: "POST", body: { id: "step:S1" } });
    expect(remote.homeUpcoming.value?.map((entry) => entry.id)).toEqual(left.map((entry) => entry.id));
    expect(toastMock).toHaveBeenCalledWith("Cancelled “Synthetic step 1”.");
    // The next poll asks with the answer's revision.
    apiMock.mockResolvedValueOnce({ unchanged: true, revision: "after" });
    await remote.refreshUpcoming();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/upcoming?revision=after");
  });

  it("asks before Stop and Pause too, with their own labels", async () => {
    remote.homeUpcoming.value = ITEMS;
    confirmMock.mockResolvedValue(false);
    await runUpcomingAction(ITEMS[8]);
    await runUpcomingAction(ITEMS[9]);
    expect(confirmMock.mock.calls.map(([options]) => [options.confirm, options.cancel])).toEqual([["Stop", "Keep"], ["Pause", "Keep"]]);
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("resumes at once", async () => {
    remote.homeUpcoming.value = ITEMS;
    const resumed = { ...ITEMS[10], group: "next", state: "scheduled", canResume: false, cancelLabel: "Pause" };
    apiMock.mockResolvedValueOnce(answer([resumed, ...ITEMS.slice(0, 10)], "Resumed “Synthetic tracker”."));
    expect(await runUpcomingAction(ITEMS[10])).toBe(true);
    expect(confirmMock).not.toHaveBeenCalled();
    expect(apiMock).toHaveBeenCalledWith("/api/v1/home/upcoming/resume", { method: "POST", body: { id: "task:T1" } });
    expect(remote.homeUpcoming.value?.[0]).toMatchObject({ id: "task:T1", cancelLabel: "Pause", canResume: false });
    expect(toastMock).toHaveBeenCalledWith("Resumed “Synthetic tracker”.");
  });

  it("shows the Mac's error in the section and keeps the list", async () => {
    remote.homeUpcoming.value = ITEMS;
    confirmMock.mockResolvedValueOnce(true);
    apiMock.mockRejectedValueOnce(new APIError("That step already ran.", 409));
    expect(await runUpcomingAction(ITEMS[0])).toBe(false);
    expect(upcomingActionError.value).toBe("Couldn't cancel “Synthetic step 0”: That step already ran.");
    expect(remote.homeUpcoming.value).toHaveLength(11);
    const nodes = render(UpcomingSection());
    expect(text(find(nodes, (element) => element.props.role === "alert"))).toContain("That step already ran.");
  });
});
