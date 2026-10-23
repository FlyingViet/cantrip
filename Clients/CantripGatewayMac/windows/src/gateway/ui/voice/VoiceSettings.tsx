// Voice settings (the Mac's MacVoiceSettings): the speech recognition engine and its one-time model
// download, the reply voice, and the pause before a spoken prompt is sent. Works without a Mac
// connection, so the Settings window can show it too.
import "./voice.css";
import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { Icon } from "../icons";
import { FormRow, FormSection, Sheet, Spinner } from "../kit";
import * as voice from "./controller";
import { CheckCircleFill } from "./parts";
import * as recognizer from "./recognizer";
import {
  ENGINES, engineInfo, PAUSE_MAX, PAUSE_MIN, PAUSE_STEP, clampPause, sttEngine, voiceID, voicePause,
} from "./settings";
import { englishVoices, voiceDisplayName, voiceQuality } from "./speech";

/** The Voice settings form (grouped sections, no sheet). */
export function VoiceSettingsPanel(): JSX.Element {
  const [page, setPage] = useState<"voice" | "voices">("voice");
  const engine = sttEngine.value;
  useEffect(() => { void recognizer.verifyCache(engine); }, [engine]);
  return page === "voices" ? <ReplyVoiceList onBack={() => setPage("voice")} /> : <VoiceForm onVoices={() => setPage("voices")} />;
}

/** The Voice settings in a sheet with Done. */
export function VoiceSettingsSheet(props: { onClose: () => void }): JSX.Element {
  return (
    <Sheet title="Voice" onClose={props.onClose} width={620} height={600}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <VoiceSettingsPanel />
    </Sheet>
  );
}

function VoiceForm(props: { onVoices: () => void }): JSX.Element {
  const engine = engineInfo(sttEngine.value);
  const model = recognizer.modelState.value;
  const pause = voicePause.value;
  const voices = voice.systemVoices.value;
  const chosen = voiceID.value ? voices.find((item) => item.voiceURI === voiceID.value) : undefined;
  return (
    <div class="voice-settings">
      <FormSection header="Speech Recognition"
        footer="Whisper runs entirely on this PC after a one-time download; what you say never leaves it. Whisper Base is the recommended engine. Whisper Tiny is a smaller download and faster on older PCs, but less accurate.">
        <FormRow label="Engine">
          <div class="segmented" role="group" aria-label="Speech recognition engine">
            {ENGINES.map((item) => (
              <button key={item.id} type="button" aria-pressed={item.id === engine.id ? "true" : "false"}
                onClick={() => { sttEngine.value = item.id; }}>{item.title}</button>
            ))}
          </div>
        </FormRow>
        <ModelStateRow title={engine.title} state={model} />
        {model.kind === "idle" || model.kind === "cached" || model.kind === "failed" ? (
          <FormRow>
            <button type="button" class="btn" onClick={() => void recognizer.prepareIfNeeded().catch(() => undefined)}>
              <Icon name={recognizer.isPrepared() ? "waveform" : "arrow.down.circle"} size={14} />
              {recognizer.isPrepared() ? `Load ${engine.title}` : `Download ${engine.title} (${engine.size})`}
            </button>
            <span class="grow" />
            {recognizer.isPrepared() ? (
              <button type="button" class="btn plain destructive" onClick={() => void recognizer.deleteModel()}>Remove Download</button>
            ) : null}
          </FormRow>
        ) : null}
      </FormSection>

      <FormSection header="Voice"
        footer="How long to wait after you stop talking before sending. Raise it if a thinking or breathing pause sends your prompt too early.">
        <FormRow label="Voice engine"><span class="form-value">System</span></FormRow>
        <button type="button" class="form-row voice-nav-row" onClick={props.onVoices}>
          <span class="form-label">Reply voice</span>
          <span class="form-value">{chosen ? voiceDisplayName(chosen) : "Default"}</span>
          <Icon name="chevron.right" size={12} class="muted" />
        </button>
        <FormRow label={<label for="voice-pause">Pause before sending</label>}>
          <input id="voice-pause" class="voice-slider" type="range" min={PAUSE_MIN} max={PAUSE_MAX} step={PAUSE_STEP}
            value={pause} aria-valuetext={`${pause.toFixed(1)} seconds`}
            onInput={(event) => { voicePause.value = clampPause(Number((event.target as HTMLInputElement).value)); }} />
          <span class="voice-pause-value">{pause.toFixed(1)}s</span>
        </FormRow>
      </FormSection>
    </div>
  );
}

/** The Mac's parakeetState row. */
function ModelStateRow(props: { title: string; state: recognizer.ModelState }): JSX.Element {
  const { state } = props;
  switch (state.kind) {
    case "idle":
      return <FormRow><span class="voice-state muted"><Icon name="arrow.down.circle" size={14} />Model not downloaded</span></FormRow>;
    case "cached":
      return <FormRow><span class="voice-state green"><Icon name="checkmark.circle" size={14} />Model downloaded</span></FormRow>;
    case "ready":
      return (
        <FormRow>
          <span class="voice-state green"><CheckCircleFill />{props.title} ready</span>
          <span class="grow" />
          <span class="caption muted">{state.device === "webgpu" ? "Using the graphics processor" : "Using the processor"}</span>
        </FormRow>
      );
    case "preparing": {
      const percent = Math.round(state.progress * 100);
      return (
        <FormRow stack>
          <div class="row" role="status">
            <Spinner size="small" />
            <span class="grow">{state.phase}</span>
            <span class="muted voice-pause-value">{percent}%</span>
          </div>
          <div class="progress" role="progressbar" aria-label={state.phase} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}>
            <div style={{ width: `${percent}%` }} />
          </div>
        </FormRow>
      );
    }
    case "failed":
      return <FormRow><span class="voice-state red caption" role="alert"><Icon name="exclamationmark.triangle" size={14} />{state.message}</span></FormRow>;
  }
}

/** The Mac's VoiceListView: pick a voice and hear a sample. */
function ReplyVoiceList(props: { onBack: () => void }): JSX.Element {
  const voices = englishVoices(voice.systemVoices.value);
  const selected = voiceID.value || voice.selectedVoice()?.voiceURI || "";
  return (
    <div class="voice-settings">
      <div class="voice-subpage-header">
        <button type="button" class="btn plain" onClick={props.onBack} data-autofocus>
          <Icon name="chevron.left" size={14} />Voice
        </button>
        <h3 class="headline">Reply Voice</h3>
      </div>
      <FormSection header="Natural and Premium voices sound the most human — Default ones are robotic."
        footer="Click a voice to select it and hear a sample. The list shows the English voices installed on this PC; add more in Windows Settings → Time & language → Speech.">
        {voices.length ? (
          <div role="radiogroup" aria-label="Reply voice">
            {voices.map((item) => {
              const checked = item.voiceURI === selected;
              return (
                <button key={item.voiceURI} type="button" role="radio" aria-checked={checked ? "true" : "false"} class="form-row voice-choice"
                  onClick={() => { voiceID.value = item.voiceURI; voice.preview(item); }}>
                  {checked ? <CheckCircleFill /> : <Icon name="circle" size={18} class="muted" />}
                  <span class="grow voice-choice-text">
                    <span class="truncate">{voiceDisplayName(item)}</span>
                    <span class="caption muted">{item.lang} · {voiceQuality(item)}</span>
                  </span>
                  <Icon name="play.circle" size={18} class="muted" />
                </button>
              );
            })}
          </div>
        ) : (
          <FormRow><span class="muted">No English voices are installed on this PC.</span></FormRow>
        )}
      </FormSection>
    </div>
  );
}
