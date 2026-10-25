// Thread tags in Cantrip Home (state/threads.ts): the capsule beside a reply's lane badge (above a
// handoff result card) naming the prompt that started its thread, and the thread it opens below,
// drawn like the child-tab card's tag and thread (ChildTabs.tsx).
import type { JSX } from "preact";
import type { RemoteThread, RemoteThreadTag } from "../../api/types";
import { loadThread, panelID, speaker, tagLabel, threadView, toggleThread, type ThreadView } from "../../state/threads";
import { Icon } from "../icons";
import { mascotDisplayName } from "../pip/prefs";
import { inline } from "./Markdown";

export interface ThreadTagProps {
  sessionID: string;
  /** The tagged message. */
  messageID: string;
  tag: RemoteThreadTag;
}

/** The capsule: reply arrow, the start of the prompt, and a chevron that flips while open. */
export function ThreadTagButton(props: ThreadTagProps): JSX.Element {
  const open = threadView(props.messageID).open;
  return (
    <button type="button" class="thread-tag" aria-expanded={open ? "true" : "false"} aria-controls={panelID(props.messageID)}
      aria-label={tagLabel(props.tag)} onClick={() => toggleThread(props.sessionID, props.messageID, props.tag)}>
      <Icon name="arrow.uturn.backward" size={12} />
      <span class="truncate">{props.tag.prompt}</span>
      <Icon name="chevron.down" size={12} class={`thread-chevron${open ? " flipped" : ""}`} />
    </button>
  );
}

/** The thread below the tag row (hidden while closed, so `aria-controls` always resolves). */
export function ThreadPanel(props: ThreadTagProps): JSX.Element {
  const view = threadView(props.messageID);
  return (
    <div id={panelID(props.messageID)} class="child-thread thread-panel" role="group" aria-label={`Thread: ${props.tag.prompt}`} hidden={!view.open}>
      {view.open ? <ThreadBody {...props} view={view} /> : null}
    </div>
  );
}

function ThreadBody(props: ThreadTagProps & { view: ThreadView }): JSX.Element {
  const load = props.view.load;
  if (load?.state === "failed") {
    return (
      <div class="thread-failed">
        <p class="child-note selectable" role="alert">Couldn't load this thread: {load.error}</p>
        <button type="button" class="btn small" onClick={() => void loadThread(props.sessionID, props.messageID, props.tag.id)}>Try again</button>
      </div>
    );
  }
  if (load?.state !== "loaded") return <p class="child-note" role="status">Loading the thread…</p>;
  return <ThreadMessages thread={load.thread} assistantName={mascotDisplayName.value} />;
}

/** The prompt as a bubble, then each earlier message: answers on the right, Pip's (and cards') on the left, named and clamped to 3 lines. */
export function ThreadMessages(props: { thread: RemoteThread; assistantName: string }): JSX.Element {
  const { thread } = props;
  return (
    <>
      <p class="child-prompt selectable">{thread.prompt.text}</p>
      {thread.hasEarlier ? <p class="child-note">Earlier messages in this thread aren't shown.</p> : null}
      {thread.messages.map((message, index) => message.role === "user" ? (
        <p key={message.id || index} class="child-prompt selectable">{message.text}</p>
      ) : (
        <div key={message.id || index} class="child-reply thread-reply">
          <span class="child-who">{speaker(message, props.assistantName)}</span>
          {/* Paragraph breaks become line breaks, so the 3 lines show text rather than a blank line. */}
          <div class="thread-bubble">
            <p class="selectable">{inline(message.text.replace(/\n\s*\n/g, "\n"), null, `m${index}`)}</p>
          </div>
        </div>
      ))}
    </>
  );
}
