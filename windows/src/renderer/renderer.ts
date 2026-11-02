import "./styles.css";
import DOMPurify from "dompurify";
import { marked } from "marked";
import {
  BACKEND_IDS,
  backendCheckLine,
  backendLines,
  backendOffersSignIn,
  backendShowsCode,
  backendSignInLine,
  backendSignInPending,
  backendStatus,
  routeBackend,
} from "../shared/backendHealth";
import { getInstantAnswer, type InstantAnswer } from "../shared/instantAnswers";
import type {
  AppMatch,
  BackendHealth,
  BackendId,
  BackendsAction,
  BackendsSnapshot,
  BackendStatus,
  ContextTier,
  ReasoningEffort,
  RunRequest,
  ScreenCapture,
  ShortcutStatus,
  UpdateState,
} from "../shared/types";
import type { PluginSummary } from "../shared/pluginTypes";
import { PRECISE_KEY, SHARE_KEY } from "../shared/location";
import { forgetFix, promptLocation, readFlag, readPosition } from "./location";
import { extractWeatherBlock, visibleWeatherText } from "../shared/weather";
import { renderCard, renderCardLoading } from "./cards";

function requiredElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element as T;
}

const queryInput = requiredElement<HTMLInputElement>("query");
const suggestions = requiredElement<HTMLElement>("suggestions");
const transcript = requiredElement<HTMLElement>("transcript");
const output = requiredElement<HTMLElement>("output");
const runLabel = requiredElement<HTMLElement>("run-label");
const runState = requiredElement<HTMLElement>("run-state");
const stopButton = requiredElement<HTMLButtonElement>("stop");
const backendSelect = requiredElement<HTMLSelectElement>("backend");
const actionsCheckbox = requiredElement<HTMLInputElement>("allow-actions");
const workdirButton = requiredElement<HTMLButtonElement>("workdir");
const workdirLabel = requiredElement<HTMLElement>("workdir-label");
const shortcutBadge = requiredElement<HTMLElement>("shortcut");
const shortcutWarning = requiredElement<HTMLElement>("shortcut-warning");
const shortcutWarningText = requiredElement<HTMLElement>("shortcut-warning-text");
const retryShortcutButton = requiredElement<HTMLButtonElement>("retry-shortcut");
const attachmentsElement = requiredElement<HTMLElement>("attachments");
const screenContextButton = requiredElement<HTMLButtonElement>("screen-context");
const settingsToggle = requiredElement<HTMLButtonElement>("settings-toggle");
const pluginsToggle = requiredElement<HTMLButtonElement>("plugins-toggle");
const homeToggle = requiredElement<HTMLButtonElement>("home-toggle");
const settingsPanel = requiredElement<HTMLElement>("settings-panel");
const settingsClose = requiredElement<HTMLButtonElement>("settings-close");
const settingsBackend = requiredElement<HTMLSelectElement>("settings-backend");
const settingsModel = requiredElement<HTMLInputElement>("settings-model");
const settingsModelOptions = requiredElement<HTMLDataListElement>("settings-model-options");
const settingsModelHelp = requiredElement<HTMLElement>("settings-model-help");
const settingsEffort = requiredElement<HTMLSelectElement>("settings-effort");
const settingsContext = requiredElement<HTMLSelectElement>("settings-context");
const settingsContextHelp = requiredElement<HTMLElement>("settings-context-help");
const settingsResetBackend = requiredElement<HTMLButtonElement>("settings-reset-backend");
const settingsAllowActions = requiredElement<HTMLInputElement>("settings-allow-actions");
const settingsLaunchAtLogin = requiredElement<HTMLInputElement>("settings-launch-at-login");
const settingsLocationShare = requiredElement<HTMLInputElement>("settings-location-share");
const settingsLocationPrecise = requiredElement<HTMLInputElement>("settings-location-precise");
const settingsLocationStatus = requiredElement<HTMLElement>("settings-location-status");
const cardSlot = requiredElement<HTMLElement>("reply-card");
const settingsOpacity = requiredElement<HTMLInputElement>("settings-opacity");
const settingsOpacityValue = requiredElement<HTMLOutputElement>("settings-opacity-value");
const settingsError = requiredElement<HTMLElement>("settings-error");
const settingsShortcut = requiredElement<HTMLElement>("settings-shortcut");
const updateVersion = requiredElement<HTMLElement>("update-version");
const updateStatus = requiredElement<HTMLElement>("update-status");
const updateProgress = requiredElement<HTMLProgressElement>("update-progress");
const updateAction = requiredElement<HTMLButtonElement>("update-action");
const settingsPluginsSection = requiredElement<HTMLElement>("settings-plugins-section");
const pluginsList = requiredElement<HTMLElement>("plugins-list");
const pluginsOpenFolder = requiredElement<HTMLButtonElement>("plugins-open-folder");
const pluginsRescan = requiredElement<HTMLButtonElement>("plugins-rescan");
const pluginsInstallExample = requiredElement<HTMLButtonElement>("plugins-install-example");
const settingsBackendsSection = requiredElement<HTMLElement>("settings-backends-section");
const backendsList = requiredElement<HTMLElement>("backends-list");
const backendsCheckAll = requiredElement<HTMLButtonElement>("backends-check-all");
const backendsError = requiredElement<HTMLElement>("backends-error");

interface BackendControls {
  models: string[];
  efforts: ReasoningEffort[];
  contexts: ContextTier[];
  modelHelp: string;
  contextHelp: string;
}

const backendControls: Record<BackendId, BackendControls> = {
  claude: {
    models: ["sonnet", "opus", "haiku", "fable", "opusplan", "sonnet[1m]"],
    efforts: ["", "low", "medium", "high", "xhigh", "max"],
    contexts: [],
    modelHelp: "Aliases follow your installed Claude Code version; custom IDs are accepted.",
    contextHelp: "Claude context is selected by the model. Use sonnet[1m] when entitled.",
  },
  copilot: {
    models: [
      "auto",
      "gpt-5.6-sol",
      "gpt-5.6-luna",
      "claude-opus-4.8",
      "claude-sonnet-4.6",
      "claude-haiku-4.5",
      "gemini-2.5-pro",
    ],
    efforts: ["", "none", "minimal", "low", "medium", "high", "xhigh", "max"],
    contexts: ["", "default", "long_context"],
    modelHelp: "Availability depends on your Copilot plan; custom model IDs are accepted.",
    contextHelp: "Long context is only applied when the selected model supports it.",
  },
  codex: {
    models: ["gpt-5.4", "gpt-5.3-codex", "o3", "o4-mini"],
    efforts: ["", "minimal", "low", "medium", "high", "xhigh"],
    contexts: [],
    modelHelp: "Passed to codex exec --model; custom model IDs are accepted.",
    contextHelp: "Codex manages context from the selected model and its config.",
  },
  agy: {
    models: [
      "gemini-4-argon-medium",
      "gemini-4-argon-high",
      "gemini-4-argon-low",
      "gemini-3.8-flash-high",
      "gemini-3.8-flash-medium",
      "gemini-3.8-flash-low",
      "claude-opus-5-5-low",
      "claude-opus-5-5-medium",
      "claude-opus-5-5-high",
      "claude-sonnet-5-5-low",
      "claude-sonnet-5-5-medium",
      "claude-sonnet-5-5-high",
      "gpt-oss-120b-medium",
    ],
    efforts: ["", "low", "medium", "high"],
    contexts: [],
    modelHelp: "Passed to agy --model (from `agy models`); custom model IDs are accepted.",
    contextHelp: "Antigravity manages context from the selected model.",
  },
};

const effortLabels: Record<ReasoningEffort, string> = {
  "": "Default",
  none: "None",
  minimal: "Minimal",
  low: "Low — faster",
  medium: "Medium",
  high: "High — deeper reasoning",
  xhigh: "XHigh — hardest",
  max: "Max — supported models",
};

const contextLabels: Record<ContextTier, string> = {
  "": "CLI default",
  default: "Default",
  long_context: "Long context",
};

let apps: AppMatch[] = [];
let instantAnswer: InstantAnswer | null = null;
let selectedIndex = 0;
let currentRunId: string | null = null;
let workdir = "";
let searchVersion = 0;
let screenCaptures: ScreenCapture[] = [];
let outputText = "";
let currentRunMode: "ai" | "shell" | null = null;
let plugins: PluginSummary[] = [];
let backendHealth: BackendsSnapshot | null = null;
let backendActionBusy = false;
/** Backends whose Check now is on its way to the main process ("Checking…" at once). */
const backendCheckPending = new Set<BackendId>();
interface BackendRow {
  card: HTMLElement;
  body: HTMLElement;
  /** The one sign-in line (a live region; visually hidden while a code shows). */
  signIn: HTMLElement;
  device: HTMLElement;
  deviceKey: string;
  copyNote: HTMLElement;
  status: HTMLElement;
  actions: HTMLElement;
}
const backendRows = new Map<BackendId, BackendRow>();

function saveSettings(): void {
  localStorage.setItem("allowActions", String(actionsCheckbox.checked));
  localStorage.setItem("workdir", workdir);
}

function backendSetting(
  backend: BackendId,
  name: "model" | "effort" | "context",
): string {
  return localStorage.getItem(`backend.${backend}.${name}`) ?? "";
}

function setAllowActions(enabled: boolean): void {
  actionsCheckbox.checked = enabled;
  settingsAllowActions.checked = enabled;
  localStorage.setItem("allowActions", String(enabled));
}

function replaceOptions<T extends string>(
  select: HTMLSelectElement,
  values: T[],
  labels: Record<T, string>,
): void {
  select.replaceChildren();
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = labels[value];
    select.append(option);
  }
}

function renderBackendSettings(): void {
  const backend = settingsBackend.value as BackendId;
  const controls = backendControls[backend];
  settingsModel.value = backendSetting(backend, "model");
  settingsModelOptions.replaceChildren(
    ...controls.models.map((model) => {
      const option = document.createElement("option");
      option.value = model;
      return option;
    }),
  );
  settingsModelHelp.textContent = controls.modelHelp;

  replaceOptions(settingsEffort, controls.efforts, effortLabels);
  settingsEffort.value = backendSetting(backend, "effort");

  if (controls.contexts.length) {
    replaceOptions(settingsContext, controls.contexts, contextLabels);
    settingsContext.disabled = false;
    settingsContext.value = backendSetting(backend, "context");
  } else {
    settingsContext.replaceChildren(new Option("Managed by model / CLI", ""));
    settingsContext.disabled = true;
  }
  settingsContextHelp.textContent = controls.contextHelp;
}

function toggleSettings(open: boolean): void {
  settingsPanel.classList.toggle("hidden", !open);
  settingsToggle.setAttribute("aria-expanded", String(open));
  window.cantrip.setExpanded(open || !transcript.classList.contains("hidden"));
  if (open) {
    settingsBackend.value = backendSelect.value;
    renderBackendSettings();
    settingsClose.focus();
  } else {
    queryInput.focus();
  }
}

function applyShortcutStatus(status: ShortcutStatus): void {
  shortcutBadge.textContent = status.displayName;
  shortcutBadge.title = status.message ?? `Summon Cantrip with ${status.displayName}`;
  shortcutWarning.classList.toggle("hidden", !status.message);
  shortcutWarningText.textContent = status.message ?? "";
  retryShortcutButton.classList.toggle("hidden", !status.isFallback);
  settingsShortcut.textContent = status.displayName;
}

function renderUpdateState(state: UpdateState): void {
  updateVersion.textContent = `Cantrip ${state.currentVersion}`;
  updateStatus.textContent = state.message;
  updateStatus.classList.toggle("error", state.status === "error");
  const downloading = state.status === "downloading";
  updateProgress.classList.toggle("hidden", !downloading);
  updateProgress.value = state.percent ?? 0;

  updateAction.disabled = state.status === "checking" || downloading;
  switch (state.status) {
    case "available":
      updateAction.textContent = `Download ${state.availableVersion ?? "update"}`;
      break;
    case "downloaded":
      updateAction.textContent = "Restart to update";
      break;
    case "checking":
      updateAction.textContent = "Checking…";
      break;
    case "downloading":
      updateAction.textContent = `Downloading ${Math.round(state.percent ?? 0)}%`;
      break;
    case "unsupported":
      updateAction.textContent = "Installed builds only";
      updateAction.disabled = true;
      break;
    default:
      updateAction.textContent = "Check for updates";
  }
}

function renderAttachments(): void {
  attachmentsElement.replaceChildren();
  attachmentsElement.classList.toggle("hidden", screenCaptures.length === 0);
  screenContextButton.classList.toggle("active", screenCaptures.length > 0);
  for (const capture of screenCaptures) {
    const item = document.createElement("div");
    item.className = "attachment";
    const image = document.createElement("img");
    image.src = capture.dataUrl;
    image.alt = "";
    const label = document.createElement("span");
    label.textContent = capture.name;
    label.title = `${capture.name} · ${capture.width}×${capture.height}`;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.title = `Remove ${capture.name}`;
    remove.addEventListener("click", () => {
      screenCaptures = screenCaptures.filter((entry) => entry.id !== capture.id);
      renderAttachments();
    });
    item.append(image, label, remove);
    attachmentsElement.append(item);
  }
}

function showSettingsError(message: string): void {
  settingsError.textContent = message;
  settingsError.classList.remove("hidden");
}

function renderPlugins(): void {
  pluginsList.replaceChildren();
  if (!plugins.length) {
    const empty = document.createElement("p");
    empty.className = "plugins-empty";
    empty.textContent = "No plugins installed. Add a folder containing manifest.json.";
    pluginsList.append(empty);
    return;
  }

  for (const plugin of plugins) {
    const card = document.createElement("article");
    card.className = `plugin-card${plugin.approved ? "" : " needs-approval"}`;

    const header = document.createElement("div");
    header.className = "plugin-card-header";
    const identity = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = plugin.name;
    identity.append(name);
    if (plugin.version) {
      const version = document.createElement("small");
      version.textContent = plugin.version;
      identity.append(version);
    }
    const enabled = document.createElement("label");
    enabled.className = "plugin-enable";
    const enabledInput = document.createElement("input");
    enabledInput.type = "checkbox";
    enabledInput.checked = plugin.enabled;
    enabledInput.disabled = !plugin.approved;
    enabledInput.addEventListener("change", async () => {
      plugins = await window.cantrip.setPluginEnabled(plugin.id, enabledInput.checked);
      renderPlugins();
    });
    enabled.append(enabledInput, document.createTextNode("Enabled"));
    header.append(identity, enabled);
    card.append(header);

    if (plugin.description) {
      const description = document.createElement("p");
      description.textContent = plugin.description;
      card.append(description);
    }

    const state = document.createElement("div");
    state.className = `plugin-state ${plugin.active ? "active" : plugin.approved ? "" : "warning"}`;
    state.textContent = plugin.active
      ? "Active"
      : plugin.approved
        ? "Approved but disabled"
        : "Approval required";
    card.append(state);

    if (plugin.capabilitySummary.length) {
      const details = document.createElement("details");
      details.className = "plugin-capabilities";
      const summary = document.createElement("summary");
      summary.textContent = `${plugin.capabilitySummary.length} declared capability${
        plugin.capabilitySummary.length === 1 ? "" : "ies"
      }`;
      const list = document.createElement("ul");
      for (const capability of plugin.capabilitySummary) {
        const item = document.createElement("li");
        item.textContent = capability;
        list.append(item);
      }
      details.append(summary, list);
      card.append(details);
    }

    const actions = document.createElement("div");
    actions.className = "plugin-actions";
    if (!plugin.approved) {
      const approve = document.createElement("button");
      approve.type = "button";
      approve.className = "primary";
      approve.textContent = "Review & approve";
      approve.addEventListener("click", async () => {
        const declarations = plugin.capabilitySummary.length
          ? plugin.capabilitySummary.join("\n• ")
          : "No commands or native capabilities.";
        if (
          !window.confirm(
            `Approve ${plugin.name}?\n\nManifest SHA-256:\n${plugin.manifestHash}\n\n• ${declarations}`,
          )
        ) {
          return;
        }
        plugins = await window.cantrip.approvePlugin(plugin.id);
        renderPlugins();
      });
      actions.append(approve);
    }
    if (plugin.active && plugin.hasPanel) {
      const open = document.createElement("button");
      open.type = "button";
      open.textContent = "Open dashboard";
      open.addEventListener("click", async () => {
        const result = await window.cantrip.openPluginPanel(plugin.id);
        if (!result.ok) showSettingsError(result.error ?? "Could not open dashboard.");
      });
      actions.append(open);
    }
    if (plugin.approved) {
      const revoke = document.createElement("button");
      revoke.type = "button";
      revoke.textContent = "Revoke";
      revoke.addEventListener("click", async () => {
        plugins = await window.cantrip.revokePlugin(plugin.id);
        renderPlugins();
      });
      actions.append(revoke);
    }
    card.append(actions);
    pluginsList.append(card);
  }
}

/** Backend picker options: signed-out or missing CLIs can't be chosen; routing picks a backup. */
function applyBackendStatuses(statuses: BackendStatus[]): void {
  for (const status of statuses) {
    let option = [...backendSelect.options].find((entry) => entry.value === status.id);
    if (!option) {
      option = document.createElement("option");
      option.value = status.id;
      backendSelect.append(option);
    }
    option.textContent = status.label;
    option.disabled = !status.available;
    option.title = status.detail;

    let settingsOption = [...settingsBackend.options].find((entry) => entry.value === status.id);
    if (!settingsOption) {
      settingsOption = document.createElement("option");
      settingsOption.value = status.id;
      settingsBackend.append(settingsOption);
    }
    const signedOut = backendHealth?.backends.some((entry) => entry.id === status.id && entry.unavailable);
    settingsOption.textContent = status.available
      ? status.label
      : `${status.label} — ${signedOut ? "signed out" : "not installed"}`;
  }
  const routed = routeBackend(localStorage.getItem("backend"), statuses);
  if (routed && backendSelect.value !== routed) {
    backendSelect.value = routed;
    renderSuggestions();
  }
}

function backendButton(
  label: string,
  ariaLabel: string,
  focusKey: string,
  onClick: () => void,
  options: { primary?: boolean; disabled?: boolean; describedBy?: string } = {},
): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.setAttribute("aria-label", ariaLabel);
  button.dataset.focusKey = focusKey;
  if (options.primary) button.className = "primary";
  // aria-disabled keeps a pressed button focusable while its backend is busy.
  if (options.disabled) button.setAttribute("aria-disabled", "true");
  if (options.describedBy) button.setAttribute("aria-describedby", options.describedBy);
  button.addEventListener("click", () => {
    if (button.getAttribute("aria-disabled") !== "true") onClick();
  });
  return button;
}

function backendLine(text: string, warning = false): HTMLParagraphElement {
  const line = document.createElement("p");
  line.className = `backend-line${warning ? " warning" : ""}`;
  line.textContent = text;
  return line;
}

function backendRowBody(backend: BackendHealth, now: number): HTMLElement[] {
  const header = document.createElement("div");
  header.className = "plugin-card-header";
  const identity = document.createElement("span");
  const name = document.createElement("strong");
  name.textContent = backend.name;
  const status = backendStatus(backend);
  const state = document.createElement("span");
  state.className = `backend-state ${status.tone || (backend.state === "ready" && !backend.checking ? "ready" : "")}`;
  state.textContent = status.text;
  identity.append(name, state);
  header.append(identity);

  const parts: HTMLElement[] = [header];
  for (const line of backendLines(backend, "on this PC", now)) {
    parts.push(backendLine(line.text, line.tone === "warning"));
  }
  return parts;
}

/** The code box: the link, the code (the instructions live here), Copy code and Open link. */
function backendDevice(backend: BackendHealth, row: BackendRow, url: string, code: string): HTMLElement[] {
  const intro = backendLine(`Open ${url} on any device and enter this code:`);
  const codeElement = document.createElement("code");
  codeElement.className = "backend-code";
  codeElement.textContent = code;
  const actions = document.createElement("div");
  actions.className = "plugin-actions";
  actions.append(
    backendButton("Copy code", `Copy code for ${backend.name} sign-in`, `${backend.id}:copy`, () => {
      navigator.clipboard.writeText(code).then(
        () => (row.copyNote.textContent = "Code copied."),
        () => (row.copyNote.textContent = "Couldn't copy: select the code and press Ctrl+C."),
      );
    }),
    backendButton(
      "Open link",
      `Open link for ${backend.name} sign-in`,
      `${backend.id}:open`,
      () => void window.cantrip.openExternal(url),
      { primary: true },
    ),
  );
  row.copyNote.textContent = "";
  return [intro, codeElement, actions, row.copyNote];
}

function backendRowActions(backend: BackendHealth): HTMLElement[] {
  const id = backend.id;
  const pending = backendSignInPending(backend);
  const buttons = [
    backendButton(
      "Check now",
      `Check ${backend.name} now`,
      `${id}:check`,
      () => void runBackendAction({ action: "check", id }),
      { disabled: backendActionBusy || backend.checking },
    ),
  ];
  const signInLine = backendSignInLine(backend);
  if (pending || backendOffersSignIn(backend)) {
    buttons.push(
      backendButton(
        pending ? "Cancel" : "Sign in",
        pending ? `Cancel ${backend.name} sign-in` : `Sign in to ${backend.name}`,
        `${id}:sign-in`,
        () => void runBackendAction({ action: pending ? "cancelSignIn" : "signIn", id }),
        {
          primary: !pending,
          disabled: backendActionBusy,
          describedBy: !pending && signInLine ? `backend-${id}-sign-in` : undefined,
        },
      ),
    );
  }
  return buttons;
}

/** Settings › Backends. Rows and their live status lines persist; their contents are redrawn. */
function renderBackendHealth(): void {
  if (!backendHealth) return;
  const focused =
    document.activeElement instanceof HTMLElement && backendsList.contains(document.activeElement)
      ? document.activeElement.dataset.focusKey
      : undefined;
  const now = Date.now();
  for (const entry of backendHealth.backends) {
    const backend = { ...entry, checking: entry.checking || backendCheckPending.has(entry.id) };
    let row = backendRows.get(backend.id);
    if (!row) {
      const liveLine = (className: string) => {
        const line = document.createElement("p");
        line.className = className;
        line.setAttribute("role", "status");
        line.setAttribute("aria-live", "polite");
        return line;
      };
      const card = document.createElement("section");
      card.className = "plugin-card backend-row";
      card.setAttribute("aria-label", `${backend.name} backend`);
      const body = document.createElement("div");
      const signIn = liveLine("backend-line backend-sign-in");
      signIn.id = `backend-${backend.id}-sign-in`;
      const device = document.createElement("div");
      device.className = "backend-device hidden";
      const copyNote = liveLine("backend-status");
      const status = liveLine("backend-status");
      const actions = document.createElement("div");
      actions.className = "plugin-actions";
      card.append(body, signIn, device, status, actions);
      backendsList.append(card);
      row = { card, body, signIn, device, deviceKey: "", copyNote, status, actions };
      backendRows.set(backend.id, row);
    }
    row.card.classList.toggle(
      "needs-approval",
      backend.state === "signedOut" || backend.state === "outOfQuota",
    );
    row.body.replaceChildren(...backendRowBody(backend, now));

    // While a code shows, its box carries the instructions; screen readers still hear it's ready.
    const { url, code } = backend.signIn;
    const showsCode = backendShowsCode(backend) && Boolean(url && code);
    const line = backendSignInLine(backend);
    const signInText = line ?? (showsCode ? `${backend.name} sign-in code ${code} is ready.` : "");
    row.signIn.classList.toggle("sr-only", !line && showsCode);
    if (row.signIn.textContent !== signInText) row.signIn.textContent = signInText;
    const deviceKey = showsCode ? `${url}\n${code}` : "";
    if (row.deviceKey !== deviceKey) {
      row.deviceKey = deviceKey;
      row.device.replaceChildren(...(showsCode && url && code ? backendDevice(backend, row, url, code) : []));
    }
    row.device.classList.toggle("hidden", !showsCode);

    const statusText = backendCheckLine(backend, now);
    if (row.status.textContent !== statusText) row.status.textContent = statusText;
    row.actions.replaceChildren(...backendRowActions(backend));
  }
  backendsCheckAll.setAttribute("aria-disabled", String(backendActionBusy));
  if (focused && !backendsList.contains(document.activeElement)) {
    const [id] = focused.split(":");
    (
      backendsList.querySelector<HTMLElement>(`[data-focus-key="${focused}"]`) ??
      backendsList.querySelector<HTMLElement>(`[data-focus-key="${id}:check"]`)
    )?.focus();
  }
}

function applyBackendHealth(snapshot: BackendsSnapshot): void {
  backendHealth = snapshot;
  renderBackendHealth();
  void window.cantrip.getBackendStatus().then(applyBackendStatuses);
}

/** The reply's `message` isn't shown: each row's sign-in state says what's next (as on the Mac and iPhone). */
async function runBackendAction(action: BackendsAction): Promise<void> {
  if (backendActionBusy) return;
  backendActionBusy = true;
  backendsError.classList.add("hidden");
  if (action.action === "check") {
    for (const id of action.id ? [action.id] : BACKEND_IDS) backendCheckPending.add(id);
  }
  renderBackendHealth();
  try {
    const snapshot = await window.cantrip.backendAction(action);
    backendActionBusy = false;
    backendCheckPending.clear();
    applyBackendHealth(snapshot);
  } catch (error) {
    backendsError.textContent = error instanceof Error ? error.message : String(error);
    backendsError.classList.remove("hidden");
  } finally {
    backendActionBusy = false;
    backendCheckPending.clear();
    renderBackendHealth();
  }
}

function setBusy(busy: boolean): void {
  stopButton.classList.toggle("hidden", !busy);
  backendSelect.disabled = busy;
  actionsCheckbox.disabled = busy;
  runState.textContent = busy ? "Running…" : "";
}

function renderOutput(markdown: boolean): void {
  output.classList.toggle("plain-output", !markdown);
  if (markdown) {
    // A reply's `weather` block becomes the card under it, never text (not even while it streams).
    const rendered = marked.parse(visibleWeatherText(outputText, currentRunId !== null), {
      async: false,
      breaks: true,
      gfm: true,
    }) as string;
    output.innerHTML = DOMPurify.sanitize(rendered, {
      USE_PROFILES: { html: true },
    });
    // The reply's card scrolls with the reply it belongs to.
    if (cardSlot.childElementCount) output.append(cardSlot);
  } else {
    output.textContent = outputText;
  }
  output.scrollTop = output.scrollHeight;
}

let cardRequest = 0;

function clearCard(): void {
  cardRequest += 1;
  cardSlot.replaceChildren();
  cardSlot.classList.add("hidden");
}

/**
 * The finished reply's weather block, as an Open-Meteo card for its place (or this PC, with Location
 * on): a generic card document the main process builds, drawn block by block.
 */
async function showWeather(): Promise<void> {
  const block = extractWeatherBlock(outputText);
  if (!block.found || block.place === undefined) return;
  const ticket = ++cardRequest;
  renderCardLoading(cardSlot, "Getting the forecast from Open-Meteo…");
  output.append(cardSlot);
  const location = block.place ? undefined : await promptLocation();
  const card = await window.cantrip.weatherCard({ place: block.place, location });
  if (ticket !== cardRequest) return;
  renderCard(cardSlot, card, (url) => void window.cantrip.openExternal(url));
  if (cardSlot.classList.contains("hidden")) return;
  output.append(cardSlot);
  cardSlot.scrollIntoView({ block: "nearest" });
}

function showMessage(title: string, message: string, isError = false): void {
  clearCard();
  window.cantrip.setExpanded(true);
  transcript.classList.remove("hidden");
  runLabel.textContent = title;
  runState.textContent = isError ? "Error" : "";
  output.classList.toggle("error", isError);
  outputText = message;
  currentRunMode = null;
  renderOutput(!isError);
}

function renderSuggestions(): void {
  suggestions.replaceChildren();
  const query = queryInput.value.trim();

  if (!query) {
    const tips = [
      ["Launch an app", "Type a Start Menu app name"],
      ["Calculate instantly", "Try 142 * 8.5 or 10 km to miles"],
      ["Run PowerShell", "Prefix an explicit command with !"],
    ];
    for (const [title, subtitle] of tips) {
      const item = document.createElement("div");
      item.className = "suggestion tip";
      item.innerHTML = `<span class="suggestion-icon">✦</span><span><strong></strong><small></small></span>`;
      item.querySelector("strong")!.textContent = title;
      item.querySelector("small")!.textContent = subtitle;
      suggestions.append(item);
    }
    return;
  }

  if (instantAnswer) {
    suggestions.append(createSuggestion("=", instantAnswer.title, instantAnswer.subtitle, 0));
    return;
  }

  if (query.startsWith("!")) {
    suggestions.append(
      createSuggestion(">", query.slice(1).trim() || "PowerShell command", "Run in the selected folder", 0),
    );
    return;
  }

  apps.forEach((app, index) => {
    suggestions.append(
      createSuggestion(
        app.kind === "shortcut" ? "◆" : "◇",
        app.name,
        "Open app",
        index,
      ),
    );
  });

  const aiIndex = apps.length;
  suggestions.append(
    createSuggestion(
      "✦",
      query,
      `Ask ${backendSelect.selectedOptions[0]?.textContent ?? "AI"} · Ctrl+Enter`,
      aiIndex,
    ),
  );
}

function createSuggestion(
  icon: string,
  title: string,
  subtitle: string,
  index: number,
): HTMLElement {
  const item = document.createElement("button");
  item.type = "button";
  item.className = `suggestion${selectedIndex === index ? " selected" : ""}`;
  item.dataset.index = String(index);

  const iconElement = document.createElement("span");
  iconElement.className = "suggestion-icon";
  iconElement.textContent = icon;
  const copy = document.createElement("span");
  const strong = document.createElement("strong");
  strong.textContent = title;
  const small = document.createElement("small");
  small.textContent = subtitle;
  copy.append(strong, small);
  item.append(iconElement, copy);

  item.addEventListener("mouseenter", () => {
    selectedIndex = index;
    renderSuggestions();
  });
  item.addEventListener("click", () => {
    selectedIndex = index;
    void submit(false);
  });
  return item;
}

async function updateQuery(): Promise<void> {
  const version = ++searchVersion;
  const query = queryInput.value.trim();
  instantAnswer = getInstantAnswer(query);
  selectedIndex = 0;

  if (!query || instantAnswer || query.startsWith("!")) {
    apps = [];
    renderSuggestions();
    return;
  }

  apps = await window.cantrip.searchApps(query);
  if (version === searchVersion) renderSuggestions();
}

async function submit(forceAi: boolean): Promise<void> {
  const query = queryInput.value.trim();
  if (!query || currentRunId) return;

  if (!forceAi && instantAnswer) {
    showMessage("Instant answer", instantAnswer.title);
    return;
  }

  if (!forceAi && !query.startsWith("!") && selectedIndex < apps.length) {
    const result = await window.cantrip.launchApp(apps[selectedIndex].id);
    if (result.ok) window.cantrip.hide();
    else showMessage("Could not open app", result.error ?? "Unknown error", true);
    return;
  }

  const mode = !forceAi && query.startsWith("!") ? "shell" : "ai";
  const prompt = mode === "shell" ? query.slice(1).trim() : query;
  if (!prompt) return;

  const runId = crypto.randomUUID();
  const request: RunRequest = {
    runId,
    mode,
    prompt,
    backend: backendSelect.value as BackendId,
    workdir,
    allowActions: actionsCheckbox.checked,
    model: backendSetting(backendSelect.value as BackendId, "model"),
    effort: backendSetting(
      backendSelect.value as BackendId,
      "effort",
    ) as ReasoningEffort,
    contextTier: backendSetting(
      backendSelect.value as BackendId,
      "context",
    ) as ContextTier,
    attachments: screenCaptures.map(({ name, dataUrl }) => ({ name, dataUrl })),
    location: mode === "ai" ? await promptLocation() : undefined,
  };

  currentRunId = runId;
  currentRunMode = mode;
  window.cantrip.setExpanded(true);
  transcript.classList.remove("hidden");
  output.classList.remove("error");
  outputText = "";
  clearCard();
  renderOutput(mode === "ai");
  runLabel.textContent =
    mode === "shell" ? "PowerShell" : backendSelect.selectedOptions[0]?.textContent ?? "AI";
  setBusy(true);

  const result = await window.cantrip.startRun(request);
  if (!result.ok) {
    currentRunId = null;
    setBusy(false);
    showMessage("Could not start", result.error ?? "Unknown error", true);
  } else {
    screenCaptures = [];
    renderAttachments();
  }
}

queryInput.addEventListener("input", () => void updateQuery());
queryInput.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (!settingsPanel.classList.contains("hidden")) toggleSettings(false);
    else window.cantrip.hide();
    return;
  }
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const count = instantAnswer || queryInput.value.trim().startsWith("!") ? 1 : apps.length + 1;
    const delta = event.key === "ArrowDown" ? 1 : -1;
    selectedIndex = (selectedIndex + delta + count) % count;
    renderSuggestions();
    return;
  }
  if (event.key === "Enter") {
    event.preventDefault();
    void submit(event.ctrlKey);
  }
});

stopButton.addEventListener("click", () => {
  if (currentRunId) void window.cantrip.cancelRun(currentRunId);
});

backendSelect.addEventListener("change", () => {
  // Only a person's pick is the preference: a backup routing chose while one is signed out isn't.
  localStorage.setItem("backend", backendSelect.value);
  saveSettings();
  settingsBackend.value = backendSelect.value;
  renderBackendSettings();
  renderSuggestions();
});
actionsCheckbox.addEventListener("change", () => setAllowActions(actionsCheckbox.checked));
workdirButton.addEventListener("click", async () => {
  const selected = await window.cantrip.chooseWorkdir(workdir);
  if (!selected) return;
  workdir = selected;
  workdirLabel.textContent = selected.split(/[\\/]/).filter(Boolean).at(-1) ?? selected;
  workdirButton.title = selected;
  saveSettings();
});
screenContextButton.addEventListener("click", async () => {
  if (screenCaptures.length) {
    screenCaptures = [];
    renderAttachments();
    return;
  }
  screenContextButton.disabled = true;
  const result = await window.cantrip.captureScreens();
  screenContextButton.disabled = false;
  if (!result.ok) {
    showMessage("Screen capture failed", result.error ?? "Unknown error", true);
    return;
  }
  screenCaptures = result.captures;
  renderAttachments();
});
retryShortcutButton.addEventListener("click", async () => {
  retryShortcutButton.disabled = true;
  applyShortcutStatus(await window.cantrip.retryShortcut());
  retryShortcutButton.disabled = false;
});
settingsToggle.addEventListener("click", () => {
  toggleSettings(settingsPanel.classList.contains("hidden"));
});
homeToggle.addEventListener("click", () => window.cantrip.openHome());
pluginsToggle.addEventListener("click", () => {
  toggleSettings(true);
  settingsPluginsSection.scrollIntoView({ behavior: "smooth", block: "start" });
});
settingsClose.addEventListener("click", () => toggleSettings(false));
backendsCheckAll.addEventListener("click", () => {
  if (backendsCheckAll.getAttribute("aria-disabled") !== "true") void runBackendAction({ action: "check" });
});
settingsBackend.addEventListener("change", renderBackendSettings);
settingsModel.addEventListener("input", () => {
  const backend = settingsBackend.value as BackendId;
  localStorage.setItem(`backend.${backend}.model`, settingsModel.value.trim());
});
settingsEffort.addEventListener("change", () => {
  const backend = settingsBackend.value as BackendId;
  localStorage.setItem(`backend.${backend}.effort`, settingsEffort.value);
});
settingsContext.addEventListener("change", () => {
  const backend = settingsBackend.value as BackendId;
  localStorage.setItem(`backend.${backend}.context`, settingsContext.value);
});
settingsResetBackend.addEventListener("click", () => {
  const backend = settingsBackend.value as BackendId;
  for (const name of ["model", "effort", "context"]) {
    localStorage.removeItem(`backend.${backend}.${name}`);
  }
  renderBackendSettings();
});
settingsAllowActions.addEventListener("change", () =>
  setAllowActions(settingsAllowActions.checked),
);
settingsLaunchAtLogin.addEventListener("change", async () => {
  settingsError.classList.add("hidden");
  const result = await window.cantrip.setLaunchAtLogin(settingsLaunchAtLogin.checked);
  if (!result.ok) {
    settingsLaunchAtLogin.checked = !settingsLaunchAtLogin.checked;
    settingsError.textContent = result.error ?? "Could not update launch at login.";
    settingsError.classList.remove("hidden");
  }
});
function showLocationStatus(text: string | null): void {
  settingsLocationStatus.textContent = text ?? "";
  settingsLocationStatus.classList.toggle("hidden", !text);
}

async function checkLocation(): Promise<void> {
  const precise = settingsLocationPrecise.checked;
  showLocationStatus("Finding this PC's location…");
  const reading = await readPosition(precise);
  if (!settingsLocationShare.checked) return;
  showLocationStatus("fix" in reading
    ? `Found${precise ? "" : "; it's sent rounded to about 1 km"}. The reply names the place it used.`
    : reading.error);
}

function renderLocationSettings(): void {
  settingsLocationShare.checked = readFlag(SHARE_KEY);
  settingsLocationPrecise.checked = readFlag(PRECISE_KEY);
  settingsLocationPrecise.disabled = !settingsLocationShare.checked;
}

settingsLocationShare.addEventListener("change", () => {
  localStorage.setItem(SHARE_KEY, String(settingsLocationShare.checked));
  forgetFix();
  renderLocationSettings();
  if (settingsLocationShare.checked) void checkLocation();
  else showLocationStatus("Off. Prompts don't include this PC's location.");
});
settingsLocationPrecise.addEventListener("change", () => {
  localStorage.setItem(PRECISE_KEY, String(settingsLocationPrecise.checked));
  forgetFix();
  if (settingsLocationShare.checked) void checkLocation();
});
settingsOpacity.addEventListener("input", () => {
  const value = Number(settingsOpacity.value);
  settingsOpacityValue.value = `${value}%`;
  localStorage.setItem("panelOpacity", String(value));
  window.cantrip.setWindowOpacity(value / 100);
});
updateAction.addEventListener("click", async () => {
  updateAction.disabled = true;
  const state = await window.cantrip.getUpdateState();
  if (state.status === "available") {
    renderUpdateState(await window.cantrip.downloadUpdate());
  } else if (state.status === "downloaded") {
    const result = await window.cantrip.installUpdate();
    if (!result.ok) {
      renderUpdateState({
        ...state,
        status: "error",
        message: result.error ?? "Could not install the update.",
      });
      pluginsOpenFolder.addEventListener("click", () => void window.cantrip.openPluginsFolder());
      pluginsInstallExample.addEventListener("click", async () => {
        pluginsInstallExample.disabled = true;
        try {
          plugins = await window.cantrip.installExamplePlugin();
          renderPlugins();
        } catch (error) {
          showSettingsError(String(error));
        } finally {
          pluginsInstallExample.disabled = false;
        }
      });
      pluginsRescan.addEventListener("click", async () => {
        pluginsRescan.disabled = true;
        plugins = await window.cantrip.rescanPlugins();
        renderPlugins();
        pluginsRescan.disabled = false;
      });
    }
  } else {
    renderUpdateState(await window.cantrip.checkForUpdates());
  }
});
document.addEventListener("keydown", (event) => {
  if (
    event.key === "Escape" &&
    !settingsPanel.classList.contains("hidden") &&
    event.target !== queryInput
  ) {
    event.preventDefault();
    toggleSettings(false);
  }
});

window.cantrip.onRunChunk((event) => {
  if (event.runId !== currentRunId) return;
  outputText += event.text;
  renderOutput(currentRunMode === "ai");
});

window.cantrip.onRunExit((event) => {
  if (event.runId !== currentRunId) return;
  currentRunId = null;
  setBusy(false);
  if (event.error || (event.exitCode !== 0 && event.exitCode !== null)) {
    output.classList.add("error");
    runState.textContent = event.error
      ? "Failed"
      : event.exitCode === null
        ? "Stopped"
        : `Exited ${event.exitCode}`;
    if (event.error) {
      outputText += `\n${event.error}`;
      renderOutput(false);
    }
  } else {
    runState.textContent = "Done";
    if (currentRunMode === "ai") {
      renderOutput(true);
      void showWeather();
    }
  }
});
window.cantrip.onShortcutStatus(applyShortcutStatus);
window.cantrip.onUpdateState(renderUpdateState);
window.cantrip.onPluginsChanged((nextPlugins) => {
  plugins = nextPlugins;
  renderPlugins();
});
window.cantrip.onBackendHealth(applyBackendHealth);
window.cantrip.onOpenBackends(() => {
  toggleSettings(true);
  settingsBackendsSection.scrollIntoView({ behavior: "smooth", block: "start" });
});
window.cantrip.onPluginPrompt((prompt) => {
  toggleSettings(false);
  queryInput.value = prompt;
  void updateQuery().then(() => submit(true));
});
output.addEventListener("click", (event) => {
  const link = (event.target as Element).closest<HTMLAnchorElement>("a[href]");
  if (!link) return;
  event.preventDefault();
  void window.cantrip.openExternal(link.href);
});

async function initialize(): Promise<void> {
  const [statuses, currentShortcut, health] = await Promise.all([
    window.cantrip.getBackendStatus(),
    window.cantrip.getShortcutStatus(),
    window.cantrip.getBackendHealth(),
  ]);
  applyShortcutStatus(currentShortcut);
  backendHealth = health;
  applyBackendStatuses(statuses);
  renderBackendHealth();

  setAllowActions(localStorage.getItem("allowActions") === "true");
  renderLocationSettings();
  const savedOpacity = Number(localStorage.getItem("panelOpacity") ?? "100");
  const opacity = Number.isFinite(savedOpacity)
    ? Math.min(100, Math.max(85, savedOpacity))
    : 100;
  settingsOpacity.value = String(opacity);
  settingsOpacityValue.value = `${opacity}%`;
  window.cantrip.setWindowOpacity(opacity / 100);
  settingsLaunchAtLogin.checked = await window.cantrip.getLaunchAtLogin();
  renderUpdateState(await window.cantrip.getUpdateState());
  plugins = await window.cantrip.listPlugins();
  renderPlugins();
  const defaultWorkdir = await window.cantrip.getDefaultWorkdir();
  workdir = localStorage.getItem("workdir") || defaultWorkdir;
  workdirLabel.textContent = workdir.split(/[\\/]/).filter(Boolean).at(-1) ?? workdir;
  workdirButton.title = workdir;
  settingsBackend.value = backendSelect.value;
  renderBackendSettings();
  renderSuggestions();
  queryInput.focus();
}

void initialize();
