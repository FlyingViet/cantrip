// Tab sections (CantripTabSections.swift): the Mac keeps named, ordered groups of tabs; each device
// keeps which ones are collapsed. Pure, so tests load it without the window bridge.
import type { RemoteSessionSummary, TabSection } from "../api/types";

/** The group of tabs not in any section. */
export const LOOSE_ID = "tabs";
export const MAX_SECTION_NAME = 40;
const COLLAPSED_KEY = "gateway.collapsedTabSections";

export interface TabGroup {
  id: string;
  name: string;
  sessions: RemoteSessionSummary[];
  /** Null for Tabs (unfiled). */
  section: TabSection | null;
}

/** Tabs (unfiled, and tabs of deleted sections) then each section; null without sections (flat list). */
export function tabGroups(sessions: RemoteSessionSummary[], sections: TabSection[]): TabGroup[] | null {
  if (!sections.length) return null;
  const known = new Set(sections.map((section) => section.id));
  return [
    { id: LOOSE_ID, name: "Tabs", sessions: sessions.filter((item) => !item.sectionID || !known.has(item.sectionID)), section: null },
    ...sections.map((section) => ({
      id: section.id, name: section.name, sessions: sessions.filter((item) => item.sectionID === section.id), section,
    })),
  ];
}

/** A collapsed group still shows the open tab and tabs that are working or waiting for an answer. */
export function visibleTabs(group: TabGroup, collapsed: boolean, openID: string | null): RemoteSessionSummary[] {
  if (!collapsed) return group.sessions;
  return group.sessions.filter((item) => item.id === openID || item.isStreaming || (item.pendingInputCount ?? 0) > 0);
}

/** The section a tab shows under, or null for Tabs. */
export function sectionOf(session: Pick<RemoteSessionSummary, "sectionID">, sections: TabSection[]): string | null {
  return session.sectionID && sections.some((section) => section.id === session.sectionID) ? session.sectionID : null;
}

/** Where a section dragged onto `targetGroupID`'s header lands: the target's place (Tabs: first). */
export function sectionDropPosition(sections: TabSection[], targetGroupID: string): number {
  return targetGroupID === LOOSE_ID ? 0 : sections.findIndex((section) => section.id === targetGroupID);
}

/** `sections` with `id` moved to `position` (as the Mac does it); unchanged for unknown ids or positions. */
export function movedSections(sections: TabSection[], id: string, position: number): TabSection[] {
  const index = sections.findIndex((section) => section.id === id);
  if (index < 0 || position < 0 || position >= sections.length || position === index) return sections;
  const next = [...sections];
  next.splice(position, 0, ...next.splice(index, 1));
  return next;
}

export function normalizeSectionName(name: string): string {
  return name.split(/\s+/).filter(Boolean).join(" ");
}

export function sectionNameError(name: string): string | null {
  const normalized = normalizeSectionName(name);
  if (!normalized) return "Give the section a name.";
  if ([...normalized].length > MAX_SECTION_NAME) return `Section names must be ${MAX_SECTION_NAME} characters or fewer.`;
  return null;
}

type Store = Pick<Storage, "getItem" | "setItem">;

function readAll(storage: Store): Record<string, string[]> {
  try {
    const parsed = JSON.parse(storage.getItem(COLLAPSED_KEY) ?? "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/** Collapsed sections for one paired Mac (`scope`). */
export function collapsedSections(storage: Store, scope: string): Set<string> {
  const ids = readAll(storage)[scope];
  return new Set(Array.isArray(ids) ? ids.filter((id) => typeof id === "string") : []);
}

export function toggleCollapsed(storage: Store, scope: string, id: string): Set<string> {
  const all = readAll(storage);
  const ids = new Set(Array.isArray(all[scope]) ? all[scope] : []);
  if (ids.has(id)) ids.delete(id); else ids.add(id);
  all[scope] = [...ids].sort();
  storage.setItem(COLLAPSED_KEY, JSON.stringify(all));
  return ids;
}
