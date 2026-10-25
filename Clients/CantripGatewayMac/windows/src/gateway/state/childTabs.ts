// Child tabs (Cantrip docs/sessions-and-council.md "Child tabs"): a queued message runs in its own tab
// and branch, nested under its parent, and merges back. Wording and offered actions match the Mac
// panel and Cantrip Agent (CantripChildTabs.swift).
import type { ChildTabAction, RemoteChildResult, RemoteChildTab } from "../api/types";

export type ChildChipTone = "work" | "ok" | "bad" | "plain";

/** The card's buttons for a conflict, in the Mac's order, limited to what it offers now. */
export function conflictOptions(child: RemoteChildResult): { action: ChildTabAction; label: string; primary: boolean }[] {
  const base = child.baseBranch ? `${child.baseBranch}'s` : "the parent's";
  const all: { action: ChildTabAction; label: string; primary: boolean }[] = [
    { action: "resolve", label: "Keep both, then run the tests (Recommended)", primary: true },
    { action: "keepParent", label: `Keep ${base} version`, primary: false },
    { action: "keepChild", label: "Keep the child's version", primary: false },
    { action: "leave", label: "Leave it unmerged; I'll look", primary: false },
  ];
  return all.filter((option) => child.actions.includes(option.action));
}

/** Try Again, Merge Its Work and Discard once the child stopped working; Discard needs a branch. */
export function extraActions(child: RemoteChildResult): { action: ChildTabAction; label: string }[] {
  if (["conflict", "working", "needsInput"].includes(child.state)) return [];
  const labels: Partial<Record<ChildTabAction, string>> = { retry: "Try Again", merge: "Merge Its Work", discard: "Discard" };
  return child.actions.flatMap((action) => {
    const label = labels[action as ChildTabAction];
    if (!label || (action === "discard" && !child.branch)) return [];
    return [{ action: action as ChildTabAction, label }];
  });
}

/** "2 files merged cleanly, but both branches changed the same lines in a.ts and b.ts." */
export function conflictLead(child: RemoteChildResult): string {
  const files = child.conflictFiles.slice(0, 4).join(", ") + (child.conflictFiles.length > 4 ? ` and ${child.conflictFiles.length - 4} more` : "");
  const clean = child.cleanFileCount ?? 0;
  return clean > 0
    ? `${clean} ${clean === 1 ? "file" : "files"} merged cleanly, but both branches changed the same lines in ${files}.`
    : `Both branches changed the same lines in ${files}.`;
}

export function firstLine(prompt: string): string {
  return prompt.split(/\r?\n/)[0] ?? "";
}

export function summaryText(child: RemoteChildResult): string {
  const summary = (child.summary ?? "").trim();
  return !summary && child.state === "working" ? "Working on it in its own tab." : summary;
}

/** The banner atop a child tab's conversation. */
export function bannerText(child: RemoteChildTab): string {
  return `Child tab of ${child.parentTitle}`
    + (child.branch ? ` · ${child.branch} → ${child.baseBranch || "the parent's branch"}` : "")
    + (child.statusLine ? ` · ${child.statusLine}` : "");
}

export function chipTone(state: string): ChildChipTone {
  switch (state) {
    case "working": case "needsInput": case "merging": case "conflict": return "work";
    case "merged": case "noChanges": return "ok";
    case "failed": return "bad";
    default: return "plain";
  }
}

export function chipGlyph(state: string): string {
  switch (state) {
    case "needsInput": return "?";
    case "finished": return "◷";
    case "merged": case "noChanges": return "✓";
    case "conflict": return "⚠";
    case "failed": return "!";
    case "working": case "merging": return "•";
    default: return "–";
  }
}

/** How a line of the conflict excerpt reads: context, the child's side or the parent's. */
export function excerptLineKind(line: string): "ctx" | "theirs" | "ours" {
  if (line.startsWith(" ") || line === "…") return "ctx";
  return line.startsWith("child ") ? "theirs" : "ours";
}
