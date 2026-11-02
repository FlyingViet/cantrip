// Voice for the chat (the Mac's ChatMicrophoneButton, MacHomeChatView.voiceStatus and VoiceModeView):
// the composer's microphone for dictation (press and hold for Voice Mode), the voice status row above
// the composer, and Voice Mode's continuous listen → send → speak loop.
import "./voice.css";
import type { JSX } from "preact";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { shortcut } from "../../bridge";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { confirmDialog, openMenu, Sheet, Spinner } from "../kit";
import { mascotDisplayName } from "../pip/prefs";
import { Markdown } from "../transcript/Markdown";
import { ThinkingIndicator } from "../transcript/Message";
import * as conversation from "./conversation";
import * as voice from "./controller";
import { MicGlyph, Waveform } from "./parts";
import * as recognizer from "./recognizer";
import { engineInfo, sttEngine } from "./settings";
import { voiceState } from "./state";

export { VoiceSettingsPanel, VoiceSettingsSheet } from "./VoiceSettings";

/** Hold this long on the microphone for Voice Mode (the Mac's LongPressGesture). */
const HOLD_MS = 500;

/** Before the first use: offers the one-time model download. True when it's fine to start. */
async function confirmModelDownload(): Promise<boolean> {
  const state = recognizer.modelState.peek();
  if (recognizer.isPrepared() || state.kind === "preparing" || state.kind === "ready") return true;
  const engine = engineInfo(sttEngine.peek());
  return confirmDialog({
    title: "Download the speech model?",
    message: `Dictation and Voice Mode turn speech into text on this PC with ${engine.title} (OpenAI Whisper, English). It's a one-time ${engine.size} download from Hugging Face; what you say never leaves this PC.`,
    confirm: "Download",
  });
}

/** The composer's microphone: click to dictate, press and hold for Voice Mode. */
export function VoiceButton(props: { disabled: boolean; onText: (text: string) => void }): JSX.Element {
  const state = voiceState.value;
  const onText = useRef(props.onText);
  onText.current = props.onText;
  const hold = useRef<{ timer: ReturnType<typeof setTimeout> | null; fired: boolean }>({ timer: null, fired: false });
  const enabled = !props.disabled && !nav.paused.value;

  const cancelHold = () => {
    if (hold.current.timer) clearTimeout(hold.current.timer);
    hold.current.timer = null;
  };
  useEffect(() => cancelHold, []);

  const openVoiceMode = () => {
    if (!enabled) return;
    if (voiceState.peek().listening) voice.stopListening(false);
    nav.sheet.value = { kind: "voiceMode" };
  };

  const tap = async () => {
    if (!enabled) return;
    const current = voiceState.peek();
    const dictate = (text: string) => onText.current(text);
    if (current.speaking) {
      voice.setTranscriptHandler(dictate);
      conversation.interruptAndListen();
      return;
    }
    if (current.listening) {
      voice.stopListening(true);
      return;
    }
    if (current.preparing || !(await confirmModelDownload())) return;
    voice.setTranscriptHandler(dictate);
    void voice.startListening();
  };

  return (
    <>
      <button type="button" class={`mic-button${state.listening ? " listening" : ""}`} disabled={!enabled}
        aria-label={state.listening ? "Stop listening" : "Start listening"} aria-describedby="voice-mic-hint"
        title="Dictate (press and hold for voice mode)" data-id="chat.microphone"
        onPointerDown={(event) => {
          hold.current.fired = false;
          cancelHold();
          if (event.button !== 0 || !enabled) return;
          hold.current.timer = setTimeout(() => {
            hold.current.timer = null;
            hold.current.fired = true;
            openVoiceMode();
          }, HOLD_MS);
        }}
        onPointerUp={cancelHold} onPointerLeave={cancelHold} onPointerCancel={cancelHold}
        onClick={(event) => {
          // A hold must not also toggle dictation when the button is released.
          if (event.detail !== 0 && hold.current.fired) {
            hold.current.fired = false;
            return;
          }
          void tap();
        }}
        onContextMenu={(event) => {
          event.preventDefault();
          openMenu({ x: event.clientX, y: event.clientY }, [
            { label: state.listening ? "Stop Listening" : "Dictate", icon: "mic", disabled: !enabled, onSelect: () => void tap() },
            { label: "Voice Mode", icon: "waveform", shortcut: shortcut("Ctrl+Shift+V"), disabled: !enabled, onSelect: openVoiceMode },
          ], { label: "Microphone" });
        }}>
        <MicGlyph filled={state.listening} size={22} />
      </button>
      <span id="voice-mic-hint" class="sr-only">Click for dictation. Press and hold, or press {shortcut("Ctrl+Shift+V")}, for continuous voice mode.</span>
    </>
  );
}

/** Listening / speaking / preparing status above the composer (MacHomeChatView.voiceStatus). */
export function VoiceStatus(): JSX.Element | null {
  const state = voiceState.value;
  if (state.preparing) {
    return (
      <div class="voice-status" role="status">
        <Spinner size="small" />
        <span class="callout muted grow">{state.status ?? "Preparing speech recognition…"}</span>
        {state.progress !== null ? (
          <div class="progress voice-status-progress" aria-hidden="true"><div style={{ width: `${Math.round(state.progress * 100)}%` }} /></div>
        ) : null}
      </div>
    );
  }
  if (state.listening) {
    return (
      <div class="voice-status" role="status">
        <Waveform active tone="red" live />
        <span class="callout muted grow voice-status-text">{state.partial || "Listening…"}</span>
      </div>
    );
  }
  if (state.error) {
    return (
      <div class="voice-status voice-status-error" role="alert">
        <Icon name="exclamationmark.triangle" size={14} />
        <span class="caption grow">{state.error}</span>
        <button type="button" class="icon-btn" aria-label="Dismiss" title="Dismiss" onClick={voice.clearError}><Icon name="xmark" size={12} /></button>
      </div>
    );
  }
  if (state.speaking) {
    return (
      <div class="voice-status" role="status">
        <Waveform active tone="accent" />
        <span class="callout muted grow">{mascotDisplayName.value} is speaking</span>
        <button type="button" class="voice-stop-speaking" aria-label="Stop speaking" title="Stop speaking" onClick={voice.stopSpeaking}>
          <Icon name="stop.circle" size={20} />
        </button>
      </div>
    );
  }
  return null;
}

/** Voice Mode (VoiceModeView): talk, Cantrip answers aloud, and it listens again. */
export function VoiceModeSheet(props: { onClose: () => void }): JSX.Element {
  const state = voiceState.value;
  const working = conversation.isWorking.value;
  const messages = remote.selectedDetail.value?.messages ?? [];
  const reply = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);

  useEffect(() => {
    let open = true;
    conversation.enterVoiceMode(false);
    void confirmModelDownload().then((ok) => {
      if (open && ok) conversation.resumeVoiceModeIfIdle();
    });
    return () => {
      open = false;
      conversation.leaveVoiceMode();
    };
  }, []);

  // Paused: Voice Mode closes (nothing may be sent).
  useEffect(() => {
    if (nav.paused.value) props.onClose();
  }, [nav.paused.value]);

  const statusText = state.speaking ? "Speaking — tap to interrupt"
    : state.preparing ? state.status ?? "Preparing speech recognition"
    : working ? conversation.runStatusText.value ?? "Thinking — tap to interrupt"
    : state.listening ? "Listening" : "Tap the mic to talk";

  // The latest reply (rendered as Markdown), and what you said: live while dictating, then the sent prompt.
  let replyText = "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.role === "user" || message.role === "freshStart") continue;
    replyText = message.role === "error" ? "" : conversation.presentedText(message);
    break;
  }
  const lastUser = [...messages].reverse().find((message) => message.role === "user");
  const transcriptText = state.listening ? state.partial : lastUser ? conversation.presentedText(lastUser) : "";
  const error = conversation.sendError.value ?? state.error;

  useLayoutEffect(() => {
    const node = reply.current;
    if (node && atBottom.current) node.scrollTop = node.scrollHeight;
  }, [replyText]);

  const tapMic = async () => {
    if (state.speaking || working) {
      conversation.interruptAndListen();
      return;
    }
    if (!state.listening && !(await confirmModelDownload())) return;
    voice.toggleListening();
  };

  const isHome = remote.isHomeSelected.value;
  return (
    <Sheet title="Voice Mode" onClose={props.onClose} width={520} height={620} class="voice-mode-sheet" bodyClass="voice-mode-body">
      <div class="voice-mode-header">
        <span class="voice-mode-indicator">
          {working && !state.speaking && !state.listening
            ? <ThinkingIndicator size={28} class="accent" />
            : <Waveform active={state.listening || state.speaking} tone={state.listening ? "red" : "accent"} size="large" live={state.listening} />}
        </span>
        <span class="voice-mode-status" role="status">{statusText}</span>
        {isHome
          ? <span class="lane-badge home"><Icon name="house" size={12} />Home · Cantrip</span>
          : <span class="lane-badge tab"><Icon name="rectangle.stack" size={12} />Tab · Cantrip</span>}
        <button type="button" class="voice-mode-close" aria-label="Close voice mode" title="Close (Esc)" onClick={props.onClose}>
          <Icon name="xmark" size={16} />
        </button>
      </div>
      {error ? (
        <div class="voice-mode-error" role="alert">
          <Icon name="exclamationmark.triangle" size={14} />
          <span class="grow">{error}</span>
        </div>
      ) : null}
      {transcriptText ? (
        <div class={`voice-mode-transcript${state.listening ? " live" : ""}`}>
          <span class="voice-mode-quote" aria-hidden="true">“</span>
          <p>{transcriptText}</p>
        </div>
      ) : null}
      <div class="voice-mode-layout">
        <div class="voice-mode-reply">
          {replyText ? (
            <div ref={reply} class="voice-mode-card selectable" tabIndex={0} aria-label="Reply"
              onScroll={(event) => {
                const node = event.currentTarget as HTMLDivElement;
                atBottom.current = node.scrollHeight - node.scrollTop - node.clientHeight < 24;
              }}>
              <Markdown text={replyText} />
            </div>
          ) : null}
        </div>
        <button type="button" class={`voice-mode-mic${state.listening ? " listening" : ""}`} data-autofocus
          disabled={state.preparing && !state.listening}
          aria-label={state.listening ? "Stop listening" : "Talk to your agent"}
          onClick={() => void tapMic()}>
          <MicGlyph filled={state.listening} size={28} />
        </button>
      </div>
    </Sheet>
  );
}
