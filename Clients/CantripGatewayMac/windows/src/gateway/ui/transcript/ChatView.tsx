// Home's conversation, or an open project tab's (MacHomeChatView.swift): notices, the transcript
// in an 860px readable column with automatic older-history paging, pinned subagents, then the
// input bar (background tasks, queue, status, attachments, composer).
import type { JSX } from "preact";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import type { RemoteMessage, RemoteSessionSummary, SendMessageRequest } from "../../api/types";
import { bridge, shortcut } from "../../bridge";
import { formatBytes, liveBackgroundSubagents, liveForegroundSubagents } from "../../state/format";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { BackgroundTaskButton, PinnedSubagents } from "../activity/Subagents";
import { QueueButton } from "../activity/Queue";
import { Icon } from "../icons";
import { alertDialog, openMenu, Spinner, toast } from "../kit";
import { displayName } from "../pip/mascot";
import { mascotName } from "../pip/prefs";
import { voiceState } from "../voice/state";
import { VoiceButton, VoiceStatus } from "../voice/VoiceControls";
import {
  AttachmentError, isImageFile, isVideoFile, MAX_FILES, MAX_IMAGES, prepareFile, prepareImage, prepareVideo, uploadAttachments,
  type FileDraft, type ImageDraft, type UploadProgress, type VideoDraft,
} from "./attachments";
import { chatQuestion, composerAcceptsText, composerPlaceholder, InputTranscript, QuestionPanel } from "./Inputs";
import { MessageRow, ThinkingIndicator } from "./Message";
import { useSlashSuggestions } from "./SlashSuggestions";
import "./transcript.css";

interface Draft {
  text: string;
  images: ImageDraft[];
  files: FileDraft[];
  video: VideoDraft | null;
}

/** Drafts per session (like the Mac's per-tab @State drafts); they never follow a switch. */
const drafts = new Map<string, Draft>();
const emptyDraft = (): Draft => ({ text: "", images: [], files: [], video: null });

export function ChatView(props: { isTab: boolean }): JSX.Element {
  const session = remote.selectedSession.value;
  const detail = remote.selectedDetail.value;
  const [height, setHeight] = useState(700);
  const rootRef = useRef<HTMLDivElement>(null);
  const [dropping, setDropping] = useState(false);
  const composer = useRef<ComposerHandle | null>(null);

  useEffect(() => {
    const node = rootRef.current;
    if (!node) return;
    const observer = new ResizeObserver(() => setHeight(node.clientHeight));
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  const pinned = useMemo(() => liveForegroundSubagents(detail?.messages ?? []), [detail]);
  return (
    <div ref={rootRef} class={`chat${dropping ? " dropping" : ""}`}
      onDragOver={(event) => {
        if (!event.dataTransfer?.types.includes("Files")) return;
        event.preventDefault();
        setDropping(true);
      }}
      onDragLeave={(event) => { if (event.target === rootRef.current || !rootRef.current?.contains(event.relatedTarget as Node)) setDropping(false); }}
      onDrop={(event) => {
        if (!event.dataTransfer?.files.length) return;
        event.preventDefault();
        setDropping(false);
        void composer.current?.addFiles(Array.from(event.dataTransfer.files));
      }}>
      <Notices />
      <Transcript session={session} messages={detail?.messages ?? []} isTab={props.isTab} detailLoaded={detail !== null} />
      {session && pinned.length ? (
        <div class="pinned-column"><PinnedSubagents sessionID={session.id} subagents={pinned} maxHeight={Math.max(120, height * 0.35)} /></div>
      ) : null}
      <InputBar session={session} isTab={props.isTab} height={height} handle={composer} />
    </div>
  );
}

function Notices(): JSX.Element | null {
  const session = remote.selectedSession.value;
  const idle = session && !session.isStreaming && session.status?.trim() ? session.status.trim() : null;
  const delivery = session?.deliveryStatus;
  const error = remote.errorMessage.value;
  const detailError = remote.detailError.value;
  if (!idle && !delivery && !error && !detailError) return null;
  return (
    <div class="notice-bar" role="status">
      <div>
        {idle ? <div class="caption muted truncate">{idle}</div> : null}
        {delivery ? <div class="caption muted">{delivery}</div> : null}
        {error ? <div class="alert-text selectable"><Icon name="exclamationmark.triangle" size={14} />{error}</div> : null}
        {detailError ? (
          <div class="col" style={{ gap: "4px", alignItems: "flex-start" }}>
            <span class="caption orange">{detailError}</span>
            <button type="button" class="btn link caption" disabled={remote.isRefreshing.value} onClick={() => void remote.refreshNow()}>Retry conversation</button>
          </div>
        ) : null}
      </div>
    </div>
  );
}

// MARK: Transcript

function Transcript(props: { session: RemoteSessionSummary | null; messages: RemoteMessage[]; isTab: boolean; detailLoaded: boolean }): JSX.Element {
  const { session, messages } = props;
  const scroller = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  const lastTop = useRef(0);
  const anchor = useRef<{ id: string; offset: number; firstID: string | undefined } | null>(null);
  const [atBottom, setAtBottom] = useState(true);
  const sessionID = session?.id ?? null;
  const history = sessionID ? remote.historyState.value.get(sessionID) : undefined;
  const hasOlder = Boolean((session as { hasOlderMessages?: boolean } | null)?.hasOlderMessages);

  const reported = useMemo(() => new Set(messages.flatMap((message) => (message.role === "handoff" && message.handoffResult ? [message.handoffResult.delegationID] : []))), [messages]);
  const lastAssistantID = useMemo(() => {
    for (let index = messages.length - 1; index >= 0; index--) {
      const message = messages[index];
      if (message.role !== "user" && message.role !== "error" && message.role !== "handoff" && message.role !== "freshStart") return message.id;
    }
    return null;
  }, [messages]);

  // A new session opens at its latest message.
  useLayoutEffect(() => {
    follow.current = true;
    anchor.current = null;
    const node = scroller.current;
    if (node) node.scrollTop = node.scrollHeight;
    setAtBottom(true);
  }, [sessionID]);

  // New content keeps the reader at the bottom when they were there; a prepended page keeps
  // the message being read where it was (renders before the page arrives keep the anchor).
  useLayoutEffect(() => {
    const node = scroller.current;
    if (!node) return;
    if (anchor.current) {
      if (messages[0]?.id !== anchor.current.firstID) {
        const row = node.querySelector<HTMLElement>(`[data-message-id="${CSS.escape(anchor.current.id)}"]`);
        if (row) node.scrollTop = row.offsetTop - anchor.current.offset;
        anchor.current = null;
      }
    } else if (follow.current) {
      node.scrollTop = node.scrollHeight;
    }
    lastTop.current = node.scrollTop;
  });

  // Content that grows after layout (images decoding, MCP views) still sticks to the bottom.
  useEffect(() => {
    const node = scroller.current;
    const content = node?.firstElementChild;
    if (!node || !content) return;
    const observer = new ResizeObserver(() => { if (follow.current) node.scrollTop = node.scrollHeight; });
    observer.observe(content);
    return () => observer.disconnect();
  }, []);

  const loadOlder = async (automatically: boolean) => {
    const node = scroller.current;
    if (!node || !sessionID) return;
    const rows = Array.from(node.querySelectorAll<HTMLElement>("[data-message-id]"));
    const first = rows.find((row) => row.offsetTop + row.offsetHeight > node.scrollTop) ?? rows[0];
    if (first) anchor.current = { id: first.dataset.messageId!, offset: first.offsetTop - node.scrollTop, firstID: messages[0]?.id };
    const loaded = await remote.loadOlder(sessionID, automatically);
    // The page renders before the next frame; a page with nothing new leaves no anchor behind.
    if (!loaded) anchor.current = null;
    else requestAnimationFrame(() => { anchor.current = null; });
  };

  const onScroll = () => {
    const node = scroller.current;
    if (!node) return;
    const bottom = node.scrollHeight - node.clientHeight - node.scrollTop <= 24;
    const upward = node.scrollTop < lastTop.current;
    follow.current = bottom;
    setAtBottom(bottom);
    if (upward && node.scrollTop < Math.max(600, node.clientHeight) && hasOlder && !history?.loading && !history?.error) void loadOlder(true);
    lastTop.current = node.scrollTop;
  };

  const lane = props.isTab ? "tab" : "home";
  return (
    <div class="transcript-wrap">
      <div ref={scroller} class="transcript" onScroll={onScroll} tabIndex={-1} aria-label="Conversation">
        <div class="transcript-column">
          {session?.supportsPagedHistory ? (
            <div class="history-row" role="status">
              {history?.error ? (
                <>
                  <span class="caption muted grow">{history.loading ? "Loading older messages…" : history.error}</span>
                  <button type="button" class="btn" disabled={history.loading} aria-label="Retry loading older messages" onClick={() => void loadOlder(false)}>Retry</button>
                </>
              ) : (
                <span class={`caption muted row${hasOlder && history?.loading ? "" : " invisible"}`}>
                  <Spinner size="small" />Loading older messages…
                </span>
              )}
              {hasOlder && !history?.loading && !history?.error ? (
                <button type="button" class="sr-only" onFocus={() => void loadOlder(true)} onClick={() => void loadOlder(false)}>Load older messages</button>
              ) : null}
            </div>
          ) : null}
          {!messages.length ? <EmptyState isTab={props.isTab} loaded={props.detailLoaded} /> : null}
          {session ? messages.map((message) => (
            <MessageRow key={message.id} message={message} session={session} lane={lane}
              streaming={Boolean(session.isStreaming && message.id === lastAssistantID)} reported={reported} />
          )) : null}
          {session ? <InputTranscript session={session} /> : null}
        </div>
      </div>
      {!atBottom ? (
        <button type="button" class="latest-button" onClick={() => {
          const node = scroller.current;
          follow.current = true;
          if (node) node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
        }}><Icon name="arrow.down" size={14} />Latest</button>
      ) : null}
    </div>
  );
}

function EmptyState(props: { isTab: boolean; loaded: boolean }): JSX.Element {
  const session = remote.selectedSession.value;
  const connection = remote.connection.value;
  if (!remote.listed.value) {
    return (
      <div class="empty-state">
        <Icon name={connection.state === "connecting" ? "antenna.radiowaves.left.and.right" : "wifi.slash"} size={56} />
        <div class="title3">{connection.state === "connecting" ? "Connecting to your Mac…" : "Can't reach your Mac"}</div>
        <p>{connection.message || "Make sure Cantrip is running on the Mac and this PC is on the same network or on Tailscale."}</p>
        {connection.state !== "connecting" ? (
          <div class="row">
            <button type="button" class="btn primary" onClick={() => void remote.refreshNow()}>Try Again</button>
            <button type="button" class="btn" onClick={() => bridge.openSettings()}>Connection Settings…</button>
          </div>
        ) : <Spinner />}
      </div>
    );
  }
  if (props.isTab) {
    return (
      <div class="empty-state">
        <Icon name="rectangle.stack" size={56} />
        <div class="title3">{session ? remote.tabTitle(session) : "No tab open"}</div>
        <p>{session ? "Type to start this tab. Cantrip runs it on your Mac." : `Choose a tab in the sidebar, or press ${shortcut("Ctrl+T")} for a new one.`}</p>
      </div>
    );
  }
  if (!remote.homeSummary.value) {
    return (
      <div class="empty-state">
        <Icon name="house" size={56} />
        <div class="title3">Cantrip Home unavailable</div>
        <p>Turn on Cantrip Home in Cantrip's Remote control settings on the Mac.</p>
      </div>
    );
  }
  if (!props.loaded) {
    return (
      <div class="empty-state">
        <Icon name="house" size={56} />
        <div class="title3">Opening Cantrip Home…</div>
        <Spinner />
      </div>
    );
  }
  return (
    <div class="empty-state">
      <Icon name="house" size={56} />
      <div class="title3">Hi, I'm {displayName(mascotName.value)}</div>
      <p>Ask anything, create a task, or make an artifact.</p>
    </div>
  );
}

// MARK: Input bar

interface ComposerHandle {
  addFiles(files: File[]): Promise<void>;
}

function InputBar(props: { session: RemoteSessionSummary | null; isTab: boolean; height: number; handle: { current: ComposerHandle | null } }): JSX.Element {
  const { session } = props;
  const detail = remote.selectedDetail.value;
  const background = props.isTab && session && !session.isCantripHome ? liveBackgroundSubagents(detail?.messages ?? []) : [];
  return (
    <div class="input-bar">
      <div class="input-column">
        {background.length && session ? (
          <BackgroundTaskButton subagents={background} onOpen={() => { nav.sheet.value = { kind: "backgroundTasks", sessionID: session.id }; }} />
        ) : null}
        {session && session.queuedCount > 0 ? <QueueButton session={session} onOpen={() => { nav.sheet.value = { kind: "queue", sessionID: session.id }; }} /> : null}
        {nav.paused.value ? <PausedBar session={session} /> : (
          <>
            <WorkStatus session={session} />
            <Composer session={session} isTab={props.isTab} height={props.height} handle={props.handle} />
          </>
        )}
      </div>
    </div>
  );
}

function PausedBar(props: { session: RemoteSessionSummary | null }): JSX.Element {
  return (
    <div class="paused-bar">
      <Icon name="pause.circle" size={24} class="orange" />
      <div class="grow">
        <div class="headline">Agent paused</div>
        <div class="caption muted">No requests will be sent.</div>
      </div>
      <StopIcon session={props.session} />
      <button type="button" class="btn primary" onClick={() => { nav.paused.value = false; }}>Resume</button>
    </div>
  );
}

function WorkStatus(props: { session: RemoteSessionSummary | null }): JSX.Element | null {
  const voice = voiceState.value;
  if (voice.listening || voice.speaking || voice.error || voice.preparing) return <VoiceStatus />;
  const session = props.session;
  if (!session?.isStreaming || chatQuestion(session)) return null;
  return (
    <div class="work-status" role="status">
      <ThinkingIndicator class="accent" />
      <span class="callout muted">{session.status?.trim() || "Cantrip is working…"}</span>
    </div>
  );
}

function StopIcon(props: { session: RemoteSessionSummary | null }): JSX.Element | null {
  const session = props.session;
  const stopping = remote.stoppingID.value !== null && remote.stoppingID.value === session?.id;
  if (!session || (!session.isStreaming && !stopping)) return null;
  const enabled = session.isStreaming && remote.isConnected.value && !remote.isMutating.value && !stopping;
  return (
    <button type="button" class="composer-stop" disabled={!enabled} title="Stop (keeps the conversation, clears queued prompts)"
      aria-label={stopping ? "Stopping Cantrip prompt" : "Stop current Cantrip prompt"}
      onClick={() => void remote.stop(session.id).catch((error) => toast(`Stop failed: ${error.message}`))}>
      {stopping ? <Spinner size="small" /> : <Icon name="stop.fill" size={12} class="filled" />}
    </button>
  );
}

function Composer(props: { session: RemoteSessionSummary | null; isTab: boolean; height: number; handle: { current: ComposerHandle | null } }): JSX.Element {
  const { session } = props;
  const sessionID = session?.id ?? null;
  const key = sessionID ?? "";
  const textRef = useRef<HTMLTextAreaElement>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const [, setVersion] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [importing, setImporting] = useState(false);
  const [progress, setProgress] = useState<UploadProgress | null>(null);
  const [focused, setFocused] = useState(false);
  const abort = useRef<AbortController | null>(null);
  const draft = drafts.get(key) ?? emptyDraft();
  const update = (change: Partial<Draft>) => {
    drafts.set(key, { ...(drafts.get(key) ?? emptyDraft()), ...change });
    setVersion((value) => value + 1);
  };

  const question = chatQuestion(session);
  const acceptsText = composerAcceptsText(question);
  const recipient = props.isTab ? remote.tabTitle(session) : displayName(mascotName.value);
  const ready = remote.listed.value && sessionID !== null;
  const busy = submitting || importing;
  const hasAttachments = draft.images.length > 0 || draft.files.length > 0 || draft.video !== null;
  const pickerDisabled = !ready || !acceptsText || busy || remote.isMutating.value || voiceState.value.listening;

  // Prefill from Tasks/Artifacts "+" and focus requests.
  useEffect(() => {
    const prefill = nav.composerPrefill.value;
    if (prefill !== null && sessionID) {
      update({ text: prefill });
      nav.composerPrefill.value = null;
    }
    requestAnimationFrame(() => {
      const node = textRef.current;
      if (!node) return;
      node.focus();
      node.setSelectionRange(node.value.length, node.value.length);
    });
  }, [nav.composerFocusRequest.value, sessionID]);

  // Grow with the text, 1 to 12 lines.
  useLayoutEffect(() => {
    const node = textRef.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(node.scrollHeight, 12 * 20 + 24)}px`;
  });

  const addFiles = async (files: File[]) => {
    if (!sessionID || pickerDisabled) return;
    setImporting(true);
    try {
      for (const file of files) {
        const current = drafts.get(key) ?? emptyDraft();
        if (isImageFile(file)) {
          if (!session?.supportsImageAttachments) throw new AttachmentError("Update Cantrip and choose a backend that accepts images to attach them.");
          if (current.images.length >= MAX_IMAGES) throw new AttachmentError(`You can attach up to ${MAX_IMAGES} images.`);
          if (current.video && !session.supportsMixedAttachments) throw new AttachmentError("This Mac can't send a video together with images.");
          update({ images: [...current.images, await prepareImage(file, file.name)] });
        } else if (isVideoFile(file)) {
          if (!session?.supportsVideoAttachments) throw new AttachmentError("Update Cantrip and choose a backend that accepts videos to attach them.");
          if (current.video) throw new AttachmentError("You can attach one video per message.");
          update({ video: await prepareVideo(file) });
        } else {
          if (!session?.supportsFileAttachments) throw new AttachmentError("Update Cantrip on your Mac to attach documents other than photos and videos.");
          if (current.files.length >= MAX_FILES) throw new AttachmentError(`You can attach up to ${MAX_FILES} files.`);
          update({ files: [...current.files, prepareFile(file)] });
        }
      }
    } catch (error) {
      void alertDialog("Attachment", (error as Error).message);
    } finally {
      setImporting(false);
    }
  };
  props.handle.current = { addFiles };

  const pasteImage = async () => {
    try {
      const items = await navigator.clipboard.read();
      const images: File[] = [];
      for (const item of items) {
        const type = item.types.find((value) => value.startsWith("image/"));
        if (type) images.push(new File([await item.getType(type)], "Pasted image", { type }));
      }
      if (!images.length) { toast("There's no image on the clipboard."); return; }
      await addFiles(images);
    } catch (error) {
      toast(`Couldn't paste: ${(error as Error).message}`);
    }
  };

  const send = async () => {
    const current = drafts.get(key) ?? emptyDraft();
    const text = current.text.trim();
    const attachments = current.images.length > 0 || current.files.length > 0 || current.video !== null;
    if (nav.paused.value || busy || !ready || !acceptsText || remote.isMutating.value || (!text && !attachments) || !sessionID || !session) return;
    const mode = nav.deliveryMode.value;
    if ((current.video || current.files.length) && /^[/!]/.test(text)) {
      void alertDialog("Attachment", "Commands starting with / or ! can't include a video or files.");
      return;
    }
    const body: SendMessageRequest = { text, mode };
    if (mode === "auto" && question) {
      if (!session.supportsChatInputReplies) {
        if (attachments) { void alertDialog("Attachment", "Update Cantrip on your Mac to attach files to a reply."); return; }
        setSubmitting(true);
        try {
          await remote.answerInput(session.id, question.id, { decision: "submit", text });
          update({ text: "" });
        } catch (error) {
          void alertDialog("Message not confirmed", `${(error as Error).message}\n\nYour draft has been kept.`);
        } finally {
          setSubmitting(false);
        }
        return;
      }
      body.inputRequestID = question.id;
    }
    if (current.images.length) body.images = current.images.map((image) => ({ data: image.data }));
    const originalText = current.text;
    setSubmitting(true);
    abort.current = new AbortController();
    try {
      if (current.video || current.files.length) {
        Object.assign(body, await uploadAttachments(sessionID, current.video, current.files, setProgress, abort.current.signal));
      }
      await remote.sendMessage(sessionID, body);
      const after = drafts.get(key) ?? emptyDraft();
      const sentImages = new Set(current.images.map((image) => image.id));
      const sentFiles = new Set(current.files.map((file) => file.id));
      for (const image of current.images) URL.revokeObjectURL(image.preview);
      drafts.set(key, {
        text: after.text === originalText ? "" : after.text,
        images: after.images.filter((image) => !sentImages.has(image.id)),
        files: after.files.filter((file) => !sentFiles.has(file.id)),
        video: after.video?.id === current.video?.id ? null : after.video,
      });
      nav.deliveryMode.value = "auto";
      setVersion((value) => value + 1);
    } catch (error) {
      void alertDialog("Message not confirmed", `${(error as Error).message || "Cantrip did not confirm the message."}\n\nYour draft has been kept. If the connection was lost, check the conversation before sending again to avoid a duplicate.`);
    } finally {
      setProgress(null);
      abort.current = null;
      setSubmitting(false);
      requestAnimationFrame(() => textRef.current?.focus());
    }
  };

  const attachMenu = (anchor: HTMLElement) => openMenu(anchor, [
    { label: "Photos…", icon: "photo.on.rectangle", disabled: session?.supportsImageAttachments === false && session?.supportsVideoAttachments === false, onSelect: () => { if (fileInput.current) { fileInput.current.accept = "image/*,.mp4,.mov,video/mp4,video/quicktime"; fileInput.current.click(); } } },
    { label: "Files…", icon: "folder", disabled: !session?.supportsFileAttachments, onSelect: () => { if (fileInput.current) { fileInput.current.accept = ""; fileInput.current.click(); } } },
    { label: "Paste Image", icon: "doc.on.doc", onSelect: () => void pasteImage() },
    ...(session?.supportsFileAttachments === false ? [{ kind: "header" as const, label: "Update Cantrip on your Mac to attach documents other than photos and videos." }] : []),
  ], { align: "start", label: "Attach" });

  const slash = useSlashSuggestions({
    session, text: draft.text, focused, enabled: ready && acceptsText && !busy,
    onChoose: (choice) => {
      if (choice.openModelSettings) {
        update({ text: "" });
        nav.openModelSettings(session);
        return;
      }
      update({ text: choice.text });
      if (choice.send) {
        void send();
        return;
      }
      requestAnimationFrame(() => {
        const node = textRef.current;
        if (!node) return;
        node.focus();
        node.setSelectionRange(node.value.length, node.value.length);
      });
    },
  });

  const sendLabel = nav.deliveryMode.value === "auto" && question ? "Send reply" : "Send prompt";
  return (
    <>
      <Attachments draft={draft} disabled={busy} update={update} importing={importing} />
      {progress ? (
        <div class="upload-progress" role="status">
          <div class="progress"><div style={{ width: `${Math.round(progress.fraction * 100)}%` }} /></div>
          <div class="row"><span class="caption muted grow">{progress.label}</span><button type="button" class="btn small" onClick={() => abort.current?.abort()}>Cancel upload</button></div>
        </div>
      ) : null}
      <div class="composer" data-id="chat.composer">
        {slash.popover}
        {slash.announcer}
        {session && question ? <QuestionPanel session={session} question={question} busy={busy || remote.isMutating.value} maxHeight={Math.min(360, Math.max(72, props.height * 0.45))} /> : null}
        <div class="composer-row">
          <button type="button" class="composer-attach" aria-label="Attach" title="Attach photos, a video or files" disabled={pickerDisabled}
            onClick={(event) => attachMenu(event.currentTarget as HTMLElement)}>
            <Icon name="plus.circle" size={22} />
          </button>
          <input ref={fileInput} type="file" multiple hidden onChange={(event) => {
            const input = event.target as HTMLInputElement;
            const files = Array.from(input.files ?? []);
            input.value = "";
            void addFiles(files);
          }} />
          <textarea ref={textRef} class="composer-text" rows={1} value={draft.text} data-id="chat.message"
            placeholder={composerPlaceholder(question, recipient)} aria-label={`Message ${recipient}`}
            disabled={!ready || !acceptsText || submitting}
            title="Enter sends. Shift+Enter adds a new line."
            {...slash.fieldProps}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            onInput={(event) => update({ text: (event.target as HTMLTextAreaElement).value })}
            onPaste={(event) => {
              const files = Array.from(event.clipboardData?.files ?? []).filter(isImageFile);
              if (files.length) { event.preventDefault(); void addFiles(files); }
            }}
            onKeyDown={(event) => {
              if (slash.onKeyDown(event)) return;
              if (event.key === "Enter" && !event.shiftKey && !event.altKey && !event.isComposing) {
                event.preventDefault();
                void send();
              }
            }} />
          <StopIcon session={session} />
          <span class="composer-action">
            {busy ? <Spinner /> : !draft.text && !hasAttachments ? (
              <VoiceButton disabled={!ready || !acceptsText} onText={(text) => update({ text: [drafts.get(key)?.text, text].filter(Boolean).join(" ") })} />
            ) : (
              <button type="button" class="send-button" aria-label={sendLabel} title="Send (Enter)"
                disabled={!ready || !acceptsText || remote.isMutating.value} onClick={() => void send()}>
                <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="12" /><path d="M12 17V7.5M7.8 11.4L12 7.2l4.2 4.2" /></svg>
              </button>
            )}
          </span>
        </div>
      </div>
    </>
  );
}

function Attachments(props: { draft: Draft; disabled: boolean; importing: boolean; update: (change: Partial<Draft>) => void }): JSX.Element | null {
  const { draft } = props;
  if (!draft.images.length && !draft.files.length && !draft.video && !props.importing) return null;
  return (
    <div class="attachments">
      {draft.images.length ? (
        <div class="attachment-images">
          {draft.images.map((image, index) => (
            <div key={image.id} class="attachment-image">
              <img src={image.preview} alt={`Attached image ${index + 1}`} />
              <button type="button" class="attachment-remove" aria-label={`Remove image ${index + 1}`} disabled={props.disabled}
                onClick={() => { URL.revokeObjectURL(image.preview); props.update({ images: draft.images.filter((item) => item.id !== image.id) }); }}>
                <Icon name="xmark" size={12} />
              </button>
            </div>
          ))}
          <span class="caption muted">{draft.images.length}/{MAX_IMAGES}</span>
        </div>
      ) : null}
      {draft.video ? (
        <div class="attachment-chip">
          <Icon name="film" size={14} />
          <span class="truncate">{draft.video.name}</span>
          <span class="caption muted">{draft.video.duration ? `${Math.floor(draft.video.duration / 60)}:${String(Math.round(draft.video.duration % 60)).padStart(2, "0")} · ` : ""}{formatBytes(draft.video.size)}</span>
          <button type="button" class="icon-btn" aria-label={`Remove ${draft.video.name}`} disabled={props.disabled} onClick={() => props.update({ video: null })}><Icon name="xmark" size={12} /></button>
        </div>
      ) : null}
      {draft.files.map((file) => (
        <div key={file.id} class="attachment-chip">
          <Icon name="paperclip" size={14} />
          <span class="truncate">{file.name}</span>
          <span class="caption muted">{formatBytes(file.size)}</span>
          <button type="button" class="icon-btn" aria-label={`Remove ${file.name}`} disabled={props.disabled}
            onClick={() => props.update({ files: draft.files.filter((item) => item.id !== file.id) })}><Icon name="xmark" size={12} /></button>
        </div>
      ))}
      {draft.files.length ? <span class="caption muted">{draft.files.length}/{MAX_FILES} files</span> : null}
      {props.importing ? <span class="caption muted row"><Spinner size="small" />Preparing attachment…</span> : null}
    </div>
  );
}
