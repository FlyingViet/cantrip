// A tab's action menu (CantripTabActions.swift): the sidebar's context menu and a tab's More menu.
import type { RemoteSessionSummary } from "../api/types";
import { isBusy, startFreshSupport } from "../state/format";
import { sectionOf } from "../state/sections";
import * as nav from "../state/nav";
import * as remote from "../state/remote";
import { confirmDialog, toast, type MenuEntry } from "./kit";

async function run(label: string, work: () => Promise<unknown>): Promise<void> {
  try {
    await work();
  } catch (error) {
    toast(`${label} failed: ${(error as Error).message}`);
  }
}

export function startFreshEntry(session: RemoteSessionSummary): MenuEntry[] {
  const support = startFreshSupport(session);
  if (support === false) return [];
  return [{
    label: support === undefined ? "Start Fresh (update Cantrip on the Mac)" : "Start Fresh",
    icon: "arrow.uturn.backward",
    disabled: remote.isMutating.value || isBusy(session) || support !== true,
    onSelect: () => void run("Start Fresh", () => remote.startFresh(session.id)),
  }];
}

export function tabActions(session: RemoteSessionSummary): MenuEntry[] {
  const list = remote.sessions.value;
  const index = list.findIndex((item) => item.id === session.id);
  const mutating = remote.isMutating.value;
  const entries: MenuEntry[] = [
    { label: "Mac Permissions & View Mac", icon: "desktopcomputer", onSelect: () => { nav.sheet.value = { kind: "macAccess" }; } },
  ];
  if (session.supportsInputRequests) {
    entries.push({
      label: "View Questions in Chat", icon: "questionmark.circle",
      onSelect: () => { nav.sheet.value = { kind: "inputRequests", sessionID: session.id }; },
    });
    if (!session.isLocalPrivate) {
      entries.push({
        label: "Sign in to GitHub on Mac", icon: "key", disabled: mutating || isBusy(session),
        onSelect: () => void run("Sign in", () => remote.sendMessage(session.id, { text: "/login github", mode: "queue" })),
      });
    }
  }
  entries.push(
    {
      label: session.isLocalPrivate ? "Private Local Settings" : "Model Settings", icon: "slider.horizontal.3", disabled: mutating,
      onSelect: () => nav.openModelSettings(session),
    },
    ...startFreshEntry(session),
    {
      label: "Rename Tab", icon: "pencil", disabled: mutating || !session.supportsTabMetadata,
      onSelect: () => { nav.sheet.value = { kind: "rename", sessionID: session.id }; },
    },
    {
      label: session.isLocked ? "Unlock Tab" : "Lock Tab", icon: "lock.fill",
      disabled: mutating || !session.supportsTabMetadata || session.isLocalPrivate,
      onSelect: () => void run(session.isLocked ? "Unlock" : "Lock", () => remote.updateTab(session.id, { isLocked: !session.isLocked })),
    },
  );
  if (remote.supportsTabSections.value && session.supportsTabSections) {
    const sections = remote.tabSections.value;
    const current = sectionOf(session, sections);
    entries.push(
      { kind: "separator" },
      { kind: "header", label: "Move to Section" },
      {
        label: "Tabs", checked: current === null, disabled: mutating,
        onSelect: () => void run("Move", () => remote.fileTab(session.id, null)),
      },
      ...sections.map((section) => ({
        label: section.name, checked: current === section.id, disabled: mutating,
        onSelect: () => void run("Move", () => remote.fileTab(session.id, section.id)),
      })),
      {
        label: "New Section…", icon: "folder" as const, disabled: mutating,
        onSelect: () => { nav.sheet.value = { kind: "sectionName", fileTabID: session.id }; },
      },
    );
  }
  if (session.isLocalPrivate) entries.push({ kind: "header", label: "Permanent tab. History saved; self-hosted models only." });
  if (!session.supportsTabMetadata) entries.push({ kind: "header", label: "Update Cantrip on the Mac to rename or lock tabs." });
  entries.push({ kind: "separator" });
  if (session.supportsTabReordering) {
    entries.push(
      {
        label: "Move Tab Up", icon: "arrow.up", disabled: mutating || index <= 0,
        onSelect: () => void run("Move", () => remote.moveTab(session.id, list[index - 1].id, false)),
      },
      {
        label: "Move Tab Down", icon: "arrow.down", disabled: mutating || index < 0 || index >= list.length - 1,
        onSelect: () => void run("Move", () => remote.moveTab(session.id, list[index + 1].id, true)),
      },
    );
  } else {
    entries.push({ kind: "header", label: "Update Cantrip on the Mac to reorder tabs." });
  }
  entries.push(
    { kind: "separator" },
    {
      label: "Close Tab", icon: "xmark", destructive: true, disabled: mutating || session.isLocked,
      onSelect: () => void nav.closeTab(session.id),
    },
  );
  return entries;
}

/** Confirms before closing a busy tab (its run stops). */
export async function confirmClose(session: RemoteSessionSummary): Promise<void> {
  if (isBusy(session)) {
    const ok = await confirmDialog({
      title: `Close ${remote.tabTitle(session)}?`, message: "It's still working. Closing stops its run.", confirm: "Close Tab", destructive: true,
    });
    if (!ok) return;
  }
  await nav.closeTab(session.id);
}
