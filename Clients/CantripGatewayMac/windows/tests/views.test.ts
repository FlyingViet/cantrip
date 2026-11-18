import { readFileSync } from "node:fs";
import { h } from "preact";
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
  parseView, parseViews, supportsViews, ThumbnailLoader, thumbnailNeedsFetch, viewActionOutcome, viewActionPath, viewColumns, viewPath,
  ViewPoller, viewRowLabel, viewsPath, viewSubtitle, type CachedView,
} from "../src/gateway/state/views";
import { TasksHeading } from "../src/gateway/ui/home/TasksView";
import { listedViews, ViewPreview, ViewsSection, ViewTile, ViewTiles } from "../src/gateway/ui/home/ViewsView";
import {
  applyShown, deleteView, openView, refreshView, setViewPinned, showView, viewActionHandler, viewDetails,
} from "../src/gateway/ui/home/viewsState";
import * as tasksNav from "../src/gateway/ui/home/tasksNav";
import { confirmDialog, toast } from "../src/gateway/ui/kit";
import { CardView } from "../src/gateway/ui/transcript/Cards";
import {
  cardButtons, cardParts, cardTable, lineChart, pieSlices, previewBlocks, VIEW_ACTION_KINDS, type CardPart,
} from "../src/gateway/ui/transcript/cardLogic";

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
  // The grid measures itself and loads thumbnails with hooks: it stays a leaf here (its tiles are drawn on their own).
  if (typeof value.type === "function" && value.type.name === "ViewsGrid") return [{ tag: "ViewsGrid", props: value.props, children: [] }];
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

// MARK: The views grid (the views grid spec): columns, collapsing, thumbnails and their fetch policy

describe("views grid", () => {
  const shownOf = (name: string): CachedView => ({ shown: parseView(fixture(name)), fetchedAt: 1_000 });

  afterEach(() => {
    localStorage.removeItem("cantrip.home.views.collapsed");
    localStorage.removeItem("cantrip.home.tasks.collapsed");
    viewDetails.value = new Map();
  });

  it("fits as many columns as the width allows, 1 to 6", () => {
    const widths = [320, 375, 599, 600, 700, 1000, 1600, 2000];
    expect(widths.map(viewColumns)).toEqual([1, 2, 3, 2, 2, 4, 6, 6]);
    expect([0, -5, Number.NaN].map(viewColumns)).toEqual([1, 1, 1]);
    const tiles = render(ViewTiles({ views: [VIEW], columns: 4, compact: false, at: new Date(), preview: () => h("i", null) }));
    expect(find(tiles, tag("ul"))[0].props).toMatchObject({ class: "hm-view-grid", style: { gridTemplateColumns: "repeat(4, minmax(0, 1fr))" } });
    expect(find(render(ViewTiles({ views: [VIEW], columns: 1, compact: true, at: new Date(), preview: () => h("i", null) })), tag("ul"))[0].props.class)
      .toBe("hm-view-grid compact");
  });

  it("collapses Views and Tasks, remembering each on this PC", () => {
    remote.homeTasks.value = TASKS;
    remote.homeViews.value = [VIEW, { ...VIEW, id: "V2", name: "Week" }];
    const heading = (nodes: Node[]) => find(nodes, (element) => element.props.class === "hm-section-toggle")[0];

    let nodes = render(ViewsSection());
    expect(heading(nodes).props).toMatchObject({ "aria-expanded": "true", "aria-controls": "hm-views-body", "aria-label": "Views, 2 views" });
    expect(text([heading(nodes)])).toBe("Views");
    expect(find(nodes, (element) => element.props.id === "hm-views-body")[0].props.hidden).toBe(false);
    expect(find(nodes, tag("ViewsGrid"))).toHaveLength(1);

    (heading(nodes).props.onClick as () => void)();
    expect(localStorage.getItem("cantrip.home.views.collapsed")).toBe("1");
    nodes = render(ViewsSection());
    expect(heading(nodes).props).toMatchObject({ "aria-expanded": "false", "aria-label": "Views, 2 views" });
    expect(text([heading(nodes)])).toBe("Views· 2");
    expect(find(nodes, (element) => element.props.id === "hm-views-body")[0].props.hidden).toBe(true);
    expect(find(nodes, tag("ViewsGrid"))).toHaveLength(0);
    (heading(nodes).props.onClick as () => void)();
    expect(localStorage.getItem("cantrip.home.views.collapsed")).toBe("0");
    expect(tasksNav.sectionCollapsed("views")).toBe(false);

    // A flag stored earlier (another launch) is read back on the next render.
    localStorage.setItem("cantrip.home.tasks.collapsed", "1");
    expect(tasksNav.sectionCollapsed("tasks")).toBe(true);
    const tasks = heading(render(TasksHeading({ count: 1, collapsed: tasksNav.sectionCollapsed("tasks") })));
    expect(tasks.props).toMatchObject({ "aria-expanded": "false", "aria-controls": "hm-tasks-body", "aria-label": "Tasks, 1 task" });
    expect(text([tasks])).toBe("Tasks· 1");
    (tasks.props.onClick as () => void)();
    expect(localStorage.getItem("cantrip.home.tasks.collapsed")).toBe("0");
    expect(tasksNav.sectionCollapsed("views")).toBe(false);
  });

  it("previews the first tab's stats and charts of a flat card", () => {
    // Real resolved cards: This week's charts belong to its other tabs; Homelab's section is only a heading.
    expect(previewBlocks(shownOf("view-dashboard").shown.card).map((block) => [block.type, block.label])).toEqual([["stat", "Active interview loops"]]);
    expect(previewBlocks(shownOf("view-homelab").shown.card).map((block) => [block.type, block.label])).toEqual([["stat", "Services up"]]);

    const pie: RemoteCardBlock = { type: "chart", kind: "pie", title: "By stage", items: [{ label: "Applied", high: 4 }] };
    const bar: RemoteCardBlock = { type: "chart", kind: "bar", title: "By category", items: [{ label: "Rent", high: 2 }] };
    const picked = previewBlocks(card([
      { type: "header", title: "Pipeline" }, { type: "notice", title: "Heads up" }, { type: "badges", badges: [{ text: "New" }] },
      { type: "progress", label: "Reading" }, { type: "actions", buttons: [{ id: "a", kind: "refresh", label: "Refresh" }] },
      { type: "section", title: "Numbers" }, pie, stat("Loops"), bar, stat("Offers"), stat("Rejected"),
    ]));
    expect(picked).toEqual([pie, stat("Loops"), stat("Offers")]);

    // Tabs own the next `count` blocks each, nested tabs included; only the first tab's show.
    expect(previewBlocks(card([
      { type: "tabs", tabs: [{ title: "Now", count: 3 }, { title: "Later", count: 2 }] },
      { type: "tabs", tabs: [{ title: "Inner", count: 1 }, { title: "Other", count: 1 }] }, stat("Inner"), stat("Other inner"),
      stat("Later one"), bar,
      stat("After"),
    ])).map((block) => block.label ?? block.title)).toEqual(["Inner", "After"]);
  });

  it("falls back to the first table, list or key-value block, cut to three rows", () => {
    const rows = (count: number) => Array.from({ length: count }, (_, index) => ({ id: `r${index}`, cells: [{ text: `Trip ${index}` }] }));
    const table: RemoteCardBlock = { type: "table", title: "Trips", columns: [{ title: "Trip" }], tableRows: rows(5) };
    const list: RemoteCardBlock = { type: "list", title: "Latest", items: [1, 2, 3, 4].map((index) => ({ title: `Item ${index}` })) };
    const keyValue: RemoteCardBlock = { type: "keyValue", rows: [1, 2, 3, 4].map((index) => ({ key: `Key ${index}`, value: `${index}` })) };
    const [trimmed] = previewBlocks(card([{ type: "header", title: "Trips" }, table, list]));
    expect(trimmed.type).toBe("table");
    expect(trimmed.tableRows?.map((row) => row.id)).toEqual(["r0", "r1", "r2"]);
    expect(table.tableRows).toHaveLength(5);
    expect(previewBlocks(card([list, table]))[0].items?.map((item) => item.title)).toEqual(["Item 1", "Item 2", "Item 3"]);
    expect(previewBlocks(card([keyValue]))[0].rows?.map((row) => row.key)).toEqual(["Key 1", "Key 2", "Key 3"]);
    expect(previewBlocks(card([{ type: "header", title: "Empty" }, { type: "notice", title: "Nothing to show" }]))).toEqual([]);
    // A table hidden in the second tab doesn't count.
    expect(previewBlocks(card([{ type: "tabs", tabs: [{ title: "A", count: 1 }, { title: "B", count: 1 }] },
      { type: "notice", title: "Soon" }, table]))).toEqual([]);
  });

  it("draws a tile as one labelled button over an inert preview", () => {
    const at = new Date("2026-11-17T22:00:00Z");
    const view = { ...VIEW, pinned: true, private: true, subtitle: "Service health", problems: ["The homelab server didn't answer."] };
    const nodes = render(ViewTile({ view, at, preview: h(ViewPreview, { cached: shownOf("view-homelab") }) }));
    const buttons = find(nodes, tag("button"));
    expect(buttons).toHaveLength(1);
    expect(buttons[0].props).toMatchObject({
      "data-focus-key": "view:V1", "data-id": "home.view.V1", "aria-label": "Homelab, pinned, private, Service health, 1 problem",
    });
    expect(find(nodes, (element) => element.props.class === "hm-view-mark").map((mark) => mark.props.title))
      .toEqual(["Pinned", "Private: it reads a private server"]);
    const preview = find(nodes, (element) => element.props.class === "hm-view-preview")[0];
    expect(preview.props).toMatchObject({ inert: true, "aria-hidden": "true" });
    expect(find([preview], (element) => element.props.class === "card-stat")).toHaveLength(1);
    expect(text(find([preview], (element) => element.props.class === "card-stat-value"))).toBe("2");
    expect(find([preview], (element) => element.props.class === "card-foot")).toEqual([]);
    expect(text(find(nodes, (element) => element.props.class === "hm-view-status warning"))).toBe("The homelab server didn't answer.");

    const refreshing = render(ViewTile({ view: { ...view, refreshing: true }, at, preview: h(ViewPreview, { cached: undefined }) }));
    expect(find(refreshing, tag("button"))[0].props["aria-label"]).toBe("Homelab, pinned, private, Service health, refreshing, 1 problem");
    expect(text(find(refreshing, (element) => element.props.class === "hm-view-status"))).toBe("Refreshing…");
    expect(find(refreshing, (element) => element.props.class === "hm-view-placeholder loading")).toHaveLength(1);
    expect(viewRowLabel({ ...VIEW, subtitle: "Every service" })).toBe("Homelab, Every service");
  });

  it("fetches a thumbnail with nothing cached, a changed summary or an elapsed refreshAfter", () => {
    const cached = shownOf("view-homelab");
    const summary = cached.shown.view;
    const refreshMs = cached.shown.refreshMs;
    expect(refreshMs).toBe(30_000);
    expect(thumbnailNeedsFetch(summary, undefined, 1_000)).toBe(true);
    expect(thumbnailNeedsFetch(summary, cached, 1_000 + refreshMs - 1)).toBe(false);
    expect(thumbnailNeedsFetch({ ...summary }, cached, 1_000 + refreshMs)).toBe(true);
    expect(thumbnailNeedsFetch({ ...summary, updatedAt: "2030-01-01T00:00:00Z" }, cached, 2_000)).toBe(true);
    expect(thumbnailNeedsFetch({ ...summary, refreshedAt: "2030-01-01T00:00:00Z" }, cached, 2_000)).toBe(true);
    // The same moment written another way is no change.
    const refreshed = new Date(String(summary.refreshedAt)).toISOString();
    expect(thumbnailNeedsFetch({ ...summary, refreshedAt: refreshed }, cached, 2_000)).toBe(false);
  });

  it("loads at most two thumbnails at a time, in list order, and wakes when the next one is due", async () => {
    let clock = 0;
    const cache = new Map<string, CachedView>();
    const pending: { callback: () => void; ms: number }[] = [];
    const timers = { set: (callback: () => void, ms: number) => pending.push({ callback, ms }), clear: vi.fn() };
    const answers = new Map<string, (value: unknown) => void>();
    const load = vi.fn((id: string) => new Promise((resolve) => answers.set(id, resolve)));
    const answer = (id: string) => answers.get(id)!({ view: { ...VIEW, id, name: id }, card: VIEW_CARD, refreshAfter: 30 });
    const loader = new ThumbnailLoader({
      load, cached: (id) => cache.get(id), now: () => clock, timers,
      onView: (id, shown) => cache.set(id, { shown, fetchedAt: clock }),
    });
    const views = ["A", "B", "C"].map((id) => ({ ...VIEW, id, name: id }));
    loader.update(views);
    expect(load.mock.calls.map(([id]) => id)).toEqual(["A", "B"]);
    loader.update(views);
    expect(load).toHaveBeenCalledTimes(2);

    clock = 500;
    answer("A");
    await vi.waitFor(() => expect(load).toHaveBeenCalledTimes(3));
    expect(load.mock.calls[2][0]).toBe("C");
    answer("B");
    answer("C");
    await vi.waitFor(() => expect(loader.loading.size).toBe(0));
    expect(cache.size).toBe(3);

    // Everything is cached and current: nothing to fetch until A's refreshAfter runs out.
    loader.update(views);
    expect(load).toHaveBeenCalledTimes(3);
    expect(pending.at(-1)?.ms).toBe(30_000);

    // The list says B changed: only B is fetched again.
    loader.update([views[0], { ...views[1], updatedAt: "2030-01-01T00:00:00Z" }, views[2]]);
    expect(load.mock.calls.slice(3).map(([id]) => id)).toEqual(["B"]);

    loader.stop();
    clock = 60_000;
    pending.at(-1)?.callback();
    expect(load).toHaveBeenCalledTimes(4);
  });

  it("shares one cache with the view's screen, which shows the last answer at once", () => {
    remote.homeTasks.value = TASKS;
    remote.homeViews.value = [VIEW];
    const shown = parseView({ view: { ...VIEW, refreshedAt: "2026-11-17T21:30:00Z" }, card: VIEW_CARD, refreshAfter: 45 });
    applyShown("V1", shown, 12_345);
    expect(viewDetails.value.get("V1")).toEqual({ shown, fetchedAt: 12_345 });
    expect(thumbnailNeedsFetch(remote.homeViews.value![0], viewDetails.value.get("V1"), 12_345 + 44_000)).toBe(false);
    showView("V1");
    expect(openView.value).toMatchObject({ id: "V1", loading: false, shown });
  });

  it("lists a view saved on the Mac at the next poll", async () => {
    remote.homeTasks.value = TASKS;
    apiMock.mockResolvedValueOnce({ views: [VIEW], revision: "r1" });
    await remote.refreshViews();
    apiMock.mockResolvedValueOnce({ views: [VIEW, { ...VIEW, id: "V9", name: "Follow-ups", pinned: false }], revision: "r2" });
    await remote.refreshViews();
    expect(apiMock).toHaveBeenLastCalledWith("/api/v1/home/views?revision=r1");
    expect(listedViews().map((view) => view.name)).toEqual(["Homelab", "Follow-ups"]);
  });
});
