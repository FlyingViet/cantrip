// Cards on Cantrip Home's runs, workspaces and records, drawn by the chat's own card renderer (Cards.tsx).
// A card that fails to draw hides only itself, never the run, task or record around it.
import type { JSX } from "preact";
import { useEffect, useErrorBoundary, useState } from "preact/hooks";
import { api } from "../../api/client";
import type { HomeTaskRun, HomeTaskWorkspace, RemoteCardDocument } from "../../api/types";
import { appleDate } from "../../state/format";
import { Spinner } from "../kit";
import { CardStack } from "../transcript/Cards";
import { cardDocuments, RecordCardsPoller, recordCardsLabel, recordCardsPath, type WorkspaceCardsView } from "./homeCardLogic";
import { formatDayTime } from "./homeLogic";
import { RunSummary } from "./parts";

/** Cards under a run's summary or above a workspace's records. */
export function HomeCardStack(props: { cards: RemoteCardDocument[] | undefined; class?: string }): JSX.Element | null {
  const cards = cardDocuments(props.cards);
  if (!cards.length) return null;
  return (
    <div class={`hm-cards${props.class ? ` ${props.class}` : ""}`}>
      <SafeCards cards={cards} />
    </div>
  );
}

function SafeCards(props: { cards: RemoteCardDocument[] }): JSX.Element | null {
  const [error] = useErrorBoundary((caught) => console.warn("Couldn't draw a Home card:", caught));
  return error ? null : <CardStack cards={props.cards} />;
}

/** Above a workspace's records: its own cards, then "Latest run · <time>", that run's summary and cards. */
export function WorkspaceCards(props: { view: WorkspaceCardsView }): JSX.Element {
  const { workspace, latest } = props.view;
  return (
    <div class="hm-workspace-cards">
      {workspace.length ? <HomeCardStack cards={workspace} /> : null}
      {latest ? <LatestRun run={latest.run} cards={latest.cards} /> : null}
    </div>
  );
}

function LatestRun(props: { run: HomeTaskRun; cards: RemoteCardDocument[] }): JSX.Element {
  const { run } = props;
  const finished = Number.isFinite(run.finishedAt) ? formatDayTime(appleDate(run.finishedAt)) : "";
  return (
    <section class="hm-latest-run" aria-label="Latest run">
      <div class="hm-run-meta">{finished ? `Latest run · ${finished}` : "Latest run"}</div>
      {typeof run.summary === "string" && run.summary.trim() ? (
        <RunSummary summary={run.summary} lineLimit={4} class="selectable hm-sheet-summary" />
      ) : null}
      <HomeCardStack cards={props.cards} />
    </section>
  );
}

/** The last cards each record showed, so reopening one shows them at once while they refresh. */
const lastRecordCards = new Map<string, RemoteCardDocument[]>();

function rememberRecordCards(key: string, cards: RemoteCardDocument[]): void {
  lastRecordCards.delete(key);
  lastRecordCards.set(key, cards);
  while (lastRecordCards.size > 24) lastRecordCards.delete(lastRecordCards.keys().next().value!);
}

/**
 * A record's live weather and map cards at the top of its detail: fetched when it opens, again every
 * `refreshAfter` seconds while it stays open (the last cards stay while refreshing or after a failure).
 * `revision` (the record's update time) refetches after an edit.
 */
export function RecordCards(props: {
  taskID: string;
  recordID: string;
  workspace: HomeTaskWorkspace;
  title: string;
  revision: number;
}): JSX.Element | null {
  const key = `${props.taskID}:${props.recordID}`;
  const [state, setState] = useState<{ cards: RemoteCardDocument[]; loaded: boolean; failed: boolean }>(() => {
    const cached = lastRecordCards.get(key);
    return { cards: cached ?? [], loaded: cached !== undefined, failed: false };
  });
  const path = recordCardsPath(props.taskID, props.recordID);

  useEffect(() => {
    if (!path) return;
    const poller = new RecordCardsPoller({
      load: () => api<unknown>(path),
      onCards: (cards) => {
        rememberRecordCards(key, cards);
        setState({ cards, loaded: true, failed: false });
      },
      onError: () => setState((current) => ({ ...current, loaded: true, failed: true })),
    });
    poller.start();
    return () => poller.stop();
  }, [path, key, props.revision]);

  if (!path) return null;
  const empty = !state.cards.length;
  if (empty && state.loaded && !state.failed) return null;
  const what = recordCardsLabel(props.workspace, "").toLowerCase();
  return (
    <section class="hm-record-cards" aria-label={recordCardsLabel(props.workspace, props.title)} aria-busy={!state.loaded ? "true" : undefined}>
      {!empty ? <HomeCardStack cards={state.cards} /> : !state.loaded ? (
        <div class="hm-record-cards-status" role="status"><Spinner size="small" /><span>Loading the {what}…</span></div>
      ) : (
        <div class="hm-record-cards-status">Couldn't load the {what}. Trying again in a minute.</div>
      )}
    </section>
  );
}
