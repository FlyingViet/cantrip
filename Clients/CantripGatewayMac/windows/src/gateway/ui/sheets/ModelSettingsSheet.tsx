// Model Settings (CantripSessionSettingsView, CantripPrivateLocalSettings.swift): a tab's model, effort
// and context window (CantripModelSettingsView, CantripModelSettings.swift), or the saved Private Local
// tab's self-hosted server (CantripPrivateLocalSettingsView). Saves check the revision first and are
// never retried: a lost reply may still have reached the Mac.
import type { JSX } from "preact";
import { batch, useSignal } from "@preact/signals";
import { useEffect, useId, useState } from "preact/hooks";
import { api, pathComponent } from "../../api/client";
import type {
  ModelSelection, ModelSettingsSnapshot, PrivateLocalConfiguration, PrivateLocalModelsResponse, PrivateLocalSettingsSnapshot,
  RemoteSessionSummary,
} from "../../api/types";
import * as remote from "../../state/remote";
import { FormRow, FormSection, Sheet, Spinner } from "../kit";
import { Loading, StatusLabel, Warning, findSession, sleep, useAlive } from "./common";
import {
  DEFAULT_PRIVATE_CONFIGURATION, MODEL_REFRESH_POLLS, capitalized, contextLabel, errorText, isUnsupported, modelInfo,
  modelSettingsChange, modelValidationError, parseContextTokens, pickerChoices, privateModelChoices, selectModel, tokenLabel,
  writeFailure,
} from "./sheetLogic";

export function ModelSettingsSheet(props: { sessionID: string; onClose: () => void }): JSX.Element | null {
  return <SessionSettings key={props.sessionID} sessionID={props.sessionID} onClose={props.onClose} />;
}

function SessionSettings(props: { sessionID: string; onClose: () => void }): JSX.Element {
  // Like the Mac, the sheet keeps the session it opened for.
  const [session] = useState(() => findSession(props.sessionID));
  if (!session) {
    return (
      <Sheet title="Model Settings" onClose={props.onClose} width={420} fit
        footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
        <Warning>This tab is no longer on the Mac.</Warning>
      </Sheet>
    );
  }
  return session.isLocalPrivate
    ? <PrivateLocalSettings session={session} onClose={props.onClose} />
    : <ModelSettings session={session} onClose={props.onClose} />;
}

interface Choice { value: string; label: string; disabled?: boolean }

function Picker(props: { label: string; value: string; choices: Choice[]; disabled: boolean; onChange: (value: string) => void }): JSX.Element {
  const id = useId();
  return (
    <FormRow label={<label for={id}>{props.label}</label>}>
      <select id={id} class="select" value={props.value} disabled={props.disabled}
        onChange={(event) => props.onChange(event.currentTarget.value)}>
        {props.choices.map((choice) => (
          <option key={choice.value} value={choice.value} disabled={choice.disabled} selected={choice.value === props.value}>
            {choice.label}
          </option>
        ))}
      </select>
    </FormRow>
  );
}

// MARK: Model settings

function ModelSettings(props: { session: RemoteSessionSummary; onClose: () => void }): JSX.Element {
  const { session, onClose } = props;
  const settings = useSignal<ModelSettingsSnapshot | null>(null);
  const selection = useSignal<ModelSelection>({ model: "", effort: "", contextTier: "" });
  const usesDefaults = useSignal(true);
  const loading = useSignal(false);
  const saving = useSignal(false);
  const error = useSignal<string | null>(null);
  const alive = useAlive();
  const defaultsID = useId();
  const path = `/api/v1/sessions/${pathComponent(session.id)}/model-settings`;

  const fetchSettings = async (refreshModels = false): Promise<ModelSettingsSnapshot> => {
    try {
      return await api<ModelSettingsSnapshot>(path + (refreshModels ? "?refresh=true" : ""));
    } catch (failure) {
      if (!isUnsupported(failure)) throw failure;
      const latest = findSession(session.id) ?? session;
      throw new Error(latest.supportsModelSettings === true
        ? "This tab's model settings are no longer available."
        : "Update and reopen Cantrip on your Mac to change a tab's model, effort and context window.");
    }
  };

  const load = async (replaceDraft = false, refreshModels = false) => {
    if (loading.value || saving.value) return;
    loading.value = true;
    try {
      let value = await fetchSettings(refreshModels);
      if (!alive.current) return;
      if (replaceDraft || !settings.value) {
        batch(() => {
          selection.value = { ...value.selection };
          usesDefaults.value = value.usesDefaults;
          settings.value = value;
        });
      }
      // Do not silently rebase an edited form over another device's changes.
      const originalRevision = settings.value?.revision ?? value.revision;
      for (let attempt = 0; attempt < MODEL_REFRESH_POLLS && value.isRefreshing; attempt++) {
        await sleep(1000);
        if (!alive.current) return;
        value = await fetchSettings();
        if (!alive.current) return;
      }
      if (value.revision !== originalRevision) {
        error.value = "Model settings changed on another device. Reload before saving.";
        return;
      }
      settings.value = value;
      error.value = value.isRefreshing ? "Model lookup is still running. Reload in a moment." : null;
    } catch (failure) {
      if (alive.current) error.value = errorText(failure);
    } finally {
      loading.value = false;
    }
  };

  useEffect(() => { void load(true); }, []);

  const current = settings.value;
  const draft = selection.value;
  const info = modelInfo(current, draft);
  const unavailable = current?.unavailableReason;
  const validation = usesDefaults.value || !current ? null : modelValidationError(current, draft);
  const message = error.value ?? unavailable ?? validation ?? current?.catalogError ?? null;
  const busy = loading.value || saving.value;
  const pickersDisabled = usesDefaults.value || !current || Boolean(unavailable);
  const canSave = Boolean(current) && !busy && !remote.isMutating.value && !unavailable && !validation;

  const save = async () => {
    const snapshot = settings.value;
    if (!snapshot || !canSave) return;
    const change = modelSettingsChange(snapshot.revision, usesDefaults.value ? null : selection.value);
    saving.value = true;
    try {
      await remote.mutate(async () => {
        const latest = await fetchSettings();
        if (latest.revision !== change.revision) throw new Error("Model settings changed on another device. Reload before saving.");
        if (latest.unavailableReason) throw new Error(latest.unavailableReason);
        await api<ModelSettingsSnapshot>(path, { method: "POST", body: change });
      });
      void remote.refreshNow();
      if (alive.current) onClose();
    } catch (failure) {
      if (alive.current) error.value = writeFailure(failure) || "Model settings could not be saved.";
    } finally {
      saving.value = false;
    }
  };

  return (
    <Sheet title="Model Settings" onClose={onClose} locked={saving.value}
      footer={<>
        <button type="button" class="btn" disabled={saving.value} onClick={onClose}>Cancel</button>
        <button type="button" class="btn primary" disabled={!canSave} onClick={() => void save()}>Save</button>
      </>}>
      <fieldset class="sh-fieldset" disabled={busy}>
        <FormSection footer="Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.">
          <FormRow><span class="sh-headline truncate">{session.title}</span></FormRow>
          <FormRow label={<label for={defaultsID}>Use Mac defaults</label>}>
            <input id={defaultsID} type="checkbox" role="switch" class="switch" checked={usesDefaults.value}
              disabled={!current || Boolean(unavailable)}
              onChange={(event) => {
                const inherited = event.currentTarget.checked;
                batch(() => {
                  usesDefaults.value = inherited;
                  if (inherited && settings.value) selection.value = { ...settings.value.defaults };
                });
              }} />
          </FormRow>
          <Picker label="Model" value={draft.model} disabled={pickersDisabled}
            choices={[
              { value: "", label: `CLI default (${current?.fileDefaultModel ?? "Auto"})` },
              ...pickerChoices(current?.models.map((model) => model.id), draft.model).map((value) => ({ value, label: value })),
            ]}
            onChange={(value) => { if (settings.value) selection.value = selectModel(settings.value, selection.value, value); }} />
          <Picker label="Effort" value={draft.effort} disabled={pickersDisabled}
            choices={[
              { value: "", label: "Model default" },
              ...pickerChoices(info?.reasoningEfforts, draft.effort).map((value) => ({
                value, label: capitalized(value), disabled: !info?.reasoningEfforts?.includes(value),
              })),
            ]}
            onChange={(value) => { selection.value = { ...selection.value, effort: value }; }} />
          <Picker label="Context window" value={draft.contextTier} disabled={pickersDisabled}
            choices={[
              { value: "", label: "CLI default" },
              ...pickerChoices(info?.contextTiers, draft.contextTier).map((value) => ({
                value, label: contextLabel(info, value), disabled: !info?.contextTiers?.includes(value),
              })),
            ]}
            onChange={(value) => { selection.value = { ...selection.value, contextTier: value }; }} />
        </FormSection>
        {info?.contextWindow !== undefined ? (
          <FormSection>
            <FormRow label="Advertised maximum"><span class="sh-value">{tokenLabel(info.contextWindow)} tokens</span></FormRow>
            <FormRow><span class="sh-footnote">Tier values are input budgets, not total context.</span></FormRow>
          </FormSection>
        ) : null}
        <div role="alert">
          {message ? <FormSection><FormRow><span class="sh-warning selectable">{message}</span></FormRow></FormSection> : null}
        </div>
        <FormSection>
          <FormRow><button type="button" class="btn" onClick={() => void load(true)}>Reload settings</button></FormRow>
          <FormRow><button type="button" class="btn" onClick={() => void load(false, true)}>Refresh models</button></FormRow>
          {loading.value || current?.isRefreshing ? <FormRow><Loading text="Loading model options..." /></FormRow> : null}
        </FormSection>
      </fieldset>
    </Sheet>
  );
}

// MARK: Private Local

function PrivateLocalSettings(props: { session: RemoteSessionSummary; onClose: () => void }): JSX.Element {
  const { session, onClose } = props;
  const snapshot = useSignal<PrivateLocalSettingsSnapshot | null>(null);
  const configuration = useSignal<PrivateLocalConfiguration>({ ...DEFAULT_PRIVATE_CONFIGURATION });
  const contextText = useSignal(String(DEFAULT_PRIVATE_CONFIGURATION.contextWindow));
  const models = useSignal<string[]>([]);
  const loading = useSignal(false);
  const saving = useSignal(false);
  const needsReload = useSignal(false);
  const error = useSignal<string | null>(null);
  const alive = useAlive();
  const ids = { url: useId(), model: useId(), server: useId(), context: useId(), prompt: useId() };
  const base = `/api/v1/sessions/${pathComponent(session.id)}`;

  const fetchSettings = async (): Promise<PrivateLocalSettingsSnapshot> => {
    try {
      return await api<PrivateLocalSettingsSnapshot>(`${base}/private-settings`);
    } catch (failure) {
      if (!isUnsupported(failure)) throw failure;
      throw new Error("Update and reopen Cantrip on the Mac to use the saved Private Local tab. No cloud tab will be used instead.");
    }
  };

  const load = async () => {
    if (loading.value || saving.value) return;
    loading.value = true;
    try {
      const value = await fetchSettings();
      if (!alive.current) return;
      batch(() => {
        snapshot.value = value;
        configuration.value = { ...value.configuration };
        contextText.value = String(value.configuration.contextWindow);
        models.value = [];
        error.value = null;
        needsReload.value = false;
      });
    } catch (failure) {
      if (!alive.current) return;
      error.value = errorText(failure);
      needsReload.value = true;
    } finally {
      loading.value = false;
    }
  };

  const loadModels = async () => {
    if (loading.value || saving.value) return;
    loading.value = true;
    try {
      const data = await api<PrivateLocalModelsResponse>(`${base}/private-models?baseURL=${encodeURIComponent(configuration.value.baseURL)}`);
      if (!alive.current) return;
      models.value = data.models;
      error.value = data.models.length ? null : "No self-hosted models found. Install a model with Ollama on the selected server.";
    } catch (failure) {
      if (alive.current) error.value = errorText(failure);
    } finally {
      loading.value = false;
    }
  };

  useEffect(() => { void load(); }, []);

  const current = snapshot.value;
  const config = configuration.value;
  const unavailable = current?.unavailableReason;
  const busy = loading.value || saving.value;
  const canSave = Boolean(current) && !busy && !needsReload.value && !remote.isMutating.value && !unavailable && config.model !== "";
  const message = error.value ?? unavailable ?? null;
  const update = (change: Partial<PrivateLocalConfiguration>) => {
    configuration.value = { ...configuration.value, ...change };
  };

  const save = async () => {
    const value = snapshot.value;
    if (!value || !canSave) return;
    const change = { revision: value.revision, configuration: { ...configuration.value } };
    saving.value = true;
    try {
      await remote.mutate(async () => {
        const latest = await fetchSettings();
        if (latest.revision !== change.revision) {
          throw new Error("Private Local settings changed on another device. Reload before saving.");
        }
        if (latest.unavailableReason) throw new Error(latest.unavailableReason);
        await api<PrivateLocalSettingsSnapshot>(`${base}/private-settings`, { method: "POST", body: change });
      });
      void remote.refreshNow();
      if (alive.current) onClose();
    } catch (failure) {
      if (!alive.current) return;
      error.value = writeFailure(failure);
      needsReload.value = true;
    } finally {
      saving.value = false;
    }
  };

  return (
    <Sheet title="Private Local" onClose={onClose} locked={saving.value}
      footer={<>
        <button type="button" class="btn" disabled={saving.value} onClick={onClose}>Cancel</button>
        <button type="button" class="btn primary" disabled={!canSave} onClick={() => void save()}>Save</button>
      </>}>
      <fieldset class="sh-fieldset" disabled={busy}>
        <FormSection>
          <FormRow><StatusLabel icon="lock.shield.fill">Saved, self-hosted models</StatusLabel></FormRow>
          <FormRow>
            <span>Local means self-hosted, not limited to the Cantrip Mac. Your LLM server can run on another machine. Conversations stay saved on the Mac and available through Remote, with no cloud fallback.</span>
          </FormRow>
        </FormSection>
        <fieldset class="sh-fieldset" disabled={!current || Boolean(unavailable)}>
          <FormSection header="Self-hosted LLM server"
            footer="Cantrip connects to this server on your behalf. Use your own server's HTTPS URL, including a LAN or Tailscale hostname; reverse-proxy base paths are supported. HTTP is allowed only on loopback. Install models on that server. Context size depends on its model and RAM; saved history is not unlimited model context.">
            <FormRow stack>
              <label class="sh-field-label" for={ids.url}>Self-hosted Ollama URL</label>
              <input id={ids.url} class="text-field" type="url" value={config.baseURL} placeholder="https://your-llm-server"
                aria-label="Self-hosted Ollama server URL" autocomplete="off" spellcheck={false} autocapitalize="off"
                onInput={(event) => update({ baseURL: event.currentTarget.value })} />
            </FormRow>
            <FormRow stack>
              <label class="sh-field-label" for={ids.model}>Installed model</label>
              <input id={ids.model} class="text-field" type="text" value={config.model} placeholder="Installed model"
                autocomplete="off" spellcheck={false} autocapitalize="off"
                onInput={(event) => update({ model: event.currentTarget.value })} />
            </FormRow>
            {models.value.length ? (
              <FormRow label={<label for={ids.server}>Server model</label>}>
                <select id={ids.server} class="select" value={config.model} onChange={(event) => update({ model: event.currentTarget.value })}>
                  {privateModelChoices(models.value, config.model).map((value) => (
                    <option key={value} value={value} selected={value === config.model}>{value === "" ? "Choose a model" : value}</option>
                  ))}
                </select>
              </FormRow>
            ) : null}
            <FormRow><button type="button" class="btn" onClick={() => void loadModels()}>Load server models</button></FormRow>
            <FormRow stack>
              <label class="sh-field-label" for={ids.context}>Context tokens</label>
              <input id={ids.context} class="text-field" type="text" inputMode="numeric" value={contextText.value} placeholder="Context tokens"
                autocomplete="off"
                onInput={(event) => {
                  contextText.value = event.currentTarget.value;
                  const tokens = parseContextTokens(event.currentTarget.value);
                  if (tokens !== null) update({ contextWindow: tokens });
                }}
                onBlur={() => { contextText.value = String(configuration.value.contextWindow); }} />
            </FormRow>
            <FormRow stack>
              <label class="sh-field-label" for={ids.prompt}>System prompt</label>
              <textarea id={ids.prompt} class="text-field" rows={4} value={config.systemPrompt} placeholder="System prompt"
                onInput={(event) => update({ systemPrompt: event.currentTarget.value })} />
            </FormRow>
          </FormSection>
        </fieldset>
        <FormSection>
          <FormRow>
            <span>Tools, shell commands, shared-memory logging, push summaries and automatic external content are disabled. Auto queues follow-ups locally. Changes apply to this tab only, while idle.</span>
          </FormRow>
          <FormRow><button type="button" class="btn" onClick={() => void load()}>Reload settings</button></FormRow>
          {busy ? <FormRow><Spinner size="small" label={saving.value ? "Saving" : "Loading"} /></FormRow> : null}
          <div role="alert" class="sh-alert-row">
            {message ? <FormRow><span class="sh-warning selectable">{message}</span></FormRow> : null}
          </div>
        </FormSection>
      </fieldset>
    </Sheet>
  );
}
