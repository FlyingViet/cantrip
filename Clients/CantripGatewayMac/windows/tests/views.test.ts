import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The card renderer, kit and Home state touch the page and the preload bridge when they load.
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
const opened = vi.hoisted(() => [] as string[]);
vi.mock("../src/gateway/bridge", () => ({
  bridge: {
    key: "gateway-key", version: "test", platform: "win32", server: "", focused: true,
    status: { connected: true, route: "", message: "", server: "" },
    openSettings() {}, openExternal(url: string) { opened.push(url); }, showLog() {}, onStatus() {}, onCommand() {}, onActive() {},
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

import { api } from "../src/gateway/api/client";
import type { HomeTasksSnapshot, RemoteCardBlock, RemoteCardDocument } from "../src/gateway/api/types";
import * as nav from "../src/gateway/state/nav";
import * as remote from "../src/gateway/state/remote";
import {
  parseView, parseViews, supportsViews, viewActionOutcome, viewActionPath, viewPath, ViewPoller, viewsPath, viewSubtitle,
} from "../src/gateway/state/views";
import { listedViews } from "../src/gateway/ui/home/ViewsView";
import { deleteView, openView, refreshView, setViewPinned, showView, viewActionHandler } from "../src/gateway/ui/home/viewsState";
import * as tasksNav from "../src/gateway/ui/home/tasksNav";
import { confirmDialog, toast } from "../src/gateway/ui/kit";
import { CardView } from "../src/gateway/ui/transcript/Cards";
import { cardButtons, cardParts, cardTable, lineChart, pieSlices, VIEW_ACTION_KINDS, type CardPart } from "../src/gateway/ui/transcript/cardLogic";

const apiMock = vi.mocked(api);
const confirmMock = vi.mocked(confirmDialog);

// MARK: A small VNode walker (no DOM): components are called with their props, like a shallow render.

interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function isVNode(value: unknown): value is VNode {
  return typeof value === "object" && value !== null && "type" in value && "props" in value;
}

function render(value: unknown): Node[] {
  if (value == null || typeof value === "boolean") return [];
  if (Array.isArray(value)) return value.flatMap(render);
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (!isVNode(value)) return [];
  if (typeof value.type === "function") return render((value.type as (props: unknown) => unknown)(value.props));
  const { children, ...props } = value.props;
  return [{ tag: String(value.type), props, children: render(children) }];
}

function text(nodes: Node[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
}

function elements(nodes: Node[]): Element[] {
  return nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
}

function find(nodes: Node[], test: (element: Element) => boolean): Element[] {
  return elements(nodes).filter(test);
}

const role = (name: string) => (element: Element) => element.props.role === name;
const tag = (name: string) => (element: Element) => element.tag === name;

const card = (blocks: RemoteCardBlock[], extra: Partial<RemoteCardDocument> = {}): RemoteCardDocument =>
  ({ version: 1, id: "view-lab", type: "view", source: { kind: "view", name: "Lab" }, blocks, ...extra });
const stat = (label: string): RemoteCardBlock => ({ type: "stat", label, value: "1" });
const blockTypes = (parts: CardPart[]) => parts.map((part) => (part.kind === "block" ? part.block.type : part.kind));

const TASKS: HomeTasksSnapshot = { tasks: [], revision: "t1", supportsReordering: true, supportsViews: true };
const VIEW = { id: "V1", name: "Homelab", icon: "server.rack", pinned: false, private: false, sources: ["tool"],
  createdAt: "2026-11-17T20:00:00Z", updatedAt: "2026-11-17T20:00:00Z", refreshedAt: "2026-11-17T21:15:00Z" };
const VIEW_CARD = card([
  { type: "header", title: "Homelab" },
  { type: "actions", buttons: [
    { id: "a1", kind: "refresh", label: "Refresh", confirmTitle: "Refresh Homelab?", confirmMessage: "Reads the view's sources again." },
    { id: "a2", kind: "open", label: "Open dashboard", style: "prominent", confirmTitle: "Open the dashboard?" },
    { id: "a3", kind: "deleteEverything", label: "Nope", confirmTitle: "?" },
  ] },
]);

beforeEach(() => {
  apiMock.mockReset();
  confirmMock.mockReset();
  vi.mocked(toast).mockReset();
  opened.length = 0;
});

afterEach(() => {
  remote.homeTasks.value = null;
  remote.homeViews.value = null;
  openView.value = null;
  tasksNav.route.value = { kind: "list" };
});

describe("view card blocks: grouping", () => {
  it("gives each tab the next `count` blocks in turn, counting blocks it skips", () => {
    const parts = cardParts(card([
      { type: "header", title: "This week" },
      { type: "tabs", tabs: [{ title: "Jobs", count: 3 }, { title: "Bills", count: 1 }] },
      stat("Applied"), { type: "someFutureBlock" }, stat("Onsite"),
      stat("Due"),
      { type: "notice", title: "After the tabs" },
    ]));
    expect(blockTypes(parts)).toEqual(["header", "tabs", "notice"]);
    const tabs = parts[1] as Extract<CardPart, { kind: "tabs" }>;
    expect(tabs.tabs.map((tab) => tab.title)).toEqual(["Jobs", "Bills"]);
    expect(tabs.tabs[0].parts.map((part) => (part as { block: RemoteCardBlock }).block.label)).toEqual(["Applied", "Onsite"]);
    expect(tabs.tabs[1].parts.map((part) => (part as { block: RemoteCardBlock }).block.label)).toEqual(["Due"]);
  });

  it("clamps counts that run past the end, and a link card shows every block in order", () => {
    const blocks: RemoteCardBlock[] = [{ type: "tabs", tabs: [{ title: "A", count: 1 }, { title: "B", count: 9 }, { title: "C", count: 4 }] },
      stat("one"), stat("two"), stat("three")];
    const [tabs] = cardParts(card(blocks)) as Extract<CardPart, { kind: "tabs" }>[];
    expect(tabs.tabs.map((tab) => tab.parts.length)).toEqual([1, 2, 0]);
    expect(blockTypes(cardParts(card(blocks, { style: "link" })))).toEqual(["block", "block", "block"].map(() => "stat"));
  });

  it("draws an actions block only for a view, with only the kinds it knows", () => {
    expect(blockTypes(cardParts(VIEW_CARD))).toEqual(["header"]);
    const parts = cardParts(VIEW_CARD, { actionKinds: VIEW_ACTION_KINDS });
    expect(blockTypes(parts)).toEqual(["header", "actions"]);
    expect(cardButtons(VIEW_CARD.blocks[1]).map((button) => button.id)).toEqual(["a1", "a2"]);
    expect(cardButtons(VIEW_CARD.blocks[1], new Set(["refresh"])).map((button) => button.id)).toEqual(["a1"]);
    const onlyUnknown = card([{ type: "actions", buttons: [{ id: "x", kind: "launchRockets", label: "Go" }] }]);
    expect(cardParts(onlyUnknown, { actionKinds: VIEW_ACTION_KINDS })).toEqual([]);
  });

  it("draws at most 48 blocks", () => {
    const parts = cardParts(card(Array.from({ length: 60 }, (_, index) => stat(`S${index}`))));
    expect(parts).toHaveLength(48);
  });
});

describe("view card blocks: data", () => {
  it("pads table rows to the columns and reads each row's label", () => {
    const table = cardTable({
      type: "table", title: "Services",
      columns: [{ title: "Service" }, { title: "Status", align: "center" }, { title: "Version", align: "trailing" }],
      tableRows: [
        { id: "grafana", cells: [{ text: "Grafana" }, { text: "Up", tone: "positive" }, { text: "11.2" }], accessibilityLabel: "Grafana, Up, version 11.2" },
        { cells: [{ text: "Router" }, { text: "Down", tone: "angry" }] },
      ],
    })!;
    expect(table.columns.map((column) => column.align)).toEqual(["leading", "center", "trailing"]);
    expect(table.rows[0]).toMatchObject({ key: "grafana", label: "Grafana, Up, version 11.2" });
    expect(table.rows[1].cells.map((cell) => cell.text)).toEqual(["Router", "Down", ""]);
    expect(table.rows[1].cells[1].tone).toBeUndefined();
    expect(table.rows[1].label).toBe("Service: Router, Status: Down");
    expect(cardTable({ type: "table", columns: [{ title: "A" }], tableRows: [] })).toBeNull();
  });

  it("puts line points on the min…max scale (widened to every point) and labels the first, middle and last", () => {
    const chart = lineChart({
      type: "chart", kind: "line", min: 0, max: 10,
      items: [{ label: "Mon", high: 0 }, { label: "Tue", high: 5, highText: "5 runs" }, { label: "Wed", high: 10 }, { label: "Thu", high: 20 },
        { label: "Fri", high: 2, accessibilityLabel: "Friday, 2" }],
    }, 100, 50);
    expect([chart.min, chart.max]).toEqual([0, 20]);
    expect(chart.points.map((point) => [point.x, point.y])).toEqual([[0, 50], [25, 37.5], [50, 25], [75, 0], [100, 45]]);
    expect(chart.labelled).toEqual([0, 2, 4]);
    expect(chart.points[1].spoken).toBe("Tue, 5 runs");
    expect(chart.points[4].spoken).toBe("Friday, 2");
    expect(lineChart({ type: "chart", kind: "line", items: [{ label: "Only", high: 3 }] }, 100, 50).labelled).toEqual([0]);
  });

  it("works out each pie slice's share and color, leaving out items with nothing to share", () => {
    const slices = pieSlices({
      type: "chart", kind: "pie", items: [
        { label: "Applied", high: 6, highText: "6" }, { label: "Ghosted", high: 0 }, { label: "Onsite", high: 3, tone: "positive" },
        { label: "Offer", high: 1, accessibilityLabel: "Offer, one" },
      ],
    });
    expect(slices.map((slice) => slice.label)).toEqual(["Applied", "Onsite", "Offer"]);
    expect(slices.map((slice) => slice.percent)).toEqual(["60%", "30%", "10%"]);
    // The palette goes by the item's place, so Offer (the fourth item) is purple.
    expect(slices.map((slice) => slice.color)).toEqual(["#4C9DFF", "#34d399", "#AF52DE"]);
    expect(slices.map((slice) => slice.start)).toEqual([0, 0.6, 0.9]);
    expect(slices.map((slice) => slice.spoken)).toEqual(["Applied, 6, 60%", "Onsite, 30%", "Offer, one, 10%"]);
    expect(pieSlices({ type: "chart", kind: "pie", items: [{ label: "None", high: 0 }] })).toEqual([]);
    const sliver = pieSlices({ type: "chart", kind: "pie", items: [{ label: "Big", high: 999 }, { label: "Tiny", high: 1 }] });
    expect(sliver.map((slice) => slice.percent)).toEqual(["100%", "<1%"]);
  });
});

describe("view card blocks: rendering", () => {
  it("draws a table with column headers, row labels, tones and a scrolling region", () => {
    const nodes = render(CardView({ card: card([{ type: "table", title: "Services", columns: [{ title: "Service" }, { title: "Up", align: "trailing" }],
      tableRows: [{ id: "a", cells: [{ text: "Grafana" }, { text: "Yes", tone: "positive" }], accessibilityLabel: "Grafana is up" }] }]) }));
    const region = find(nodes, role("region"))[0];
    expect(region.props).toMatchObject({ "aria-label": "Services", tabIndex: 0, class: "card-table-scroll" });
    const headers = find(nodes, tag("th"));
    expect(headers.map((th) => [th.props.scope, text([th])])).toEqual([["col", "Service"], ["col", "Up"]]);
    const row = find(nodes, (element) => element.tag === "tr" && element.props["aria-label"] !== undefined)[0];
    expect(row.props["aria-label"]).toBe("Grafana is up");
    expect(find([row], tag("td")).map((td) => td.props.class)).toEqual(["align-leading", "align-trailing tone-positive"]);
    expect(find(nodes, tag("table"))).toHaveLength(1);
  });

  it("draws tabs as a tablist and shows only the selected tab's blocks", () => {
    const tabsCard = card([{ type: "tabs", tabs: [{ title: "Week", count: 1 }, { title: "Month", count: 1 }] },
      { type: "stat", label: "This week", value: "3" }, { type: "stat", label: "This month", value: "12" }], { id: "view-tabs" });
    let nodes = render(CardView({ card: tabsCard }));
    const tabs = find(nodes, role("tab"));
    expect(find(nodes, role("tablist"))).toHaveLength(1);
    expect(tabs.map((tab) => [text([tab]), tab.props["aria-selected"], tab.props.tabIndex])).toEqual([["Week", true, 0], ["Month", false, -1]]);
    const panels = () => find(nodes, role("tabpanel")).map((panel) => [panel.props.hidden, text([panel])]);
    expect(panels()).toEqual([[false, "This week3"], [true, ""]]);
    expect(tabs[0].props["aria-controls"]).toBe(find(nodes, role("tabpanel"))[0].props.id);

    (tabs[1].props.onClick as () => void)();
    nodes = render(CardView({ card: tabsCard }));
    expect(panels()).toEqual([[true, ""], [false, "This month12"]]);
    expect(find(nodes, role("tab")).map((tab) => tab.props["aria-selected"])).toEqual([false, true]);
  });

  it("draws a pie's legend with each share and a line's points as labelled stops", () => {
    const nodes = render(CardView({ card: card([
      { type: "chart", kind: "pie", title: "Stages", items: [{ label: "Applied", high: 3, highText: "3" }, { label: "Onsite", high: 1, highText: "1" }] },
      { type: "chart", kind: "line", title: "Runs", min: 0, max: 4, items: [{ label: "Mon", high: 1, highText: "1" }, { label: "Tue", high: 4, highText: "4" }] },
    ]) }));
    expect(find(nodes, (element) => element.props.class === "card-pie-row").map((row) => row.props["aria-label"]))
      .toEqual(["Applied, 3, 75%", "Onsite, 1, 25%"]);
    expect(find(nodes, (element) => element.props.class === "card-block-title").map((title) => text([title]))).toEqual(["Stages", "Runs"]);
    const dots = find(nodes, (element) => element.props.class === "card-linechart-dot");
    expect(dots.map((dot) => [dot.props["aria-label"], dot.props.tabIndex])).toEqual([["Mon, 1", 0], ["Tue, 4", 0]]);
  });

  it("shows no actions in a chat reply's card", () => {
    expect(find(render(CardView({ card: VIEW_CARD })), (element) => element.tag === "button")).toEqual([]);
  });
});

describe("view actions", () => {
  const buttons = (onAction: (button: { id: string }) => unknown) =>
    find(render(CardView({ card: VIEW_CARD, onAction })), (element) => element.tag === "button");

  it("hides kinds it doesn't know and asks before running a button", async () => {
    const onAction = vi.fn();
    const shown = buttons(onAction);
    expect(shown.map((button) => [text([button]), button.props.class])).toEqual([
      ["Refresh", "card-view-action"], ["Open dashboard", "card-view-action prominent"],
    ]);
    confirmMock.mockResolvedValueOnce(false);
    (shown[0].props.onClick as () => void)();
    await vi.waitFor(() => expect(confirmMock).toHaveBeenCalledTimes(1));
    expect(confirmMock).toHaveBeenCalledWith({ title: "Refresh Homelab?", message: "Reads the view's sources again.", confirm: "Refresh", cancel: "Cancel" });
    await Promise.resolve();
    expect(onAction).not.toHaveBeenCalled();

    confirmMock.mockResolvedValueOnce(true);
    (shown[1].props.onClick as () => void)();
    await vi.waitFor(() => expect(onAction).toHaveBeenCalledTimes(1));
    expect(onAction.mock.calls[0][0]).toMatchObject({ id: "a2", kind: "open" });
  });

  it("posts {confirmed: true} to the view's action only after the user confirms", async () => {
    remote.homeTasks.value = TASKS;
    let confirm!: (value: boolean) => void;
    confirmMock.mockImplementationOnce(() => new Promise((resolve) => { confirm = resolve; }));
    apiMock.mockResolvedValueOnce({ result: "open", url: "https://dashboard.example.com/lab" });
    const shown = buttons(viewActionHandler("V1"));
    (shown[1].props.onClick as () => void)();
    await vi.waitFor(() => expect(confirmMock).toHaveBeenCalled());
    expect(apiMock).not.toHaveBeenCalled();
    confirm(true);
    await vi.waitFor(() => expect(opened).toEqual(["https://dashboard.example.com/lab"]));
    expect(apiMock).toHaveBeenCalledTimes(1);
    expect(apiMock).toHaveBeenCalledWith("/api/v1/home/views/V1/actions/a2", { method: "POST", body: { confirmed: true } });
  });

  it("never posts when the user cancels", async () => {
    confirmMock.mockResolvedValue(false);
    const shown = buttons(viewActionHandler("V1"));
    for (const button of shown) (button.props.onClick as () => void)();
    await vi.waitFor(() => expect(confirmMock).toHaveBeenCalledTimes(2));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("does what each result asks", async () => {
    remote.homeTasks.value = {
      ...TASKS, tasks: [{ id: "T1", title: "Jobs", workspace: { records: [{ id: "R1", values: {} }] } } as never],
    };
    showView("V1");
    const handler = viewActionHandler("V1");
    const run = async (answer: unknown) => {
      apiMock.mockResolvedValueOnce(answer);
      await handler({ id: "x", kind: "runTask", label: "Run", prominent: false, confirmTitle: "Run?" });
    };
    await run({ result: "started", message: "Jobs will run now." });
    expect(toast).toHaveBeenCalledWith("Jobs will run now.");
    await run({ result: "record", taskID: "T1", recordID: "R1" });
    expect(tasksNav.route.value).toEqual({ kind: "record", taskID: "T1", recordID: "R1", fromView: "V1" });
    tasksNav.back();
    expect(tasksNav.route.value).toEqual({ kind: "view", viewID: "V1" });
    await run({ result: "refreshed", view: VIEW, card: VIEW_CARD, refreshAfter: 30 });
    expect(openView.value?.shown?.card).toEqual(VIEW_CARD);
    expect(openView.value?.shown?.refreshMs).toBe(30_000);
    nav.section.value = "tasks";
    await run({ result: "sent", message: "Asked Home." });
    expect(nav.section.value).toBe("chat");
    await run({ result: "open", url: "javascript:alert(1)" });
    expect(opened).toEqual([]);
    expect(openView.value?.error).toMatch(/can't open/);
  });
});

// Real host output: views the Mac's resolver built from live homelab status and tracker record counts.
const fixture = (name: string) => JSON.parse(readFileSync(new URL(`./fixtures/views/${name}.json`, import.meta.url), "utf8"));

describe("views from the Mac", () => {
  it("draws the This week view: tabs over their blocks, then its buttons", () => {
    const shown = parseView(fixture("view-dashboard"));
    expect(shown.refreshMs).toBe(30_000);
    const parts = cardParts(shown.card, { actionKinds: VIEW_ACTION_KINDS });
    expect(blockTypes(parts)).toEqual(["header", "tabs", "actions"]);
    const tabs = (parts[1] as Extract<CardPart, { kind: "tabs" }>).tabs;
    expect(tabs.map((tab) => [tab.title, blockTypes(tab.parts)])).toEqual([
      ["Overview", ["stat", "keyValue", "table"]], ["Interviews", ["chart", "chart"]], ["Bills", ["chart"]],
    ]);
    const [pie, line] = tabs[1].parts.map((part) => (part as { block: RemoteCardBlock }).block);
    expect(pieSlices(pie).map((slice) => [slice.label, slice.percent, slice.spoken])).toEqual([
      ["Applied", "41%", "Applied, 9, 41 percent"], ["Recruiter screen complete", "9%", "Recruiter screen complete, 2, 9 percent"],
      ["Interviewing", "14%", "Interviewing, 3, 14 percent"], ["Final round", "5%", "Final round, 1, 5 percent"],
      ["Offer", "5%", "Offer, 1, 5 percent"], ["Rejected", "27%", "Rejected, 6, 27 percent"],
    ]);
    const chart = lineChart(line, 100, 100);
    expect(chart.labelled.map((index) => chart.points[index].label)).toEqual(["Mon, Oct 5", "Thu, Oct 15", "Thu, Oct 29"]);

    const nodes = render(CardView({ card: shown.card, onAction: () => {} }));
    expect(find(nodes, role("tab")).map((tab) => text([tab]))).toEqual(["Overview", "Interviews", "Bills"]);
    expect(find(nodes, tag("tr")).length).toBe(5);
    expect(find(nodes, (element) => element.tag === "button" && element.props["data-kind"] !== undefined).map((button) => text([button])))
      .toEqual(["Run interview tracker", "Summarize my week"]);
  });

  it("draws the Homelab view: a section heading over its table, and a Refresh button", () => {
    const shown = parseView(fixture("view-homelab"));
    expect(shown.view).toMatchObject({ name: "Homelab", private: true, pinned: true });
    const parts = cardParts(shown.card, { actionKinds: VIEW_ACTION_KINDS });
    expect(parts.map((part) => [blockTypes([part])[0], part.divided])).toEqual([
      ["header", false], ["stat", false], ["section", true], ["table", false], ["keyValue", true], ["actions", false],
    ]);
    const table = cardTable((parts[3] as { block: RemoteCardBlock }).block)!;
    expect(table.rows.map((row) => row.label)).toEqual([
      "Grafana, Status Up, Version 11.2.0", "NAS, Status Up, Version —", "Router, Status Down, Version 4.1.3",
    ]);
    expect(cardButtons((parts[5] as { block: RemoteCardBlock }).block)).toEqual([{
      id: "a1", kind: "refresh", label: "Refresh", symbol: "arrow.clockwise", prominent: true,
      confirmTitle: "Refresh Homelab?", confirmMessage: "Cantrip reads this view's sources again.",
    }]);
  });

  it("lists the views pinned first with their subtitles", () => {
    const list = parseViews(fixture("views-list"));
    expect(list.unchanged ? null : list.views.map((view) => [view.name, view.pinned, view.private, viewSubtitle(view)])).toEqual([
      ["Homelab", true, true, "Service health"], ["This week", true, false, "Across the trackers"],
    ]);
  });
});

describe("views API", () => {
  it("builds every Views path", () => {
    expect(viewsPath()).toBe("/api/v1/home/views");
    expect(viewsPath("r 7")).toBe("/api/v1/home/views?revision=r%207");
    expect(viewPath("V/1")).toBe("/api/v1/home/views/V%2F1");
    expect(viewPath("V1", "refresh")).toBe("/api/v1/home/views/V1/refresh");
    expect(viewPath("V1", "pin")).toBe("/api/v1/home/views/V1/pin");
    expect(viewActionPath("V1", "a?b")).toBe("/api/v1/home/views/V1/actions/a%3Fb");
  });

  it("refreshes, pins and deletes through the Mac", async () => {
    remote.homeTasks.value = TASKS;
    remote.homeViews.value = [VIEW, { ...VIEW, id: "V2", name: "Week" }];
    showView("V1");
    apiMock.mockResolvedValueOnce({ view: VIEW, card: VIEW_CARD, refreshAfter: 30 });
    expect(await refreshView("V1")).toBe(true);
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/views/V1/refresh", { method: "POST" });
    expect(openView.value?.shown?.view.name).toBe("Homelab");

    apiMock.mockResolvedValueOnce({ ...VIEW, id: "V2", name: "Week", pinned: true }).mockResolvedValueOnce({ unchanged: true, revision: "r1" });
    expect(await setViewPinned({ ...VIEW, id: "V2", name: "Week" }, true)).toBe(true);
    expect(apiMock).toHaveBeenNthCalledWith(2, "/api/v1/home/views/V2/pin", { method: "POST", body: { pinned: true } });
    expect(remote.homeViews.value?.map((view) => [view.id, view.pinned])).toEqual([["V2", true], ["V1", false]]);

    apiMock.mockResolvedValueOnce({ deleted: true }).mockResolvedValueOnce({ unchanged: true, revision: "r1" });
    expect(await deleteView(VIEW)).toBe(true);
    expect(apiMock).toHaveBeenNthCalledWith(4, "/api/v1/home/views/V1", { method: "DELETE" });
    expect(remote.homeViews.value?.map((view) => view.id)).toEqual(["V2"]);
    expect(openView.value).toBeNull();
  });

  it("reads list and view answers leniently", () => {
    const list = parseViews({ revision: "r2", views: [VIEW, { ...VIEW, id: "V3", pinned: true }, { id: 4 }, null] });
    expect(list).toMatchObject({ unchanged: false, revision: "r2" });
    expect(list.unchanged ? [] : list.views.map((view) => view.id)).toEqual(["V3", "V1"]);
    expect(parseViews({ unchanged: true, revision: "r2" })).toEqual({ unchanged: true, revision: "r2" });
    expect(() => parseView({ view: VIEW })).toThrow();
    expect(parseView({ view: VIEW, card: VIEW_CARD }).refreshMs).toBe(60_000);
    expect(parseView({ view: VIEW, card: VIEW_CARD, refreshAfter: 1 }).refreshMs).toBe(10_000);
    expect(viewActionOutcome({ result: "launch" }).kind).toBe("unknown");
    expect(viewSubtitle({ ...VIEW, subtitle: "Every service" })).toBe("Every service");
    expect(viewSubtitle(VIEW, new Date("2026-11-17T22:00:00Z"), "en-US")).toMatch(/^Updated \d{1,2}:15/);
  });

  it("fetches an open view again every refreshAfter seconds until it closes", async () => {
    const pending: { callback: () => void; ms: number }[] = [];
    const timers = { set: (callback: () => void, ms: number) => pending.push({ callback, ms }), clear: vi.fn() };
    const load = vi.fn().mockResolvedValue({ view: VIEW, card: VIEW_CARD, refreshAfter: 45 });
    const onView = vi.fn();
    const poller = new ViewPoller({ load, onView, timers });
    poller.start();
    await vi.waitFor(() => expect(pending).toHaveLength(1));
    expect(pending[0].ms).toBe(45_000);
    pending[0].callback();
    await vi.waitFor(() => expect(onView).toHaveBeenCalledTimes(2));
    poller.stop();
    expect(timers.clear).toHaveBeenCalled();
    expect(load).toHaveBeenCalledTimes(2);
  });
});

describe("views gating", () => {
  it("lists views only when the tasks snapshot says supportsViews", async () => {
    remote.homeTasks.value = { ...TASKS, supportsViews: undefined };
    remote.homeViews.value = [VIEW];
    expect(supportsViews(remote.homeTasks.value)).toBe(false);
    expect(listedViews()).toEqual([]);
    await remote.refreshViews();
    expect(apiMock).not.toHaveBeenCalled();
    expect(remote.homeViews.value).toBeNull();

    remote.homeTasks.value = TASKS;
    apiMock.mockResolvedValueOnce({ views: [VIEW], revision: "r1", supportsViewActions: true });
    await remote.refreshViews();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/views");
    expect(listedViews().map((view) => view.id)).toEqual(["V1"]);
    apiMock.mockResolvedValueOnce({ unchanged: true, revision: "r1" });
    await remote.refreshViews();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/views?revision=r1");
    expect(listedViews().map((view) => view.id)).toEqual(["V1"]);
  });
});
