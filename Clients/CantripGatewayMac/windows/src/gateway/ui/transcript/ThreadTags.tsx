// Thread tags in Cantrip Home (state/threads.ts), drawn like inline replies in Messages (CantripThreadTags.swift):
// above a reply from another thread, a small copy of the prompt that started it, joined to the reply's lane badge
// by a curved line through the margin, which the rows after it in that thread share (`threadLines`); "N Replies"
// under a prompt whose replies got split up; and the open thread over the blurred window.
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useRef } from "preact/hooks";
import type { RemoteThread, RemoteThreadTag } from "../../api/types";
import * as remote from "../../state/remote";
import {
  closeThread, loadThread, openThread, repliesLabel, showThread, speaker, tagLabel, threadLoad,
  type ThreadFocus, type ThreadLoad,
} from "../../state/threads";
import { Icon } from "../icons";
import { mascotDisplayName } from "../pip/prefs";
import { plainMentions } from "../../state/tabMentions";
import { Markdown } from "./Markdown";
import { MentionText } from "./TabMentions";

export interface ThreadQuoteProps {
  sessionID: string;
  /** The tagged reply. */
  messageID: string;
  tag: RemoteThreadTag;
  /** The reply's lane badge, which the line turns into; cards have none. */
  children?: ComponentChildren;
  /** Later rows share this quote's line, so it runs on past the badge instead of turning into it. */
  continues?: boolean;
}

/** A reply's head: the quoted prompt on the right, the line running from it through the margin into the lane row. */
export function ThreadQuote(props: ThreadQuoteProps): JSX.Element {
  const open = () => showThread({ sessionID: props.sessionID, threadID: props.tag.id, prompt: props.tag.prompt, messageID: props.messageID });
  return (
    <div class="thread-head">
      <div class="thread-quote-row">
        <span class="thread-arm" aria-hidden="true" />
        <button type="button" class="thread-quote" aria-label={`${tagLabel(props.tag)}. Opens the thread`} title="Open the thread" onClick={open}>
          <span class="thread-quote-text">{plainMentions(props.tag.prompt)}</span>
        </button>
      </div>
      <ThreadLaneRow continues={props.continues}>{props.children}</ThreadLaneRow>
    </div>
  );
}

/** The row a thread line turns into (or, continuing, runs past): a reply's lane badge, or a short space above a card. */
export function ThreadLaneRow(props: { children?: ComponentChildren; continues?: boolean }): JSX.Element {
  return <div class={`thread-lane-row${props.continues ? " continues" : ""}`}>{props.children ?? <span class="thread-spacer" />}</div>;
}

/** "N Replies ›" under a prompt whose replies other messages split up. */
export function ThreadRepliesButton(props: { sessionID: string; promptID: string; prompt: string; count: number }): JSX.Element {
  const label = repliesLabel(props.count);
  return (
    <button type="button" class="thread-replies" aria-label={`${label}. Opens the thread`}
      onClick={() => showThread({ sessionID: props.sessionID, threadID: props.promptID, prompt: props.prompt, messageID: null })}>
      {label}<Icon name="chevron.right" size={12} />
    </button>
  );
}

/** The open thread over the blurred window: the prompt, then every message in it, whole. */
export function ThreadView(): JSX.Element | null {
  const focus = openThread.value;
  const selected = remote.selectedSession.value;
  const load = focus ? threadLoad(focus.threadID) : undefined;
  const closeRef = useRef<HTMLButtonElement>(null);
  const bodyRef = useRef<HTMLDivElement>(null);
  const restore = useRef<HTMLElement | null>(null);
  const revision = useRef<string | undefined>(undefined);
  const scrolled = useRef<string | null>(null);
  const key = focus ? `${focus.sessionID}/${focus.threadID}/${focus.messageID ?? ""}` : null;

  useEffect(() => {
    if (!key) return;
    restore.current = document.activeElement as HTMLElement | null;
    revision.current = selected?.historyRevision;
    scrolled.current = null;
    requestAnimationFrame(() => closeRef.current?.focus());
  }, [key]);

  // The open thread follows its conversation; opening another tab closes it.
  useEffect(() => {
    if (!focus) return;
    if (selected?.id !== focus.sessionID) {
      closeThread();
      return;
    }
    if (selected.historyRevision === revision.current) return;
    revision.current = selected.historyRevision;
    void loadThread(focus.sessionID, focus.threadID);
  }, [focus, selected?.id, selected?.historyRevision]);

  // Opened from a reply: just far enough to show it, so the prompt stays in view when it fits.
  useEffect(() => {
    if (!focus?.messageID || load?.state !== "loaded" || scrolled.current === focus.messageID) return;
    const node = bodyRef.current?.querySelector(`[data-message-id="${focus.messageID}"]`);
    if (!node) return;
    scrolled.current = focus.messageID;
    node.scrollIntoView({ block: "nearest" });
  }, [load, focus?.messageID]);

  if (!focus) return null;
  const close = () => {
    closeThread();
    restore.current?.focus?.();
  };
  const count = load?.state === "loaded" ? load.thread.replyCount ?? load.thread.messages.length : null;
  return (
    <div class="thread-view" role="dialog" aria-modal="true" aria-labelledby="thread-view-title"
      onKeyDown={(event) => { if (event.key === "Escape") { event.stopPropagation(); close(); } }}
      onClick={(event) => { if (event.target === event.currentTarget) close(); }}>
      <div class="thread-view-column">
        <div class="thread-view-bar">
          <div class="thread-view-heading">
            <h2 id="thread-view-title">Thread</h2>
            {count != null ? <span>{repliesLabel(count)}</span> : null}
          </div>
          <button ref={closeRef} type="button" class="thread-view-close" aria-label="Close thread" title="Close (Esc)" onClick={close}>✕</button>
        </div>
        <div ref={bodyRef} class="thread-view-body">
          <ThreadBody focus={focus} load={load} assistantName={mascotDisplayName.value} />
        </div>
      </div>
    </div>
  );
}

export function ThreadBody(props: { focus: ThreadFocus; load: ThreadLoad | undefined; assistantName: string }): JSX.Element {
  const { focus, load } = props;
  if (load?.state === "loaded") return <ThreadMessages thread={load.thread} assistantName={props.assistantName} />;
  return (
    <>
      <p class="thread-mine selectable"><MentionText text={focus.prompt} /></p>
      {load?.state === "failed" ? (
        <div class="thread-failed">
          <p class="child-note selectable" role="alert">Couldn't load this thread: {load.error}</p>
          <button type="button" class="btn small" onClick={() => void loadThread(focus.sessionID, focus.threadID)}>Try again</button>
        </div>
      ) : <p class="child-note thread-note" role="status">Loading the thread…</p>}
    </>
  );
}

/** The prompt and the user's answers as blue bubbles on the right; Pip's (and cards') as gray bubbles on the left, named. */
export function ThreadMessages(props: { thread: RemoteThread; assistantName: string }): JSX.Element {
  const { thread } = props;
  return (
    <>
      <p class="thread-mine selectable" data-message-id={thread.prompt.id}><MentionText text={thread.prompt.text} /></p>
      {thread.hasEarlier ? <p class="child-note thread-note">Earlier messages in this thread aren't shown.</p> : null}
      {thread.messages.map((message, index) => message.role === "user" ? (
        <p key={message.id || index} class="thread-mine selectable" data-message-id={message.id}><MentionText text={message.text} /></p>
      ) : (
        <div key={message.id || index} class="thread-theirs" data-message-id={message.id}>
          <span class="child-who">{speaker(message, props.assistantName)}</span>
          <div class="thread-bubble"><Markdown text={message.text} remoteImages={false} /></div>
        </div>
      ))}
    </>
  );
}
