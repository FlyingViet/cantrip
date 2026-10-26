// Voice Mode's conversation (the voice half of the Mac's ChatViewModel): spoken prompts go to the
// shown Home or tab through the normal send path, and the reply that answers them is read aloud as
// it streams in (syncRemoteTranscript's remoteSpeechTargetID logic).
import { computed, effect, signal, untracked } from "@preact/signals";
import type { RemoteMessage } from "../../api/types";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { plainMentions } from "../../state/tabMentions";
import * as voice from "./controller";
import { SpeechChunker } from "./speech";
import { voiceState } from "./state";

/** A spoken prompt is on its way to the Mac. */
export const sending = signal(false);
/** Why the last spoken prompt or interruption failed. */
export const sendError = signal<string | null>(null);

/** `vm.isWorking`: sending, or the shown conversation is running. */
export const isWorking = computed(() => sending.value || Boolean(remote.selectedSession.value?.isStreaming));
/** `vm.runStatusText`. */
export const runStatusText = computed(() => {
  if (sending.value) return "Sending to Cantrip…";
  const session = remote.selectedSession.value;
  return session?.isStreaming ? session.status?.trim() || "Cantrip is working…" : null;
});

/** A model reply: not the user, an error, a handoff result card or a fresh-start divider. */
export function isReply(message: RemoteMessage): boolean {
  return message.role !== "user" && message.role !== "error" && message.role !== "handoff" && message.role !== "freshStart";
}

/** `presentedText`: the display text when the Mac sent one; tab mentions read (and are spoken) as "@Label". */
export function presentedText(message: RemoteMessage): string {
  return plainMentions(message.displayText ?? message.text ?? "");
}

/**
 * The reply to read aloud: the newest model reply that wasn't in the conversation when the prompt
 * was sent (`remoteSpeechTargetID`).
 */
export function speechTarget(messages: readonly RemoteMessage[], baseline: ReadonlySet<string>): RemoteMessage | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (isReply(messages[i]) && !baseline.has(messages[i].id)) return messages[i];
  }
  return null;
}

let speechBaseline = new Set<string>();
let speechTargetID: string | null = null;
let speechActive = false;
let shownSessionID: string | null = null;
const chunker = new SpeechChunker();

function resetSpeech(): void {
  speechActive = false;
  speechBaseline = new Set();
  speechTargetID = null;
}

/** Sends a spoken prompt to the shown conversation and reads its reply aloud. */
export async function sendSpoken(raw: string): Promise<void> {
  const text = raw.trim();
  // Paused: nothing is sent, ever.
  if (nav.paused.peek() || !text || sending.peek()) return;
  const sessionID = remote.selectedID.peek();
  if (!sessionID) return;
  sendError.value = null;
  speechBaseline = new Set(remote.selectedDetail.peek()?.messages.map((message) => message.id) ?? []);
  speechTargetID = null;
  speechActive = true;
  chunker.reset();
  voice.beginReply();
  sending.value = true;
  try {
    await remote.sendMessage(sessionID, { text, mode: nav.deliveryMode.peek() });
    nav.deliveryMode.value = "auto";
    sending.value = false;
    sync();
  } catch (error) {
    sending.value = false;
    sendError.value = (error as Error).message || "Cantrip did not accept the prompt.";
    finishSpeech();
  }
}

function speakReady(force: boolean): void {
  if (!speechTargetID) return;
  const target = remote.selectedDetail.peek()?.messages.find((message) => message.id === speechTargetID);
  if (!target) return;
  const chunk = chunker.next(presentedText(target), force);
  if (chunk) voice.enqueue(chunk);
}

/** Speaks what's left of the reply, then lets Voice Mode listen again. */
function finishSpeech(): void {
  if (!speechActive) return;
  speakReady(true);
  resetSpeech();
  voice.finishReply();
}

function sync(): void {
  const id = remote.selectedID.peek();
  if (shownSessionID !== id) {
    const changed = shownSessionID !== null;
    shownSessionID = id;
    // Another conversation: dictation and speech for the old one stop.
    if (changed) {
      const wasSpeaking = speechActive;
      resetSpeech();
      voice.stopListening(false);
      if (wasSpeaking || voiceState.peek().speaking) voice.stopSpeaking();
    }
  }
  if (!speechActive) return;
  if (speechTargetID === null) {
    speechTargetID = speechTarget(remote.selectedDetail.peek()?.messages ?? [], speechBaseline)?.id ?? null;
  }
  speakReady(false);
  if (!remote.selectedSession.peek()?.isStreaming && !remote.isMutating.peek() && !sending.peek()) finishSpeech();
}

effect(() => {
  void remote.selectedID.value;
  void remote.selectedDetail.value;
  void remote.selectedSession.value?.isStreaming;
  void remote.isMutating.value;
  untracked(sync);
});

// Pausing stops listening and speaking at once (Voice Mode closes itself).
effect(() => {
  if (!nav.paused.value) return;
  untracked(() => {
    resetSpeech();
    voice.stopAll();
  });
});

/** Barge-in: stops the running reply and its speech, and listens for a new prompt. */
export function interruptAndListen(): void {
  const id = remote.selectedID.peek();
  const session = remote.selectedSession.peek();
  resetSpeech();
  if (id && session?.isStreaming && remote.stoppingID.peek() !== id) {
    void remote.stop(id).catch((error: Error) => { sendError.value = `Stop failed: ${error.message}`; });
  }
  voice.stopSpeaking();
  void voice.startListening();
}

/** Voice Mode opened: hands-free, each utterance is sent. */
export function enterVoiceMode(listen = true): void {
  voice.setTranscriptHandler((text) => void sendSpoken(text));
  voice.setHandsFree(true);
  sendError.value = null;
  if (listen) resumeVoiceModeIfIdle();
}

export function leaveVoiceMode(): void {
  voice.setHandsFree(false);
  voice.setTranscriptHandler(null);
  resetSpeech();
  voice.stopAll();
}

export function resumeVoiceModeIfIdle(): void {
  const state = voiceState.peek();
  if (!state.handsFree || isWorking.peek() || state.listening || state.speaking || state.preparing) return;
  void voice.startListening();
}
