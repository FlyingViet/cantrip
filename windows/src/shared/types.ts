import type { PluginSummary } from "./pluginTypes";

export type BackendId = "claude" | "copilot" | "codex";
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
}
