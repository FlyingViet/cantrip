// Queued messages (CantripQueueView.swift): the composer's "Queued messages (N)" row and the sheet
// that lists prompts the Mac accepted and will run in order, with Send now and Remove.
import "./activity.css";
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import { api, pathComponent } from "../../api/client";
import type { QueuedPrompt, RemoteSessionDetail, RemoteSessionSummary, SessionUpdateResponse } from "../../api/types";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { alertDialog, openMenu, Sheet, Spinner, type MenuEntry } from "../kit";
import { PlanChip } from "../transcript/ChildTabs";
import { MacImage } from "../transcript/Message";
import { promptPages, promptPreview, queuedText, queuePositionLabel } from "./activityLogic";
import { DisconnectedNotice } from "./BackgroundTasksSheet";
import { ArrowUpCircle } from "./glyphs";

const REMOVAL_UNSUPPORTED = "Update and reopen Cantrip on your Mac to remove queued messages from Cantrip Agent.";
const SEND_NOW_UNSUPPORTED = "Update and reopen Cantrip on your Mac to send queued messages now from Cantrip Agent. The message is still queued.";
const CHILD_TABS_UNSUPPORTED = "Update and reopen Cantrip on your Mac to run queued messages in child tabs. The message is still queued.";

function queuedPrompts(session: RemoteSessionSummary): QueuedPrompt[] | undefined {
  return (session as Partial<RemoteSessionDetail>).queued ?? remote.details.value.get(session.id)?.queued;
}

/** "Queued messages (2)" above the composer, with the next prompt's first lines. */
export function QueueButton(props: { session: RemoteSessionSummary; onOpen: () => void }): JSX.Element | null {
  const { session } = props;
  if (session.queuedCount <= 0) return null;
  const next = queuedPrompts(session)?.[0];
  return (
    <button type="button" class="act-queue-button" onClick={props.onOpen} title="View messages waiting to run on your Mac">
      <span class="act-queue-head">
        <Icon name="clock" size={12} />
        <span class="grow">Queued messages ({session.queuedCount})</span>
        <Icon name="chevron.right" size={12} class="act-chevron" />
      </span>
      {next ? <span class="act-queue-preview">{promptPreview(queuedText(next)).preview}</span> : null}
    </button>
  );
}

/** The Mac's prepare step: re-read the tab (cheaply, by revision) and check it still supports the action. */
async function requireCapability(sessionID: string, key: "supportsQueueRemoval" | "supportsQueueSendNow" | "supportsChildTabs", message: string): Promise<void> {
  const cached = remote.details.peek().get(sessionID);
  const query = cached?.historyRevision ? `?revision=${encodeURIComponent(cached.historyRevision)}` : "";
  const data = await api<SessionUpdateResponse>(`/api/v1/sessions/${pathComponent(sessionID)}${query}`, { recent: true });
  let host: RemoteSessionSummary | undefined = cached;
  if ("session" in data) {
    remote.apply(data.session);
    host = data.session;
  }
  if (host?.[key] !== true) throw new Error(message);
}

/** Paged view of a long prompt (PromptReader in PromptTextView.swift). */
function PromptReader(props: { text: string; onClose: () => void }): JSX.Element {
  const pages = promptPages(props.text);
  const [page, setPage] = useState(0);
  return (
    <Sheet title="Full prompt" onClose={props.onClose} width={600} height={560}
      actions={<button type="button" class="btn small" onClick={() => void navigator.clipboard.writeText(props.text)}>Copy all</button>}
      footer={<>
        <button type="button" class="btn" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button>
        <span class="spacer" />
        <span class="caption" aria-live="polite">Page {page + 1}</span>
        <span class="spacer" />
        <button type="button" class="btn" disabled={page >= pages.length - 1} onClick={() => setPage(page + 1)}>Next</button>
        <button type="button" class="btn primary" onClick={props.onClose}>Done</button>
      </>}>
      <div class="act-reader-text selectable" key={page}>{pages[page]}</div>
    </Sheet>
  );
}

function PromptText(props: { text: string; onRead: (text: string) => void }): JSX.Element {
  const { preview, isLong } = promptPreview(props.text);
  return (
    <div class="act-prompt">
      <div class={`act-prompt-text selectable${isLong ? " clipped" : ""}`}>{preview}</div>
      {isLong ? (
        <button type="button" class="act-read-full" title="Only the preview is shortened. The complete prompt is sent."
          onClick={() => props.onRead(props.text)}>
          Read full prompt
        </button>
      ) : null}
    </div>
  );
}

export function QueueSheet(props: { sessionID: string; onClose: () => void }): JSX.Element {
  const { sessionID } = props;
  const [removingID, setRemovingID] = useState<string | null>(null);
  const [sendingID, setSendingID] = useState<string | null>(null);
  const [forkingID, setForkingID] = useState<string | null>(null);
  const [reading, setReading] = useState<string | null>(null);
  const detail = remote.details.value.get(sessionID);
  const summary = sessionID === remote.homeID.value ? remote.homeSummary.value : remote.sessions.value.find((item) => item.id === sessionID);
  const session: RemoteSessionSummary | undefined = detail ?? summary ?? undefined;
  const supportsSendNow = session?.supportsQueueSendNow === true;
  const supportsRemoval = session?.supportsQueueRemoval === true;
  const supportsChildTabs = session?.supportsChildTabs === true;
  const childTabsUnavailable = supportsChildTabs ? session?.childTabsUnavailableReason || null : null;
  const canMutate = remote.isConnected.value && !remote.isMutating.value && removingID === null && sendingID === null && forkingID === null;
  const canRemove = canMutate && supportsRemoval;
  const canSendNow = canMutate && supportsSendNow;
  const canFork = canMutate && supportsChildTabs && !childTabsUnavailable;

  const remove = async (prompt: QueuedPrompt) => {
    if (remote.isMutating.peek()) {
      void alertDialog("Could not remove message", "Wait for the current request to finish, then try removing the message again.");
      return;
    }
    setRemovingID(prompt.id);
    try {
      await requireCapability(sessionID, "supportsQueueRemoval", REMOVAL_UNSUPPORTED);
      await remote.removeQueued(sessionID, prompt.id);
    } catch (error) {
      void alertDialog("Could not remove message",
        (error as Error).message || "Removal could not be confirmed. Check the queue before trying again.");
    } finally {
      setRemovingID(null);
    }
  };

  const sendNow = async (prompt: QueuedPrompt) => {
    if (remote.isMutating.peek()) {
      void alertDialog("Could not send message", "Wait for the current request to finish, then try sending the message again.");
      return;
    }
    setSendingID(prompt.id);
    let sent = false;
    try {
      await requireCapability(sessionID, "supportsQueueSendNow", SEND_NOW_UNSUPPORTED);
      await remote.sendQueuedNow(sessionID, prompt.id);
      sent = true;
    } catch (error) {
      void alertDialog("Could not send message",
        (error as Error).message || "Sending could not be confirmed. Check the conversation before trying again.");
    } finally {
      setSendingID(null);
    }
    // Nothing is left to manage; show the conversation the message went into.
    if (sent && (remote.details.peek().get(sessionID)?.queuedCount ?? 0) === 0) props.onClose();
  };

  // Starts the message now in a child tab under this one; this tab stays open.
  const fork = async (prompt: QueuedPrompt) => {
    if (remote.isMutating.peek()) {
      void alertDialog("Could not start a child tab", "Wait for the current request to finish, then try again.");
      return;
    }
    setForkingID(prompt.id);
    let forked = false;
    try {
      await requireCapability(sessionID, "supportsChildTabs", CHILD_TABS_UNSUPPORTED);
      await remote.forkQueued(sessionID, prompt.id);
      forked = true;
    } catch (error) {
      void alertDialog("Could not start a child tab",
        (error as Error).message || "The child tab could not be confirmed. Check the tab list before trying again.");
    } finally {
      setForkingID(null);
    }
    if (forked && (remote.details.peek().get(sessionID)?.queuedCount ?? 0) === 0) props.onClose();
  };

  const menu = (event: MouseEvent, prompt: QueuedPrompt) => {
    const entries: MenuEntry[] = [];
    if (supportsChildTabs) entries.push({ label: "Run in Child Tab", icon: "arrow.triangle.branch", disabled: !canFork, onSelect: () => void fork(prompt) });
    if (supportsSendNow) entries.push({ label: "Send now", icon: "arrow.up", disabled: !canSendNow, onSelect: () => void sendNow(prompt) });
    if (supportsRemoval) entries.push({ label: "Remove", icon: "trash", destructive: true, disabled: !canRemove, onSelect: () => void remove(prompt) });
    if (!entries.length) return;
    event.preventDefault();
    openMenu({ x: event.clientX, y: event.clientY }, entries, { label: "Queued message" });
  };

  const row = (prompt: QueuedPrompt, index: number) => {
    const text = queuedText(prompt);
    const hint = promptPreview(text).preview.slice(0, 120);
    return (
      <li key={prompt.id} class="act-queue-row" onContextMenu={(event) => menu(event, prompt)}>
        <div class="act-queue-row-head">
          <span class="act-queue-position">{queuePositionLabel(index)}</span>
          <span class="grow" />
          {sendingID === prompt.id ? (
            <span class="act-row-busy"><Spinner label="Sending queued message now" /></span>
          ) : removingID === prompt.id ? (
            <span class="act-row-busy"><Spinner label="Removing queued message" /></span>
          ) : forkingID === prompt.id ? (
            <span class="act-row-busy"><Spinner label="Starting a child tab" /></span>
          ) : (
            <>
              {supportsChildTabs ? (
                <button type="button" class="icon-btn act-row-action child" aria-label="Run in child tab"
                  title={childTabsUnavailable ?? `Run in a child tab (its own tab and branch, merged back when done): ${hint}`}
                  disabled={!canFork} onClick={() => void fork(prompt)}>
                  <Icon name="arrow.triangle.branch" size={16} />
                </button>
              ) : null}
              {supportsSendNow ? (
                <button type="button" class="icon-btn act-row-action" aria-label="Send queued message now" title={`Send now: ${hint}`}
                  disabled={!canSendNow} onClick={() => void sendNow(prompt)}>
                  <ArrowUpCircle size={18} />
                </button>
              ) : null}
              {supportsRemoval ? (
                <button type="button" class="icon-btn act-row-action destructive" aria-label="Remove queued message" title={`Remove: ${hint}`}
                  disabled={!canRemove} onClick={() => void remove(prompt)}>
                  <Icon name="trash" size={16} />
                </button>
              ) : null}
            </>
          )}
        </div>
        {text ? <PromptText text={text} onRead={setReading} /> : null}
        {prompt.plan?.reason ? <PlanChip plan={prompt.plan} /> : null}
        {prompt.images?.length ? (
          <div class="act-gallery">
            {prompt.images.map((image, imageIndex) => (
              <MacImage key={image.id} sessionID={sessionID} image={image} kind="attachment" label={`Attached image ${imageIndex + 1}`} index={imageIndex} />
            ))}
          </div>
        ) : null}
      </li>
    );
  };

  const contents = () => {
    if (!session || session.queuedCount <= 0) {
      return (
        <div class="empty-state act-empty">
          <Icon name="checklist" size={28} />
          <div class="title3">No queued messages</div>
          <p>Accepted prompts appear here while waiting to run.</p>
        </div>
      );
    }
    if (!detail) return <div class="act-loading"><Spinner label="Loading queued messages" /></div>;
    if (!detail.queued) {
      return (
        <div class="empty-state act-empty">
          <Icon name="clock" size={28} />
          <div class="title3">{detail.queuedCount} queued on your Mac</div>
          <p>Update and relaunch Cantrip on your Mac to see the queued message contents.</p>
        </div>
      );
    }
    return (
      <div class="act-content">
        {childTabsUnavailable ? <p class="act-queue-note" role="note">{childTabsUnavailable}</p> : null}
        <ol class="act-queue-list" aria-label="Queued messages">{detail.queued.map(row)}</ol>
        <div class="act-footnotes">
          <p>These prompts are accepted by your Mac and run in order. They move into the conversation when they start.</p>
          {supportsChildTabs ? <p>Run in child tab starts a message now in its own tab under this one, on its own branch, and merges it back when it's done. Each message shows what your Mac suggests.</p> : null}
          {supportsSendNow ? <p>Send now delivers a message without waiting. Work already running keeps going in the background.</p> : null}
          {supportsRemoval
            ? <p>Remove a prompt with the trash button or by right-clicking it. Removing a queued message does not stop the current task.</p>
            : <p>Update and reopen Cantrip on your Mac to remove queued messages here.</p>}
        </div>
      </div>
    );
  };

  return (
    <>
      <Sheet title="Queued messages" onClose={props.onClose} width={600} height={600}
        footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
        <DisconnectedNotice text="Disconnected. Showing the last known queue." />
        {contents()}
      </Sheet>
      {reading !== null ? <PromptReader text={reading} onClose={() => setReading(null)} /> : null}
    </>
  );
}
