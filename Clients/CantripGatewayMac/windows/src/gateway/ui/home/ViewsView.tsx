// Home's Views (docs/views.md, CantripHomeViewsSection): a grid of thumbnails above Tasks (pinned first, a lock on
// private views), each drawing a few of the view's blocks with the chat's card renderer, and a view's screen, its
// card drawn by the same renderer with Refresh, Pin and Delete, fetched again every `refreshAfter` seconds while it
// stays open.
import type { JSX } from "preact";
import { useEffect, useErrorBoundary, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import type { HomeViewSummary } from "../../api/types";
import { now } from "../../state/clock";
import * as remote from "../../state/remote";
import {
  supportsViews, ThumbnailLoader, VIEW_GRID_COMPACT_WIDTH, viewColumns, viewProblem, viewRowLabel, viewSubtitle, ViewPoller,
  type CachedView,
} from "../../state/views";
import { Icon } from "../icons";
import { confirmDialog, Spinner, type MenuEntry } from "../kit";
import { CardView } from "../transcript/Cards";
import { previewBlocks } from "../transcript/cardLogic";
import { contextMenuAt, ErrorLine, PaneBar, ScrollArea, SectionHeading, Unavailable } from "./parts";
import { SymbolIcon } from "./symbols";
import * as tasksNav from "./tasksNav";
import {
  applyShown, closeView, deleteView, fetchView, loadFailed, openView, refreshView, setViewPinned, showView, viewActionHandler,
  viewDetails,
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

/** "Views" above the tasks: a collapsible heading over the thumbnail grid. */
export function ViewsSection(): JSX.Element | null {
  const views = listedViews();
  const error = supportsViews(remote.homeTasks.value) ? remote.homeViewsError.value : null;
  if (!views.length && !error) return null;
  const collapsed = tasksNav.sectionCollapsed("views");
  return (
    <section class="hm-views" aria-labelledby="hm-views-title">
      <SectionHeading id="hm-views-title" title="Views" count={views.length} noun={["view", "views"]} collapsed={collapsed}
        controls="hm-views-body" onToggle={() => tasksNav.toggleSection("views")} />
      <div id="hm-views-body" class="hm-section-body" hidden={collapsed}>
        {collapsed ? null : (
          <>
            <ErrorLine text={error} class="hm-views-error" />
            {views.length ? <ViewsGrid views={views} /> : null}
          </>
        )}
      </div>
    </section>
  );
}

/** The grid: as many columns as fit its width (`viewColumns`), each view's thumbnail kept current while it shows. */
function ViewsGrid(props: { views: HomeViewSummary[] }): JSX.Element {
  const { views } = props;
  const ref = useRef<HTMLUListElement>(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return undefined;
    setWidth(element.clientWidth);
    const observer = new ResizeObserver((entries) => setWidth(entries[entries.length - 1].contentRect.width));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const loader = useMemo(() => new ThumbnailLoader({
    load: fetchView,
    cached: (id) => viewDetails.peek().get(id),
    onView: (id, shown) => applyShown(id, shown),
  }), []);
  useEffect(() => {
    const visibility = () => (document.visibilityState === "hidden" ? loader.pause() : loader.resume());
    document.addEventListener("visibilitychange", visibility);
    return () => {
      document.removeEventListener("visibilitychange", visibility);
      loader.stop();
    };
  }, [loader]);
  useEffect(() => { loader.update(views); }, [loader, views]);

  const details = viewDetails.value;
  // Each preview is redrawn only when its view's answer changes, not with every tick of the clock.
  const previews = useRef(new Map<string, { cached: CachedView | undefined; node: JSX.Element }>());
  const preview = (view: HomeViewSummary): JSX.Element => {
    const cached = details.get(view.id);
    const kept = previews.current.get(view.id);
    if (kept && kept.cached === cached) return kept.node;
    const node = <ViewPreview cached={cached} />;
    previews.current.set(view.id, { cached, node });
    return node;
  };
  return (
    <ViewTiles views={views} columns={viewColumns(width)} compact={width < VIEW_GRID_COMPACT_WIDTH} at={new Date(now.value)}
      preview={preview} listRef={ref} />
  );
}

/** The tiles in `columns` equal columns: drawn from the summaries alone, with each view's preview from `preview`. */
export function ViewTiles(props: {
  views: HomeViewSummary[];
  columns: number;
  compact: boolean;
  at: Date;
  preview: (view: HomeViewSummary) => JSX.Element;
  listRef?: { current: HTMLUListElement | null };
}): JSX.Element {
  return (
    <ul ref={props.listRef} class={`hm-view-grid${props.compact ? " compact" : ""}`} aria-label="Views"
      style={{ gridTemplateColumns: `repeat(${props.columns}, minmax(0, 1fr))` }}>
      {props.views.map((view) => <ViewTile key={view.id} view={view} at={props.at} preview={props.preview(view)} />)}
    </ul>
  );
}

/**
 * One view's thumbnail. The whole tile opens it: its button carries the row's label and stretches over the preview,
 * which only shows (no pointer, no focus, hidden from screen readers).
 */
export function ViewTile(props: { view: HomeViewSummary; at: Date; preview: JSX.Element }): JSX.Element {
  const { view, at } = props;
  const problem = view.refreshing === true ? null : viewProblem(view);
  return (
    <li class="hm-view-tile">
      <button type="button" class="hm-view-open" data-focus-key={`view:${view.id}`} data-id={`home.view.${view.id}`}
        aria-label={viewRowLabel(view, at)} onClick={() => openViewScreen(view)}
        onContextMenu={(event) => contextMenuAt(event, viewMenu(view), `${view.name} actions`)}>
        <span class="hm-view-title">
          <span class="hm-view-icon accent"><SymbolIcon name={view.icon ?? "rectangle.stack"} size={18} /></span>
          <span class="hm-view-name">{view.name}</span>
          {view.pinned ? <span class="hm-view-mark" title="Pinned"><Icon name="pin" size={12} /></span> : null}
          {view.private ? <span class="hm-view-mark" title="Private: it reads a private server"><Icon name="lock.fill" size={12} /></span> : null}
        </span>
        <span class="hm-view-subtitle">{viewSubtitle(view, at)}</span>
      </button>
      <div class="hm-view-preview" inert aria-hidden="true">{props.preview}</div>
      {view.refreshing === true ? <div class="hm-view-status" aria-hidden="true">Refreshing…</div>
        : problem ? <div class="hm-view-status warning" aria-hidden="true"><Icon name="exclamationmark.triangle" size={12} /><span class="hm-view-status-text">{problem}</span></div>
          : null}
    </li>
  );
}

/** A thumbnail's preview: the blocks `previewBlocks` picks, drawn by the card renderer at 60%; a quiet placeholder
 *  until the view has loaded (or when it has nothing to preview). */
export function ViewPreview(props: { cached: CachedView | undefined }): JSX.Element {
  const card = props.cached?.shown.card;
  const blocks = card ? previewBlocks(card) : [];
  if (!card || !blocks.length) {
    return (
      <div class={`hm-view-placeholder${card ? "" : " loading"}`}>
        <span /><span /><span />
      </div>
    );
  }
  // No source: a thumbnail has no footer (when it was read, or an attribution link).
  return (
    <div class="hm-view-preview-scale">
      <CardView card={{ ...card, blocks, source: undefined }} />
    </div>
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
