import { describe, expect, it } from "vitest";
import type { RemoteChildResult } from "../src/gateway/api/types";
import {
  bannerText, chipTone, conflictLead, conflictOptions, excerptLineKind, extraActions, firstLine, summaryText,
} from "../src/gateway/state/childTabs";

function child(overrides: Partial<RemoteChildResult>): RemoteChildResult {
  return {
    id: "child", parentID: "parent", title: "Per-task models", prompt: "Let each task set its own model\nthen run five on Sonnet.",
    parentTitle: "Cantrip", state: "working", statusLine: "Working", summary: "", replies: [], files: [], added: 0, removed: 0,
    conflictFiles: [], cleanFileCount: 0, actions: [], createdAt: 0, updatedAt: 0, ...overrides,
  };
}

describe("child tab cards", () => {
  it("offers the Mac's conflict answers in order, naming the parent's branch", () => {
    const options = conflictOptions(child({ state: "conflict", baseBranch: "main", actions: ["resolve", "keepParent", "keepChild", "leave", "open"] }));
    expect(options.map((option) => option.label)).toEqual([
      "Keep both, then run the tests (Recommended)", "Keep main's version", "Keep the child's version", "Leave it unmerged; I'll look",
    ]);
    expect(options[0].primary).toBe(true);
    expect(conflictOptions(child({ state: "conflict", actions: ["leave"] })).map((option) => option.action)).toEqual(["leave"]);
  });

  it("shows Try Again, Merge and Discard only once the child has stopped, and Discard only with a branch", () => {
    expect(extraActions(child({ state: "unmerged", branch: "cantrip/child/x", actions: ["retry", "discard", "open"] })).map((a) => a.label))
      .toEqual(["Try Again", "Discard"]);
    expect(extraActions(child({ state: "failed", actions: ["open", "discard"] }))).toEqual([]);
    expect(extraActions(child({ state: "working", branch: "b", actions: ["open", "discard"] }))).toEqual([]);
    expect(extraActions(child({ state: "needsInput", branch: "b", actions: ["open", "requeue", "discard"] })).map((a) => a.label))
      .toEqual(["Run in this tab instead"]);
    expect(extraActions(child({ state: "requeued", actions: ["open"] }))).toEqual([]);
    expect(extraActions(child({ state: "conflict", branch: "b", actions: ["resolve", "open"] }))).toEqual([]);
    expect(extraActions(child({ state: "stopped", branch: "b", actions: ["merge", "discard", "open"] })).map((a) => a.action))
      .toEqual(["merge", "discard"]);
  });

  it("words conflicts, banners and summaries like the other clients", () => {
    expect(conflictLead(child({ conflictFiles: ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts"], cleanFileCount: 1 })))
      .toBe("1 file merged cleanly, but both branches changed the same lines in a.ts, b.ts, c.ts, d.ts and 1 more.");
    expect(conflictLead(child({ conflictFiles: ["a.ts"] }))).toBe("Both branches changed the same lines in a.ts.");
    expect(bannerText({ state: "working", title: "x", parentTitle: "Cantrip", statusLine: "Working", branch: "cantrip/child/x", baseBranch: "main" }))
      .toBe("Child tab of Cantrip · cantrip/child/x → main · Working");
    expect(bannerText({ state: "noChanges", title: "x", parentTitle: "Notes", statusLine: "Done · no repository to merge" }))
      .toBe("Child tab of Notes · Done · no repository to merge");
    expect(summaryText(child({}))).toBe("Working on it in its own tab.");
    expect(summaryText(child({ state: "merged", summary: "  Done.  " }))).toBe("Done.");
    expect(firstLine("First\r\nSecond")).toBe("First");
  });

  it("colors states and excerpt lines like the Mac", () => {
    expect(chipTone("merged")).toBe("ok");
    expect(chipTone("conflict")).toBe("work");
    expect(chipTone("failed")).toBe("bad");
    expect(chipTone("rebasing")).toBe("plain");
    expect(["  context", "…", "child   applyModel()", "main    removeOnce()"].map(excerptLineKind)).toEqual(["ctx", "ctx", "theirs", "ours"]);
  });
});
