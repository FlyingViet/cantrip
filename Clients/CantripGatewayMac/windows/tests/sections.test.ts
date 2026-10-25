import { describe, expect, it } from "vitest";
import type { RemoteSessionSummary } from "../src/gateway/api/types";
import {
  collapsedSections, LOOSE_ID, movedSections, normalizeSectionName, sectionDropPosition, sectionNameError, sectionOf, tabGroups,
  toggleCollapsed, visibleTabs,
} from "../src/gateway/state/sections";

const tab = (id: string, extra: Partial<RemoteSessionSummary> = {}) => ({ id, title: id, isStreaming: false, ...extra }) as RemoteSessionSummary;
const sections = [{ id: "s1", name: "Work" }, { id: "s2", name: "Home" }];

describe("tab sections", () => {
  it("keeps a flat list without sections", () => {
    expect(tabGroups([tab("a")], [])).toBeNull();
  });

  it("puts unfiled tabs first, then sections in the Mac's order", () => {
    const groups = tabGroups([tab("a"), tab("b", { sectionID: "s2" }), tab("c", { sectionID: "s1" }), tab("d", { sectionID: "gone" })], sections)!;
    expect(groups.map((group) => group.name)).toEqual(["Tabs", "Work", "Home"]);
    expect(groups.map((group) => group.sessions.map((item) => item.id))).toEqual([["a", "d"], ["c"], ["b"]]);
    expect(groups[0].id).toBe(LOOSE_ID);
    expect(sectionOf(tab("x", { sectionID: "gone" }), sections)).toBeNull();
    expect(sectionOf(tab("x", { sectionID: "s2" }), sections)).toBe("s2");
  });

  it("reorders sections like the Mac: a dropped header takes the target's place, Tabs means first", () => {
    const three = [...sections, { id: "s3", name: "Games" }];
    expect(sectionDropPosition(three, "s1")).toBe(0);
    expect(sectionDropPosition(three, "s3")).toBe(2);
    expect(sectionDropPosition(three, LOOSE_ID)).toBe(0);
    expect(movedSections(three, "s3", 0).map((section) => section.id)).toEqual(["s3", "s1", "s2"]);
    expect(movedSections(three, "s1", 2).map((section) => section.id)).toEqual(["s2", "s3", "s1"]);
    expect(movedSections(three, "s1", 1).map((section) => section.id)).toEqual(["s2", "s1", "s3"]);
    for (const [id, position] of [["s1", 0], ["s1", -1], ["s3", 3], ["gone", 0]] as const) {
      expect(movedSections(three, id, position)).toBe(three);
    }
  });

  it("keeps the open, working and waiting tabs of a collapsed section", () => {
    const group = tabGroups([tab("a", { sectionID: "s1" }), tab("b", { sectionID: "s1", isStreaming: true }),
      tab("c", { sectionID: "s1", pendingInputCount: 2 }), tab("d", { sectionID: "s1" })], sections)![1];
    expect(visibleTabs(group, false, null).map((item) => item.id)).toEqual(["a", "b", "c", "d"]);
    expect(visibleTabs(group, true, null).map((item) => item.id)).toEqual(["b", "c"]);
    expect(visibleTabs(group, true, "d").map((item) => item.id)).toEqual(["b", "c", "d"]);
  });

  it("remembers collapsed sections per Mac", () => {
    const store = new Map<string, string>();
    const storage = { getItem: (key: string) => store.get(key) ?? null, setItem: (key: string, value: string) => { store.set(key, value); } };
    toggleCollapsed(storage, "mini", "s1");
    expect([...collapsedSections(storage, "mini")]).toEqual(["s1"]);
    expect(collapsedSections(storage, "laptop").size).toBe(0);
    toggleCollapsed(storage, "mini", "s1");
    expect(collapsedSections(storage, "mini").size).toBe(0);
    store.set("gateway.collapsedTabSections", "not json");
    expect(collapsedSections(storage, "mini").size).toBe(0);
  });

  it("checks section names like the Mac", () => {
    expect(normalizeSectionName("  Work \n stuff ")).toBe("Work stuff");
    expect(sectionNameError("   ")).toMatch(/name/);
    expect(sectionNameError("x".repeat(41))).toMatch(/40/);
    expect(sectionNameError("x".repeat(40))).toBeNull();
  });
});
