// Input requests in chat (CantripInputRequests.swift): the question panel above the composer, and
// approval / sign-in / local-action cards in the transcript. Passwords go to the secure sheet.
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import type { InputDecision, InputRequest, RemoteSessionSummary } from "../../api/types";
import { bridge } from "../../bridge";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { openMenu, toast } from "../kit";
import { Markdown } from "./Markdown";
import { MacImage, inlineImages } from "./Message";

export function pendingInputs(session: RemoteSessionSummary | null): InputRequest[] {
  return session?.pendingInputs ?? [];
}

/** The question a chat reply answers: the one the user picked, else the first. */
export function chatQuestion(session: RemoteSessionSummary | null): InputRequest | null {
  const questions = pendingInputs(session).filter((request) => request.kind === "question");
  const chosen = nav.chosenQuestion.value;
  return (chosen && chosen.sessionID === session?.id ? questions.find((request) => request.id === chosen.requestID) : undefined) ?? questions[0] ?? null;
}

export function composerPlaceholder(question: InputRequest | null, recipient: string): string {
  if (nav.deliveryMode.value !== "auto" || !question) return `Message ${recipient}…`;
  return question.allowsFreeform ? "Your reply…" : "Choose an answer above…";
}

export function composerAcceptsText(question: InputRequest | null): boolean {
  return nav.deliveryMode.value !== "auto" || question?.allowsFreeform !== false;
}

async function respond(
  sessionID: string, request: InputRequest, decision: InputDecision, text?: string, onError?: (message: string) => void,
): Promise<boolean> {
  if (Date.now() / 1000 >= request.expiresAt) {
    const message = "This request expired on the Mac.";
    if (onError) onError(message); else toast(message);
    return false;
  }
  try {
    await remote.answerInput(sessionID, request.id, decision === "submit" ? { decision, text } : { decision });
    return true;
  } catch (error) {
    const message = `${(error as Error).message} Not retried. Refresh before responding again.`;
    if (onError) onError(message); else toast(message);
    return false;
  }
}

/** A standalone preview image line (with an optional bold/heading label above it) becomes a tile. */
function questionParts(request: InputRequest, sessionID: string) {
  const images = request.images ?? [];
  const byID = new Map(images.map((image) => [image.id, image]));
  const lines = ((byID.size && request.displayText) || request.detail || "").split("\n");
  const removed = new Set<number>();
  const tiles: { image: (typeof images)[number]; caption: string }[] = [];
  lines.forEach((line, index) => {
    const match = line.match(/^ {0,3}!\[[^\]]*\]\(cantrip-preview:\/\/image\/([^)\s]+)\)\s*$/);
    const image = match ? byID.get(match[1]) : undefined;
    if (!image) return;
    removed.add(index);
    let above = index - 1;
    while (above >= 0 && !lines[above].trim()) above--;
    let caption = (image.altText || "").trim();
    const label = above >= 0 && !removed.has(above) && lines[above].match(/^ {0,3}(?:#{1,6}[ \t]+(.+?)[ \t]*#*|\*\*([^*]+)\*\*|__([^_]+)__)[ \t]*\r?$/);
    if (label) {
      const text = (label[1] || label[2] || label[3]).trim().replace(/:$/, "");
      if (text) { removed.add(above); caption = text; }
    }
    if (!tiles.some((tile) => tile.image === image)) tiles.push({ image, caption: caption || "Image" });
  });
  return { text: lines.filter((_, index) => !removed.has(index)).join("\n").trim(), tiles, images };
}

export function InputDetail(props: { request: InputRequest; sessionID: string; verbatimClass?: string }): JSX.Element | null {
  const { request, sessionID } = props;
  if (request.kind !== "question") {
    return request.detail ? <div class={`input-verbatim selectable${props.verbatimClass ? ` ${props.verbatimClass}` : ""}`}>{request.detail}</div> : null;
  }
  const parts = questionParts(request, sessionID);
  return (
    <div class="input-detail">
      {parts.text ? <Markdown text={parts.text} images={inlineImages(sessionID, parts.images)} /> : null}
      {parts.tiles.length ? (
        <div class="input-images" role="group" aria-label={parts.tiles.length === 1 ? "Image" : `${parts.tiles.length} images`}>
          {parts.tiles.map((tile) => (
            <figure key={tile.image.id} class="input-image">
              <MacImage sessionID={sessionID} image={tile.image} kind="input" label={tile.caption} />
              <figcaption>{tile.caption}</figcaption>
            </figure>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** The "Reply to …" panel above the composer for the current question. */
export function QuestionPanel(props: { session: RemoteSessionSummary; question: InputRequest; busy: boolean; maxHeight: number }): JSX.Element {
  const { session, question } = props;
  const questions = pendingInputs(session).filter((request) => request.kind === "question");
  const index = Math.max(0, questions.findIndex((request) => request.id === question.id));
  const expired = Date.now() / 1000 >= question.expiresAt;
  const disabled = props.busy || expired;
  return (
    <div class="question-panel" style={{ maxHeight: `${props.maxHeight}px` }} data-id="cantrip.input.composer">
      <div class="question-head">
        <span class="caption muted strong grow">Reply to {question.source}</span>
        {questions.length > 1 ? (
          <button type="button" class="btn plain small mono-digits" aria-label="Choose pending question"
            onClick={(event) => openMenu(event.currentTarget as HTMLElement, questions.map((request) => ({
              label: request.title || request.detail.slice(0, 80), checked: request.id === question.id,
              onSelect: () => { nav.chosenQuestion.value = { sessionID: session.id, requestID: request.id }; },
            })), { label: "Pending questions" })}>
            {index + 1}/{questions.length}
          </button>
        ) : null}
        <button type="button" class="icon-btn" aria-label="Cancel question" title="Cancel question" disabled={disabled}
          onClick={() => void respond(session.id, question, "cancel")}>
          <Icon name="xmark" size={14} />
        </button>
      </div>
      <InputDetail request={question} sessionID={session.id} />
      {question.choices.map((choice, choiceIndex) => (
        <button key={choiceIndex} type="button" class="input-choice" disabled={disabled} data-id={`cantrip.input.choice.${choiceIndex}`}
          onClick={() => void respond(session.id, question, "submit", choice)}>
          {choice}
        </button>
      ))}
      {nav.deliveryMode.value !== "auto" ? <p class="caption muted">Switch delivery to Auto to send a typed reply to this question.</p> : null}
      {expired ? <p class="caption orange">This question expired on the Mac.</p> : null}
    </div>
  );
}

/** Approvals, sign-ins and local actions in the transcript; passwords open the secure sheet. */
export function InputTranscript(props: { session: RemoteSessionSummary }): JSX.Element | null {
  const requests = pendingInputs(props.session).filter((request) => request.kind !== "question");
  if (!requests.length) return null;
  return (
    <div class="input-transcript" data-id="cantrip.input.inline">
      {requests.map((request) => request.kind === "secret" ? (
        <button key={request.id} type="button" class="btn large secure-input"
          onClick={() => { nav.sheet.value = { kind: "inputRequests", sessionID: props.session.id }; }}>
          <Icon name="lock.shield.fill" />Enter password or passphrase securely
        </button>
      ) : <InputCard key={request.id} request={request} sessionID={props.session.id} busy={remote.isMutating.value} />)}
    </div>
  );
}

export function InputCard(props: {
  request: InputRequest;
  sessionID: string;
  busy: boolean;
  /** After the Mac accepted an answer; `decision` is what was sent. */
  onAnswered?: (decision: InputDecision) => void;
  /** Shows the failure inline instead of a toast. */
  onError?: (message: string) => void;
}): JSX.Element {
  const { request, sessionID } = props;
  const [text, setText] = useState("");
  const disabled = props.busy || Date.now() / 1000 >= request.expiresAt;
  const answer = async (decision: InputDecision) => {
    const reply = request.kind === "question" ? text.trim() : text;
    setText("");
    if (await respond(sessionID, request, decision, decision === "submit" ? reply : undefined, props.onError)) props.onAnswered?.(decision);
  };
  let url: URL | null = null;
  try { url = request.url ? new URL(request.url) : null; } catch { url = null; }
  return (
    <section class="input-card" aria-label={`${request.source}: ${request.title}`}>
      <strong class="headline">{request.title}</strong>
      <span class="caption muted">{request.source}</span>
      <InputDetail request={request} sessionID={sessionID} />
      {request.kind === "secret" ? (
        <>
          <input type="password" class="text-field" autocomplete="off" spellcheck={false} aria-label="Password or passphrase"
            placeholder="Password or passphrase" value={text} disabled={disabled} onInput={(event) => setText((event.target as HTMLInputElement).value)}
            onKeyDown={(event) => { if (event.key === "Enter" && text) void answer("submit"); }} />
          <p class="caption muted">Sent only to the verified waiting program on the Mac. Not added to chat or saved by Cantrip.</p>
        </>
      ) : null}
      {request.kind === "question" ? (
        <>
          {request.choices.map((choice) => <button key={choice} type="button" class="btn" disabled={disabled} onClick={() => void respond(sessionID, request, "submit", choice, props.onError).then((ok) => ok && props.onAnswered?.("submit"))}>{choice}</button>)}
          {request.allowsFreeform ? (
            <textarea class="text-field" rows={2} aria-label={`Answer: ${request.title}`} placeholder="Your answer" value={text} disabled={disabled}
              onInput={(event) => setText((event.target as HTMLTextAreaElement).value)} />
          ) : null}
        </>
      ) : null}
      {url && url.protocol === "https:" ? (
        <>
          {request.code ? <div class="mono selectable">Device code: {request.code}</div> : null}
          <a href={url.href} onClick={(event) => { event.preventDefault(); bridge.openExternal(url!.href); }}>Open {url.host || "sign-in page"}</a>
          <p class="caption">Finish sign-in in your browser and return here. Account passwords stay on the provider's site.</p>
        </>
      ) : null}
      <div class="row wrap input-actions">
        <button type="button" class="btn" disabled={disabled} onClick={() => void answer("cancel")}>Cancel</button>
        {request.kind === "approval" ? (
          <>
            <button type="button" class="btn destructive" disabled={disabled} onClick={() => void answer("deny")}>Deny</button>
            <button type="button" class="btn primary" disabled={disabled} onClick={() => void answer("approve")}>Approve once</button>
          </>
        ) : request.kind === "secret" ? (
          <button type="button" class="btn primary" disabled={disabled || !text} onClick={() => void answer("submit")}>Submit</button>
        ) : request.kind === "question" ? (
          request.allowsFreeform ? <button type="button" class="btn primary" disabled={disabled || !text.trim()} onClick={() => void answer("submit")}>Send</button> : null
        ) : (
          <button type="button" class="btn" disabled={disabled} onClick={() => void answer("approve")}>{request.kind === "login" ? "I've signed in" : "Done on Mac"}</button>
        )}
      </div>
    </section>
  );
}
