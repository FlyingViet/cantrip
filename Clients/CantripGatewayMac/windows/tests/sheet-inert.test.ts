import { describe, expect, it, vi } from "vitest";

// kit.tsx listens for keys on the page when it loads.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  scope.document ??= { addEventListener: noop, removeEventListener: noop };
});

import { inertTargets } from "../src/gateway/ui/kit";

class Node {
  readonly children: Node[];
  constructor(readonly name: string, ...children: Node[]) {
    this.children = children;
  }
  contains(other: Node): boolean {
    return other === this || this.children.some((child) => child.contains(other));
  }
}

const names = (nodes: Node[]) => nodes.map((node) => node.name);

describe("what goes inert behind a sheet", () => {
  it("makes whole panes inert when the sheet is drawn outside them", () => {
    const sidebar = new Node("sidebar", new Node("tabs"));
    const detail = new Node("detail", new Node("chat"));
    const sheet = new Node("sheet");
    expect(names(inertTargets([sidebar, detail], [sheet]))).toEqual(["sidebar", "detail"]);
  });

  it("keeps the way down to a sheet drawn inside a pane (Tasks' Edit Task sheet) usable", () => {
    const sheet = new Node("sheet", new Node("cards"));
    const backdrop = new Node("backdrop", sheet);
    const detail = new Node("detail", new Node("toolbar"), new Node("tasks", new Node("rows")), backdrop);
    const sidebar = new Node("sidebar");
    const targets = inertTargets([sidebar, detail], [sheet]);
    expect(names(targets)).toEqual(["sidebar", "toolbar", "tasks"]);
    expect(targets.some((node) => node.contains(sheet))).toBe(false);
  });

  it("keeps every open sheet usable", () => {
    const first = new Node("first");
    const second = new Node("second");
    const detail = new Node("detail", new Node("pane", first), new Node("other"), second);
    expect(names(inertTargets([detail], [first, second]))).toEqual(["other"]);
    expect(names(inertTargets([detail], []))).toEqual(["detail"]);
  });
});
