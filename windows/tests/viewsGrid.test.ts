import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Block } from "../src/shared/cards";
import { parseView, type HomeViewSummary, type ShownView } from "../src/shared/views";
import {
  SECTION_KEYS,
  gridColumns,
  previewBlocks,
  sectionCollapsed,
  sectionCount,
  sectionLabel,
  setSectionCollapsed,
  thumbDue,
  thumbLabel,
  thumbNote,
  thumbsToFetch,
  type ThumbEntry,
} from "../src/renderer/viewsGrid";

/** Resolved views as the views QA host serves them (synthetic trackers). */
const fixture = (name: string): ShownView => parseView(JSON.parse(readFileSync(new URL(`./views/${name}.json`, import.meta.url), "utf8")))!;
const shape = (blocks: Block[]) => blocks.map((block) => block.label ?? block.title ?? block.type);
const stat = (label: string, value = "1"): Block => ({ type: "stat", label, value });
const chart = (title: string, kind = "bar"): Block => ({ type: "chart", kind, title, items: [{ label: "A", high: 1 }] });

describe("views grid: columns", () => {
  it("fits 160-wide columns under 600 and 240-wide ones from 600, 12 apart, 1 to 6", () => {
    const widths: [number, number][] = [[320, 1], [375, 2], [599, 3], [600, 2], [700, 2], [1000, 4], [1600, 6], [2000, 6]];
    for (const [width, columns] of widths) expect(gridColumns(width), `columns(${width})`).toBe(columns);
    expect(gridColumns(0)).toBe(1);
    expect(gridColumns(Number.NaN)).toBe(1);
  });
});

describe("views grid: previewBlocks", () => {
  it("keeps only the first tab's blocks of a flat card: This week shows just its stat", () => {
    const week = fixture("view-dashboard").card;
    expect(week.blocks.map((block) => block.type)).toEqual(["header", "tabs", "stat", "keyValue", "table", "chart", "chart", "chart", "actions"]);
    expect(shape(previewBlocks(week))).toEqual(["Active interview loops"]);
  });

  it("treats a section as a heading before its blocks: Homelab shows its stat", () => {
    expect(shape(previewBlocks(fixture("view-homelab").card))).toEqual(["Services up"]);
  });

  it("takes up to 2 stats and the first chart, in document order", () => {
    expect(shape(previewBlocks(fixture("view-bills").card))).toEqual(["Due soon", "Active", "By category"]);
    const blocks = [chart("Line", "line"), stat("A"), stat("B"), stat("C"), chart("Pie", "pie")];
    expect(shape(previewBlocks({ blocks }))).toEqual(["Line", "A", "B"]);
  });

  it("falls back to the first table, list or key-value block, trimmed to 3 rows", () => {
    const rows = Array.from({ length: 5 }, (_, n) => ({ id: `r${n}`, cells: [{ text: `Trip ${n + 1}` }] }));
    const table: Block = { type: "table", title: "Trips", columns: [{ title: "Trip" }], tableRows: rows };
    const [trimmed] = previewBlocks({ blocks: [{ type: "header", title: "Trips" }, table] });
    expect(trimmed.tableRows).toHaveLength(3);
    expect(table.tableRows).toHaveLength(5);
    const list: Block = { type: "list", items: Array.from({ length: 6 }, (_, n) => ({ title: `Person ${n}` })) };
    expect(previewBlocks({ blocks: [{ type: "section", title: "People" }, list, table] })[0].items).toHaveLength(3);
    const pairs: Block = { type: "keyValue", rows: [1, 2, 3, 4].map((n) => ({ key: `Key ${n}`, value: String(n) })) };
    expect(previewBlocks({ blocks: [{ type: "notice", title: "Note" }, pairs] })[0].rows).toHaveLength(3);
  });

  it("never shows later tabs' blocks or skipped types", () => {
    const table: Block = { type: "table", title: "First tab", columns: [{ title: "A" }], tableRows: [] };
    const tabs: Block = { type: "tabs", tabs: [{ title: "One", count: 1 }, { title: "Two", count: 2 }] };
    expect(shape(previewBlocks({ blocks: [tabs, table, stat("Hidden"), chart("Hidden chart"), stat("After")] }))).toEqual(["After"]);
    expect(shape(previewBlocks({ blocks: [tabs, table, stat("Hidden"), chart("Hidden chart")] }))).toEqual(["First tab"]);
    const skipped = ["header", "section", "actions", "notice", "badges", "progress", "image", "map"].map((type) => ({ type, title: "x" }));
    expect(previewBlocks({ blocks: skipped })).toEqual([]);
    expect(previewBlocks(null)).toEqual([]);
  });
});

describe("views grid: collapsible sections", () => {
  function memory() {
    const values = new Map<string, string>();
    return { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => void values.set(key, value), values };
  }

  it("writes each section's flag when toggled and reads it back", () => {
    const store = memory();
    expect(sectionCollapsed(store, "views")).toBe(false);
    setSectionCollapsed(store, "views", true);
    expect(store.values.get("cantrip.home.views.collapsed")).toBe("1");
    expect(sectionCollapsed(store, "views")).toBe(true);
    expect(sectionCollapsed(store, "tasks")).toBe(false);
    setSectionCollapsed(store, "tasks", true);
    setSectionCollapsed(store, "views", false);
    expect([...store.values]).toEqual([[SECTION_KEYS.views, "0"], [SECTION_KEYS.tasks, "1"]]);
    expect(sectionCollapsed(store, "views")).toBe(false);
    expect(sectionCollapsed(store, "tasks")).toBe(true);
    const broken = { getItem: () => { throw new Error("denied"); }, setItem: () => { throw new Error("denied"); } };
    expect(sectionCollapsed(broken, "tasks")).toBe(false);
    expect(() => setSectionCollapsed(broken, "tasks", true)).not.toThrow();
  });

  it("names each heading with its count and shows the count only when collapsed", () => {
    expect(sectionLabel("Views", 6, "view")).toBe("Views, 6 views");
    expect(sectionLabel("Tasks", 1, "task")).toBe("Tasks, 1 task");
    expect(sectionCount(4, true)).toBe("· 4");
    expect(sectionCount(4, false)).toBe("");
  });
});

describe("views grid: thumbnail fetches", () => {
  const now = 10_000_000;
  const summary = (id: string, extra: Partial<HomeViewSummary> = {}): HomeViewSummary =>
    ({ id, name: id, pinned: false, private: false, updatedAt: "2026-11-17T20:00:00Z", refreshedAt: "2026-11-17T20:05:00Z", ...extra });
  const cached = (view: HomeViewSummary, fetchedAt = now - 10_000): ThumbEntry =>
    ({ shown: { view, card: { version: 1, id: `view-${view.id}`, type: "view", blocks: [] }, refreshMs: 30_000 }, fetchedAt, failed: false });

  it("fetches when nothing is cached, the view changed, or its refreshAfter passed", () => {
    const view = summary("v1");
    expect(thumbDue(undefined, view, now)).toBe(true);
    expect(thumbDue(cached(view), view, now)).toBe(false);
    expect(thumbDue(cached(view), { ...view, updatedAt: "2026-11-17T21:00:00Z" }, now)).toBe(true);
    expect(thumbDue(cached(view), { ...view, refreshedAt: "2026-11-17T21:00:00Z" }, now)).toBe(true);
    expect(thumbDue(cached(summary("v1", { refreshedAt: null })), summary("v1", { refreshedAt: undefined }), now)).toBe(false);
    expect(thumbDue(cached(view), view, now + 19_999)).toBe(false);
    expect(thumbDue(cached(view), view, now + 20_000)).toBe(true);
    const failed: ThumbEntry = { ...cached(view, now), failed: true };
    expect(thumbDue(failed, { ...view, updatedAt: "changed" }, now + 29_000)).toBe(false);
    expect(thumbDue(failed, view, now + 30_000)).toBe(true);
  });

  it("keeps at most 2 in flight, in list order, skipping fresh ones", () => {
    const views = ["a", "b", "c", "d"].map((id) => summary(id));
    const cache = new Map<string, ThumbEntry>([["a", cached(views[0])]]);
    expect(thumbsToFetch(views, cache, new Set(), now)).toEqual(["b", "c"]);
    expect(thumbsToFetch(views, cache, new Set(["b"]), now)).toEqual(["c"]);
    expect(thumbsToFetch(views, cache, new Set(["b", "c"]), now)).toEqual([]);
    cache.set("b", cached(views[1])).set("c", cached(views[2])).set("d", cached(views[3]));
    expect(thumbsToFetch(views, cache, new Set(), now)).toEqual([]);
    expect(thumbsToFetch(views.map((view) => (view.id === "d" ? { ...view, updatedAt: "newer" } : view)), cache, new Set(), now)).toEqual(["d"]);
  });
});

describe("views grid: thumbnail text", () => {
  it("labels the whole card like the old row, with refreshing and problems", () => {
    const view: HomeViewSummary = { id: "v", name: "Homelab", subtitle: "Service health", pinned: true, private: true };
    expect(thumbLabel(view)).toBe("Homelab, Pinned, Private, Service health");
    expect(thumbLabel({ ...view, pinned: false, private: false, refreshing: true, problems: ["a", "b"] })).toBe("Homelab, Service health, Refreshing, 2 problems");
    expect(thumbNote({ ...view, refreshing: true, problems: ["down"] })).toEqual({ text: "Refreshing…", warning: false });
    expect(thumbNote({ ...view, problems: ["homelab is down"] })).toEqual({ text: "homelab is down", warning: true });
    expect(thumbNote(view)).toBeNull();
  });
});
