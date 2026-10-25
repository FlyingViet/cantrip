import { describe, expect, it } from "vitest";
import type { RemoteSessionSummary } from "../src/gateway/api/types";
import {
  collapsedSections, LOOSE_ID, normalizeSectionName, sectionNameError, sectionOf, tabGroups, toggleCollapsed, visibleTabs,
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
