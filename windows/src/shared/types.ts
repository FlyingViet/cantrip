import type { PluginSummary } from "./pluginTypes";

export type BackendId = "claude" | "copilot" | "codex" | "agy";
export type ReasoningEffort =
  | ""
  | "none"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "max";
export type ContextTier = "" | "default" | "long_context";

export interface AppMatch {
  id: string;
  name: string;
  path: string;
  kind: "shortcut" | "executable";
}

export interface BackendStatus {
  id: BackendId;
  label: string;
  available: boolean;
  detail: string;
}

/** Install, sign-in and quota of one backend's CLI on this PC (the Mac host's GET /api/v1/backends shape). */
export type BackendState = "ready" | "signedOut" | "outOfQuota" | "notInstalled" | "unknown";

export interface BackendQuota {
  name: string;
  usedPercent?: number;
  resetsAt?: string;
}

export interface BackendSignIn {
  /** `deviceCode`: a link and a code shown in Settings; `terminal`: finished in a terminal window. */
  mode: "deviceCode" | "terminal";
  command: string;
  hint: string;
  url?: string;
  code?: string;
  startedAt?: string;
  /** How the last sign-in attempt ended, or where it continues. */
  message?: string;
}

export interface BackendHealth {
  id: BackendId;
  name: string;
  state: BackendState;
  summary: string;
  path?: string;
  version?: string;
  /** Absent when the check couldn't tell. */
  signedIn?: boolean;
  account?: string;
  authMethod?: string;
  plan?: string;
  quota: BackendQuota[];
  /** When a used-up limit lifts. */
  limitedUntil?: string;
  lastSuccessAt?: string;
  lastAuthError?: { message: string; at: string };
  checkedAt?: string;
  checking: boolean;
  /** Routing skips it (signed out) and uses a backup. */
  unavailable: boolean;
  problem?: string;
  signIn: BackendSignIn;
}

export interface BackendsSnapshot {
  backends: BackendHealth[];
  /** Seconds between scheduled checks. */
  checkInterval: number;
  revision: number;
  /** What a signIn or cancelSignIn did. */
  message?: string;
}

export type BackendsAction =
  | { action: "check"; id?: BackendId }
  | { action: "signIn"; id: BackendId }
  | { action: "cancelSignIn"; id: BackendId };

export interface ShortcutStatus {
  accelerator: string | null;
  displayName: string;
  isFallback: boolean;
  message?: string;
}

export interface ScreenCapture {
  id: string;
  name: string;
  dataUrl: string;
  width: number;
  height: number;
}

export interface RunAttachment {
  name: string;
  dataUrl: string;
}

export interface RunRequest {
  runId: string;
  mode: "ai" | "shell";
  prompt: string;
  backend: BackendId;
  workdir: string;
  allowActions: boolean;
  model: string;
  effort: ReasoningEffort;
  contextTier: ContextTier;
  attachments: RunAttachment[];
}

export interface RunChunkEvent {
  runId: string;
  stream: "stdout" | "stderr";
  text: string;
}

export interface RunExitEvent {
  runId: string;
  exitCode: number | null;
  error?: string;
}

export type UpdateStatus =
  | "idle"
  | "checking"
  | "available"
  | "downloading"
  | "downloaded"
  | "up-to-date"
  | "error"
  | "unsupported";

export interface UpdateState {
  status: UpdateStatus;
  currentVersion: string;
  availableVersion?: string;
  percent?: number;
  message: string;
}

export interface CantripApi {
  searchApps(query: string): Promise<AppMatch[]>;
  launchApp(id: string): Promise<{ ok: boolean; error?: string }>;
  getBackendStatus(): Promise<BackendStatus[]>;
  getBackendHealth(): Promise<BackendsSnapshot>;
  backendAction(action: BackendsAction): Promise<BackendsSnapshot>;
  getShortcutStatus(): Promise<ShortcutStatus>;
  retryShortcut(): Promise<ShortcutStatus>;
  getDefaultWorkdir(): Promise<string>;
  chooseWorkdir(current: string): Promise<string | null>;
  captureScreens(): Promise<{ ok: boolean; captures: ScreenCapture[]; error?: string }>;
  openExternal(url: string): Promise<boolean>;
  listPlugins(): Promise<PluginSummary[]>;
  rescanPlugins(): Promise<PluginSummary[]>;
  approvePlugin(id: string): Promise<PluginSummary[]>;
  revokePlugin(id: string): Promise<PluginSummary[]>;
  setPluginEnabled(id: string, enabled: boolean): Promise<PluginSummary[]>;
  openPluginPanel(id: string): Promise<{ ok: boolean; error?: string }>;
  openPluginsFolder(): Promise<boolean>;
  installExamplePlugin(): Promise<PluginSummary[]>;
  startRun(request: RunRequest): Promise<{ ok: boolean; error?: string }>;
  cancelRun(runId: string): Promise<boolean>;
  getLaunchAtLogin(): Promise<boolean>;
  setLaunchAtLogin(enabled: boolean): Promise<{ ok: boolean; error?: string }>;
  getUpdateState(): Promise<UpdateState>;
  checkForUpdates(): Promise<UpdateState>;
  downloadUpdate(): Promise<UpdateState>;
  installUpdate(): Promise<{ ok: boolean; error?: string }>;
  setWindowOpacity(opacity: number): void;
  setExpanded(expanded: boolean): void;
  hide(): void;
  onRunChunk(callback: (event: RunChunkEvent) => void): () => void;
  onRunExit(callback: (event: RunExitEvent) => void): () => void;
  onShortcutStatus(callback: (status: ShortcutStatus) => void): () => void;
  onUpdateState(callback: (state: UpdateState) => void): () => void;
  onPluginsChanged(callback: (plugins: PluginSummary[]) => void): () => void;
  onPluginPrompt(callback: (prompt: string) => void): () => void;
  onBackendHealth(callback: (snapshot: BackendsSnapshot) => void): () => void;
  onOpenBackends(callback: () => void): () => void;
}
