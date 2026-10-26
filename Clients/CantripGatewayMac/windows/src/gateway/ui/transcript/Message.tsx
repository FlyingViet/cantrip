// One transcript row (Hermes TurnView): prompt bubbles, replies with their lane badge, reasoning steps,
// MCP apps, finished subagents placed where they ended, handoff cards, errors and fresh-start dividers.
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { cachedImage, loadImage } from "../../api/client";
import type {
  MessageImageRef, PromptUsage, RemoteDelegation, RemoteHandoffResult, RemoteMessage, RemoteReasoningStep,
  RemoteSessionSummary, RemoteSubagent,
} from "../../api/types";
import { now } from "../../state/clock";
import { clockTime, compactTokens, elapsed, isBusy, subagentLive } from "../../state/format";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { threadReplies, threadTag, type ThreadLine } from "../../state/threads";
import { SubagentStack } from "../activity/Subagents";
import { Icon, StatusIcon } from "../icons";
import { Spinner, toast } from "../kit";
import { openViewer } from "../viewer";
import { ChildResultCard } from "./ChildTabs";
import { MCPAppStack } from "./MCPApp";
import { Markdown, type InlineImages } from "./Markdown";
import { ThreadLaneRow, ThreadQuote, ThreadRepliesButton } from "./ThreadTags";

export type Lane = "home" | "tab";

// MARK: Images

/** A Mac image (generated preview or attachment) loaded through the API as a thumbnail. */
export function MacImage(props: { sessionID: string; image: MessageImageRef; label: string; kind: "preview" | "attachment" | "input"; index?: number }): JSX.Element {
  const { sessionID, image } = props;
  const key = `${sessionID}:${image.id}:thumb`;
  const [src, setSrc] = useState<string | null>(cachedImage(key) ?? null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const ref = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (src) return;
    let live = true;
    const start = () => loadImage(sessionID, image.id).then((url) => { if (live) setSrc(url); }, (failure: Error) => { if (live) setError(failure.message); });
    // Load when close to the viewport, like the web client.
    const node = ref.current;
    if (!node || !("IntersectionObserver" in window)) { void start(); return () => { live = false; }; }
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) { observer.disconnect(); void start(); }
    }, { rootMargin: "900px 0px" });
    observer.observe(node);
    return () => { live = false; observer.disconnect(); };
  }, [sessionID, image.id, attempt]);

  const open = () => {
    if (src) openViewer({ title: props.label, placeholder: src, load: () => loadImage(sessionID, image.id, true) });
    else if (error) { setError(null); setAttempt((value) => value + 1); }
  };
  return (
    <button ref={ref} type="button" class={`mac-image ${props.kind}${error ? " failed" : ""}`} onClick={open}
      aria-label={error ? `${props.label}. Could not load. Activate to retry.` : src ? `${props.label}. View full image.` : `${props.label}. Loading.`}
      title={error ?? undefined}>
      {src ? <img src={src} alt="" /> : error ? (
        props.kind === "preview" ? (
          <span class="mac-image-error"><span class="row"><Icon name="photo" /> Preview unavailable</span><span>{error}</span><strong>Click to retry</strong></span>
        ) : <span class="mac-image-error small"><Icon name="photo" /><span class="caption">Retry</span></span>
      ) : props.kind === "preview" ? <span class="mac-image-loading"><Spinner /> Loading preview…</span> : <Spinner />}
    </button>
  );
}

function ImageGallery(props: { sessionID: string; images: MessageImageRef[] }): JSX.Element | null {
  if (!props.images.length) return null;
  return (
    <div class="image-gallery">
      {props.images.map((image, index) => (
        <MacImage key={image.id} sessionID={props.sessionID} image={image} kind="attachment" label={`Attached image ${index + 1}`} index={index} />
      ))}
    </div>
  );
}

export function inlineImages(sessionID: string, images: MessageImageRef[] | undefined): InlineImages | null {
  if (!images?.length) return null;
  return {
    sessionID,
    images: new Map(images.map((image) => [image.id, image])),
    render: (image, alt) => <MacImage sessionID={sessionID} image={image} kind="preview" label={alt || image.altText || "Generated image"} />,
    link: (image, children) => (
      <button type="button" class="preview-link" onClick={() => openViewer({
        title: image.altText || "Preview", placeholder: cachedImage(`${sessionID}:${image.id}:thumb`),
        load: () => loadImage(sessionID, image.id, true),
      })}>{children}</button>
    ),
  };
}

// MARK: Prompts

const PREVIEW_LIMIT = 1200;

function PromptText(props: { text: string }): JSX.Element {
  const long = props.text.length > PREVIEW_LIMIT;
  const preview = long ? props.text.slice(0, PREVIEW_LIMIT) : props.text;
  return (
    <div class="prompt-text">
      <div class={`selectable${long ? " clipped" : ""}`}>{preview}</div>
      {long ? (
        <button type="button" class="read-full" title="Only the preview is shortened. The complete prompt is sent."
          onClick={() => { nav.sheet.value = { kind: "promptReader", title: "Full prompt", text: props.text }; }}>
          Read full prompt
        </button>
      ) : null}
    </div>
  );
}

function usageSummary(usage: PromptUsage): string {
  if (usage.contextTokens != null) {
    const limit = usage.contextLimit && usage.contextLimit > 0 ? ` · ${percent(usage.contextTokens, usage.contextLimit)} of ${compactTokens(usage.contextLimit)}` : "";
    return `${compactTokens(usage.contextTokens)} tokens of context${limit}`;
  }
  if (usage.messageTokens != null) return `About ${compactTokens(usage.messageTokens)} tokens sent`;
  return `${compactTokens(usage.inputTokens || 0)} input tokens`;
}

function percent(part: number, whole: number): string {
  if (!(whole > 0)) return "0%";
  const value = (part / whole) * 100;
  return value > 0 && value < 1 ? "<1%" : `${Math.round(value)}%`;
}

const USAGE_FOOTNOTE = "Token counts come from the model provider. “This message” includes memory and context Cantrip added, estimated at about 4 characters per token. Run totals include subagents and every step’s model call.";

function PromptUsageLine(props: { usage: PromptUsage }): JSX.Element {
  const [open, setOpen] = useState(false);
  const u = props.usage;
  const n = (value: number) => value.toLocaleString();
  const sent = [
    u.contextTokens != null && ["Total", n(u.contextTokens) + (u.contextLimit && u.contextLimit > 0 ? ` of ${n(u.contextLimit)}` : "")],
    u.systemTokens != null && ["System instructions", n(u.systemTokens)],
    u.toolTokens != null && ["Tool definitions", n(u.toolTokens)],
    u.conversationTokens != null && ["Conversation", n(u.conversationTokens)],
    u.messageTokens != null && ["This message", `≈ ${n(u.messageTokens)}`],
    u.messageTokens != null && (u.addedTokens ?? 0) > 0 && ["Added by Cantrip", `≈ ${n(u.addedTokens!)}`],
  ].filter(Boolean) as [string, string][];
  const run: [string, string][] = [];
  if (u.modelCalls > 0) {
    run.push(["Model calls", n(u.modelCalls)],
      ["Input tokens", n(u.inputTokens) + (u.inputTokens > 0 && u.cachedInputTokens > 0 ? ` (${percent(u.cachedInputTokens, u.inputTokens)} cached)` : "")],
      ["Output tokens", n(u.outputTokens)]);
  }
  if (u.latestContextTokens != null && u.latestContextTokens !== u.contextTokens) run.push(["Latest context", n(u.latestContextTokens)]);
  return (
    <Popover open={open} onClose={() => setOpen(false)} align="end" anchor={
      <button type="button" class="usage-line" aria-label={`Prompt context: ${usageSummary(u)}`} aria-expanded={open ? "true" : "false"}
        title="Shows the token breakdown" onClick={() => setOpen(!open)}>
        <Icon name="gauge.with.dots.needle.33percent" size={12} />
        <span>{usageSummary(u)}</span>
      </button>
    }>
      <div class="usage-details">
        {[["When sent", sent], ["This run", run] as const].map(([title, rows]) => (rows as [string, string][]).length ? (
          <div key={title as string} class="usage-section">
            <div class="usage-title">{title as string}</div>
            {(rows as [string, string][]).map(([label, value]) => <div key={label} class="usage-row"><span>{label}</span><span class="mono-digits">{value}</span></div>)}
          </div>
        ) : null)}
        <p class="caption muted">{USAGE_FOOTNOTE}</p>
      </div>
    </Popover>
  );
}

/** A small popover panel anchored under its button; Escape or a click outside closes it. */
export function Popover(props: { open: boolean; onClose: () => void; anchor: JSX.Element; children: ComponentChildren; align?: "start" | "end" }): JSX.Element {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!props.open) return;
    const onDown = (event: PointerEvent) => { if (!ref.current?.contains(event.target as Node)) props.onClose(); };
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); props.onClose(); } };
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey, true);
    return () => { document.removeEventListener("pointerdown", onDown, true); document.removeEventListener("keydown", onKey, true); };
  }, [props.open]);
  return (
    <span class="popover-anchor" ref={ref}>
      {props.anchor}
      {props.open ? <div class={`popover ${props.align ?? "start"}`} role="dialog">{props.children}</div> : null}
    </span>
  );
}

// MARK: Replies

function LaneBadge(props: { lane: Lane }): JSX.Element {
  return props.lane === "home"
    ? <span class="lane-badge home"><Icon name="house" size={12} />Home · Cantrip</span>
    : <span class="lane-badge tab"><Icon name="rectangle.stack" size={12} />Tab · Cantrip</span>;
}

function stepLabel(count: number): string {
  return `${count} ${count === 1 ? "step" : "steps"}`;
}

/** Host steps, or the whole reasoning as one step from Macs that don't split it. */
function reasoningSteps(message: RemoteMessage): RemoteReasoningStep[] {
  const steps = (message.reasoning ?? []).filter((step) => step.title || step.text);
  if (steps.length) return steps;
  const text = message.thinking?.trim() ?? "";
  return text ? [{ title: "Reasoning", text, number: 1 }] : [];
}

function ReasoningSteps(props: { steps: RemoteReasoningStep[]; streaming: boolean }): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const latest = props.steps[props.steps.length - 1];
  return (
    <div class="reasoning">
      <button type="button" class="reasoning-toggle" aria-expanded={expanded ? "true" : "false"}
        title={expanded ? "Hides the reasoning steps" : "Shows each reasoning step"} onClick={() => setExpanded(!expanded)}>
        <Icon name={expanded ? "chevron.down" : "chevron.right"} size={12} class="disclosure-chevron" />
        {props.streaming ? <Spinner size="small" /> : <Icon name="brain" size={14} class="muted" />}
        <strong>Reasoning</strong>
        <span class="grow" />
        <span class="muted">{stepLabel(props.steps.length)}</span>
      </button>
      {props.streaming && !expanded && latest?.title ? <div class="reasoning-now" aria-label={`Now: ${latest.title}`}><Markdown text={latest.title} /></div> : null}
      {expanded ? (
        <div class="reasoning-steps">
          {props.steps.map((step, index) => (
            <ReasoningStepRow key={step.number ?? index + 1} step={step} number={step.number ?? index + 1}
              current={props.streaming && index === props.steps.length - 1} />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function ReasoningStepRow(props: { step: RemoteReasoningStep; number: number; current: boolean }): JSX.Element {
  const [open, setOpen] = useState(false);
  const title = props.step.title || `Step ${props.number}`;
  const details = props.step.text.trim().length > 0;
  const body = (
    <>
      <span class={`step-number${props.current ? " current" : ""}`}>{props.number}</span>
      <span class="step-body">
        <span class="step-title"><Markdown text={title} /></span>
        {open && details ? <span class="step-text"><Markdown text={props.step.text} /></span> : null}
      </span>
      {details ? <Icon name={open ? "chevron.down" : "chevron.right"} size={12} class="muted" /> : null}
    </>
  );
  return details ? (
    <button type="button" class="reasoning-step" aria-expanded={open ? "true" : "false"} onClick={() => setOpen(!open)}
      aria-label={`Step ${props.number}, ${title}${props.current ? ", in progress" : ""}`}>{body}</button>
  ) : <div class="reasoning-step">{body}</div>;
}

/** Where each finished subagent card goes: after N reply blocks (blank-line separated, fences kept whole). */
function replyBlockStarts(text: string): number[] {
  const starts: number[] = [];
  let offset = 0;
  let fence = "";
  let afterBlank = true;
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (fence) {
      if (trimmed.startsWith(fence)) fence = "";
      afterBlank = false;
    } else if (!trimmed) afterBlank = true;
    else {
      if (afterBlank) starts.push(offset);
      afterBlank = false;
      if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) fence = trimmed.slice(0, 3);
    }
    offset += line.length + 1;
  }
  return starts;
}

function ReplyText(props: { message: RemoteMessage; session: RemoteSessionSummary; settled: RemoteSubagent[] }): JSX.Element {
  const { message, session } = props;
  const text = (message.images?.length ? message.displayText : undefined) ?? message.displayText ?? message.text ?? "";
  const images = session.isLocalPrivate ? null : inlineImages(session.id, message.images);
  const part = (value: string, key: string) => {
    if (!value.trim()) return null;
    return session.isLocalPrivate || message.isLocalPrivate
      ? <pre key={key} class="private-text selectable">{value}</pre>
      : <Markdown key={key} text={value} images={images} />;
  };
  if (!props.settled.length) return <>{part(text, "t")}</>;
  const groups = new Map<number, RemoteSubagent[]>();
  for (const agent of props.settled) {
    const block = Math.max(0, agent.textBlock ?? 0);
    groups.set(block, [...(groups.get(block) ?? []), agent]);
  }
  const starts = replyBlockStarts(text);
  const out: ComponentChildren[] = [];
  let from = 0;
  for (const block of [...groups.keys()].sort((a, b) => a - b)) {
    const to = Math.max(from, block === 0 ? 0 : block < starts.length ? starts[block] : text.length);
    out.push(part(text.slice(from, to).replace(/\s+$/, ""), `t${block}`));
    from = to;
    out.push(<SubagentStack key={`s${block}`} sessionID={session.id} subagents={groups.get(block)!} />);
  }
  out.push(part(text.slice(from), "tail"));
  return <>{out}</>;
}

// MARK: Handoffs

function trimmed(value: string | undefined): string {
  return (value ?? "").trim();
}

function handoffNeedsAnswer(handoff: RemoteDelegation): boolean {
  if (handoff.status !== "running") return false;
  const latest = trimmed(handoff.latestStatus);
  return Boolean(handoff.needsInput) || latest === "Needs your answer" || latest === "Waiting for your input";
}

function HandoffIcon(props: { state: string }): JSX.Element {
  switch (props.state) {
    case "needsInput": return <Icon name="questionmark.circle" size={18} class="tint-active" />;
    case "queued": return <Icon name="clock" size={16} class="muted" />;
    case "running":
    case "working": return <Spinner size="small" />;
    case "completed": return <StatusIcon kind="succeeded" size={16} />;
    case "failed": return <Icon name="exclamationmark.triangle" size={16} class="orange" />;
    case "cancelled": return <StatusIcon kind="cancelled" size={16} />;
    default: return <Icon name="info.circle" size={16} class="muted" />;
  }
}

function OpenTabButton(props: { tabID: string; title: string }): JSX.Element | null {
  if (!trimmed(props.tabID)) return null;
  return (
    <button type="button" class="btn plain handoff-open" aria-label={`Open ${props.title} tab`}
      onClick={() => {
        if (!remote.sessions.value.some((item) => item.id === props.tabID)) { toast("That tab is no longer open."); return; }
        nav.openTab(props.tabID);
      }}>
      <Icon name="arrow.up.forward.square" size={14} />Open tab
    </button>
  );
}

function HandoffCard(props: { handoff: RemoteDelegation }): JSX.Element {
  const { handoff } = props;
  const needs = handoffNeedsAnswer(handoff);
  const statusText = needs ? "Needs your answer" : ({
    queued: "Queued in tab", running: "Working in tab", completed: "Done in tab", failed: "Failed in tab", cancelled: "Stopped",
  } as Record<string, string>)[handoff.status] ?? "Handed off";
  const tab = trimmed(handoff.tabTitle) || "Project tab";
  const summary = trimmed(handoff.summary) || trimmed(handoff.prompt);
  const active = handoff.status === "queued" || handoff.status === "running";
  const time = elapsed(handoff.startedAt, handoff.finishedAt, active ? now.value / 1000 : undefined);
  return (
    <section class="handoff-card" aria-label={`${statusText}, ${tab}: ${summary}. ${time}`}>
      <div class="handoff-head">
        <span class="handoff-icon"><HandoffIcon state={needs ? "needsInput" : handoff.status} /></span>
        <div class="handoff-main">
          <div class="handoff-status"><span class={needs ? "strong" : ""}>{statusText}</span><span class="tab-chip"><Icon name="rectangle.stack" size={12} />{tab}</span></div>
          <div class="handoff-summary">{summary}</div>
        </div>
      </div>
      <div class="handoff-foot"><span class="caption muted">{time}</span><span class="grow" /><OpenTabButton tabID={handoff.tabID} title={tab} /></div>
    </section>
  );
}

const RESULT_TEXT: Record<string, string> = {
  working: "Working in tab", needsInput: "Needs your answer", completed: "Done in tab", failed: "Failed in tab", cancelled: "Stopped",
};

function HandoffResultCard(props: { result: RemoteHandoffResult }): JSX.Element {
  const { result } = props;
  const statusText = RESULT_TEXT[result.state] ?? "Handoff update";
  const tab = trimmed(result.tabTitle) || "Project tab";
  const summary = trimmed(result.summary);
  const detail = trimmed(result.detail);
  let time = "";
  if (result.state === "working" && !result.finishedAt && result.startedAt) time = elapsed(result.startedAt, undefined, now.value / 1000);
  else if (result.finishedAt) {
    const clock = clockTime(new Date(result.finishedAt * 1000));
    time = result.startedAt ? `Finished ${clock} · took ${elapsed(result.startedAt, result.finishedAt)}` : `Finished ${clock}`;
  } else if (result.updatedAt) time = `Updated ${clockTime(new Date(result.updatedAt * 1000))}`;
  return (
    <section class={`handoff-card result ${result.state}`} aria-label={`Handoff. ${statusText}, ${tab}${summary ? `: ${summary}` : ""}`}>
      <div class="handoff-tint" aria-hidden="true" />
      <div class="handoff-content">
        <div class="handoff-head">
          <span class="handoff-icon"><HandoffIcon state={result.state} /></span>
          <div class="handoff-main">
            <div class="handoff-status"><span class={result.state === "needsInput" ? "strong" : ""}>{statusText}</span><span class="tab-chip"><Icon name="rectangle.stack" size={12} />{tab}</span></div>
            {summary ? <div class="handoff-summary">{summary}</div> : null}
          </div>
        </div>
        {detail ? <p class="handoff-detail selectable">{detail}</p> : null}
        <div class="handoff-foot"><span class="caption muted">{time}</span><span class="grow" /><OpenTabButton tabID={result.tabID} title={tab} /></div>
      </div>
    </section>
  );
}

// MARK: Rows

function RepeatedErrorActions(props: { session: RemoteSessionSummary }): JSX.Element | null {
  const { session } = props;
  const fresh = session.supportsStartFresh === true;
  const settings = session.supportsModelSettings === true || session.isLocalPrivate;
  if (!fresh && !settings) return null;
  return (
    <div class="row error-actions">
      {fresh ? (
        <button type="button" class="btn primary" disabled={remote.isMutating.value || isBusy(session)}
          title="Keeps this tab's messages, but the next prompt won't send them to the model."
          onClick={() => void remote.startFresh(session.id).catch((error) => toast(`Start Fresh failed: ${error.message}`))}>
          <Icon name="arrow.uturn.backward" size={14} />Start Fresh
        </button>
      ) : null}
      {settings ? (
        <button type="button" class="btn" disabled={remote.isMutating.value} onClick={() => nav.openModelSettings(session)}>
          <Icon name="slider.horizontal.3" size={14} />{session.isLocalPrivate ? "Private Local Settings" : "Change Model"}
        </button>
      ) : null}
    </div>
  );
}

export function ThinkingIndicator(props: { size?: number; class?: string }): JSX.Element {
  return <span class={`thinking${props.class ? ` ${props.class}` : ""}`} role="img" aria-label="Thinking"><Icon name="brain" size={(props.size ?? 22) as 22} /></span>;
}

export function MessageRow(props: {
  message: RemoteMessage;
  session: RemoteSessionSummary;
  lane: Lane;
  streaming: boolean;
  reported: Set<string>;
  /** Home: this row's place on a quoted reply's thread line (`threadLines`). */
  threadLine?: ThreadLine;
}): JSX.Element | null {
  const { message, session, threadLine } = props;
  const tag = threadTag(message);
  const line = threadLine ? ` thread-${threadLine}` : "";
  // A reply from another thread quotes its prompt above the lane badge (cards: above the card); the last row of a
  // run the line turns into the same way.
  const head = (lane?: JSX.Element) => tag
    ? <ThreadQuote sessionID={session.id} messageID={message.id} tag={tag} continues={threadLine === "start"}>{lane}</ThreadQuote>
    : threadLine === "end" ? <ThreadLaneRow>{lane}</ThreadLaneRow> : lane ?? null;
  // The run's first row: the line carries on beside the rest of the reply.
  const rest = (children: ComponentChildren) => tag && threadLine === "start" ? <div class="thread-rest">{children}</div> : children;
  if (message.childResult) {
    return <div class={`turn${line}`} data-message-id={message.id}>{head()}{rest(<ChildResultCard parentID={session.id} child={message.childResult} />)}</div>;
  }
  if (message.role === "handoff" && message.handoffResult) {
    return <div class={`turn${line}`} data-message-id={message.id}>{head()}{rest(<HandoffResultCard result={message.handoffResult} />)}</div>;
  }
  if (message.role === "freshStart") {
    const caption = message.text?.trim() || "Started fresh — earlier messages aren't sent to the model";
    return <div class="fresh-start" data-message-id={message.id} role="separator" aria-label={caption}><span />{caption}<span /></div>;
  }
  if (message.role === "user") {
    const text = message.displayText ?? message.text;
    const replies = threadReplies(session, message.id);
    return (
      <div class={`turn user${line}`} data-message-id={message.id}>
        <div class="bubble">
          {text ? <PromptText text={text} /> : null}
          <ImageGallery sessionID={session.id} images={message.images ?? []} />
        </div>
        {replies ? <ThreadRepliesButton sessionID={session.id} promptID={message.id} prompt={text ?? ""} count={replies} /> : null}
        {message.promptUsage ? <PromptUsageLine usage={message.promptUsage} /> : null}
      </div>
    );
  }
  const isError = message.role === "error";
  const subagents = message.subagents ?? [];
  const settled = subagents.filter((agent) => !subagentLive(agent));
  const steps = isError ? [] : reasoningSteps(message);
  const apps = message.apps ?? [];
  const handoffs = (message.delegations ?? []).filter((handoff) => !props.reported.has(handoff.id));
  const text = isError ? "" : (message.displayText ?? message.text ?? "");
  const thinking = props.streaming && !text && !steps.length && !apps.length && !subagents.length;
  return (
    <div class={`turn assistant${line}`} data-message-id={message.id}>
      {head(<LaneBadge lane={props.lane} />)}
      {rest(
        <>
          {message.author ? <div class="author">{message.author}</div> : null}
          {steps.length ? <ReasoningSteps steps={steps} streaming={props.streaming} /> : null}
          {apps.length ? <MCPAppStack sessionID={session.id} apps={apps} /> : null}
          {!isError ? <ReplyText message={message} session={session} settled={settled} /> : null}
          {handoffs.length ? <div class="handoff-stack">{handoffs.map((handoff) => <HandoffCard key={handoff.id} handoff={handoff} />)}</div> : null}
          {thinking ? <ThinkingIndicator class="muted" /> : null}
          {isError ? (
            <>
              <div class="error-line selectable" role="alert"><Icon name="exclamationmark.triangle" size={14} />{message.text}</div>
              {message.id === session.repeatedErrorMessageID ? <RepeatedErrorActions session={session} /> : null}
            </>
          ) : null}
        </>,
      )}
    </div>
  );
}
