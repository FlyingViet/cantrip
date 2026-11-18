// Home's Views (docs/views.md, CantripHomeViewsSection): the list above Tasks (pinned first, a lock on private
// views) and a view's screen, its card drawn by the chat's card renderer with Refresh, Pin and Delete, fetched
// again every `refreshAfter` seconds while it stays open.
import type { JSX } from "preact";
import { useEffect, useErrorBoundary, useMemo, useState } from "preact/hooks";
import type { HomeViewSummary } from "../../api/types";
import { now } from "../../state/clock";
import * as remote from "../../state/remote";
import { supportsViews, viewRowLabel, viewSubtitle, ViewPoller } from "../../state/views";
import { Icon } from "../icons";
import { confirmDialog, Spinner, type MenuEntry } from "../kit";
import { CardView } from "../transcript/Cards";
import { contextMenuAt, ErrorLine, PaneBar, ScrollArea, Unavailable } from "./parts";
import { SymbolIcon } from "./symbols";
import * as tasksNav from "./tasksNav";
import {
  applyShown, closeView, deleteView, fetchView, loadFailed, openView, refreshView, setViewPinned, showView, viewActionHandler,
} from "./viewsState";

/** The views to list: none unless the Mac serves views. */
export function listedViews(): HomeViewSummary[] {
  return supportsViews(remote.homeTasks.value) ? remote.homeViews.value ?? [] : [];
}

export function openViewScreen(view: HomeViewSummary): void {
  showView(view.id);
  tasksNav.openView(view.id);
}

function confirmDeleteView(view: HomeViewSummary, then?: () => void): void {
  void confirmDialog({
    title: `Delete ${view.name}?`, message: "The view is removed from every device. Its data stays where it came from.",
    confirm: "Delete View", destructive: true,
  }).then(async (confirmed) => {
    if (confirmed && (await deleteView(view))) then?.();
  });
}

function viewMenu(view: HomeViewSummary): MenuEntry[] {
  return [
    { label: "Open", icon: "arrow.up.forward.square", onSelect: () => openViewScreen(view) },
    { label: view.pinned ? "Unpin" : "Pin", icon: view.pinned ? "pin.slash" : "pin", disabled: remote.isMutating.value,
      onSelect: () => void setViewPinned(view, !view.pinned) },
    { kind: "separator" },
    { label: "Delete", icon: "trash", destructive: true, disabled: remote.isMutating.value, onSelect: () => confirmDeleteView(view) },
  ];
}

/** "Views" above the tasks: each view's icon, name and subtitle (or when it was updated), pinned ones first. */
export function ViewsSection(): JSX.Element | null {
  const views = listedViews();
  const error = supportsViews(remote.homeTasks.value) ? remote.homeViewsError.value : null;
  if (!views.length && !error) return null;
  const at = new Date(now.value);
  return (
    <section class="hm-views" aria-labelledby="hm-views-title">
      <h3 id="hm-views-title" class="hm-views-heading">Views</h3>
      <ErrorLine text={error} class="hm-views-error" />
      <ul class="hm-view-list">
        {views.map((view) => (
          <li key={view.id} class="hm-view-item">
            <button type="button" class="hm-view" data-focus-key={`view:${view.id}`} aria-label={viewRowLabel(view, at)}
              onClick={() => openViewScreen(view)} onContextMenu={(event) => contextMenuAt(event, viewMenu(view), `${view.name} actions`)}>
              <span class="hm-view-icon accent"><SymbolIcon name={view.icon ?? "rectangle.stack"} size={20} /></span>
              <span class="hm-view-body">
                <span class="hm-view-title">
                  <span class="hm-view-name">{view.name}</span>
                  {view.pinned ? <span class="hm-view-mark" title="Pinned"><Icon name="pin" size={12} /></span> : null}
                  {view.private ? <span class="hm-view-mark" title="Private: it reads a private server"><Icon name="lock.fill" size={12} /></span> : null}
                </span>
                <span class="hm-view-subtitle">{viewSubtitle(view, at)}</span>
              </span>
              <Icon name="chevron.right" size={14} class="hm-view-chevron" />
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** A view's screen: Back, its name, Refresh, Pin/Unpin and Delete over its card at a readable width. */
export function ViewScreen(props: { viewID: string }): JSX.Element {
  const { viewID } = props;
  const state = openView.value?.id === viewID ? openView.value : null;
  const listed = remote.homeViews.value?.find((view) => view.id === viewID);
  const summary = state?.shown?.view ?? listed;
  const onAction = useMemo(() => viewActionHandler(viewID), [viewID]);
  const [cardError] = useErrorBoundary((caught) => console.warn("Couldn't draw a view:", caught));
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (openView.peek()?.id !== viewID || attempt > 0) showView(viewID);
    const poller = new ViewPoller({
      load: () => fetchView(viewID),
      onView: (shown) => applyShown(viewID, shown),
      onError: (error) => loadFailed(viewID, error),
    });
    poller.start();
    return () => {
      poller.stop();
      // Leaving for one of its records keeps it; going anywhere else closes it.
      const route = tasksNav.route.peek();
      if (!(route.kind === "record" && route.fromView === viewID)) closeView(viewID);
    };
  }, [viewID, attempt]);

  const refreshing = state?.refreshing === true;
  const bar = (
    <PaneBar backLabel="Tasks" onBack={tasksNav.back} title={summary?.name ?? "View"}>
      {summary?.private ? <span class="hm-view-private" title="Private: it reads a private server"><Icon name="lock.fill" size={14} label="Private" /></span> : null}
      <div class="glass-group">
        <button type="button" class="glass-btn" aria-label={refreshing ? "Refreshing" : "Refresh"} title="Refresh"
          disabled={!summary || refreshing} aria-busy={refreshing ? "true" : undefined} onClick={() => void refreshView(viewID)}>
          {refreshing ? <Spinner size="small" /> : <Icon name="arrow.clockwise" size={18} />}
        </button>
        <button type="button" class="glass-btn" aria-label={summary?.pinned ? "Unpin" : "Pin"} title={summary?.pinned ? "Unpin" : "Pin"}
          aria-pressed={summary?.pinned === true} disabled={!summary || remote.isMutating.value}
          onClick={() => { if (summary) void setViewPinned(summary, !summary.pinned); }}>
          <Icon name={summary?.pinned ? "pin.slash" : "pin"} size={18} />
        </button>
        <button type="button" class="glass-btn hm-destructive" aria-label="Delete view" title="Delete view" aria-haspopup="dialog"
          disabled={!summary || remote.isMutating.value}
          onClick={() => { if (summary) confirmDeleteView(summary, () => { if (tasksNav.route.value.kind === "view") tasksNav.back(); }); }}>
          <Icon name="trash" size={18} />
        </button>
      </div>
    </PaneBar>
  );

  if (!state?.shown) {
    return (
      <>
        {bar}
        {state?.error && !state.loading ? (
          <Unavailable icon={<Icon name="rectangle.stack" size={56} />} title="View unavailable" error={state.error}
            action={<button type="button" class="btn" onClick={() => setAttempt((value) => value + 1)}>Try Again</button>} />
        ) : (
          <div class="hm-unavailable" role="status"><Spinner size="large" label="Loading the view" /></div>
        )}
      </>
    );
  }
  return (
    <>
      {bar}
      <ScrollArea scrollKey={`view:${viewID}`} saved={tasksNav.savedScroll} onSave={tasksNav.saveScroll} class="hm-view-detail">
        <ErrorLine text={state.error} class="hm-view-banner" />
        {state.shown.view.problems?.length ? (
          <ErrorLine text={state.shown.view.problems.join(" ")} class="hm-view-banner" />
        ) : null}
        <div class="hm-view-card" aria-busy={refreshing ? "true" : undefined}>
          {cardError ? <p class="hm-view-fallback selectable">{state.shown.card.fallbackText ?? "This view couldn't be drawn."}</p>
            : <CardView card={state.shown.card} onAction={onAction} />}
        </div>
      </ScrollArea>
    </>
  );
}
