import { contextBridge, ipcRenderer } from "electron";
import type {
  AppMatch,
  BackendStatus,
  CantripApi,
  RunChunkEvent,
  RunExitEvent,
  RunRequest,
  ScreenCapture,
  ShortcutStatus,
  UpdateState,
} from "../shared/types";
import type { PluginSummary } from "../shared/pluginTypes";

const api: CantripApi = {
  searchApps: (query: string) =>
    ipcRenderer.invoke("apps:search", query) as Promise<AppMatch[]>,
  launchApp: (id: string) =>
    ipcRenderer.invoke("apps:launch", id) as Promise<{ ok: boolean; error?: string }>,
  getBackendStatus: () =>
    ipcRenderer.invoke("backends:status") as Promise<BackendStatus[]>,
  getShortcutStatus: () =>
    ipcRenderer.invoke("shortcut:status") as Promise<ShortcutStatus>,
  retryShortcut: () =>
    ipcRenderer.invoke("shortcut:retry") as Promise<ShortcutStatus>,
  getDefaultWorkdir: () => ipcRenderer.invoke("workdir:default") as Promise<string>,
  chooseWorkdir: (current: string) =>
    ipcRenderer.invoke("workdir:choose", current) as Promise<string | null>,
  captureScreens: () =>
    ipcRenderer.invoke("screens:capture") as Promise<{
      ok: boolean;
      captures: ScreenCapture[];
      error?: string;
    }>,
  openExternal: (url: string) =>
    ipcRenderer.invoke("links:open-external", url) as Promise<boolean>,
  listPlugins: () =>
    ipcRenderer.invoke("plugins:list") as Promise<PluginSummary[]>,
  rescanPlugins: () =>
    ipcRenderer.invoke("plugins:rescan") as Promise<PluginSummary[]>,
  approvePlugin: (id: string) =>
    ipcRenderer.invoke("plugins:approve", id) as Promise<PluginSummary[]>,
  revokePlugin: (id: string) =>
    ipcRenderer.invoke("plugins:revoke", id) as Promise<PluginSummary[]>,
  setPluginEnabled: (id: string, enabled: boolean) =>
    ipcRenderer.invoke("plugins:set-enabled", id, enabled) as Promise<PluginSummary[]>,
  openPluginPanel: (id: string) =>
    ipcRenderer.invoke("plugins:open-panel", id) as Promise<{
      ok: boolean;
      error?: string;
    }>,
  openPluginsFolder: () =>
    ipcRenderer.invoke("plugins:open-folder") as Promise<boolean>,
  installExamplePlugin: () =>
    ipcRenderer.invoke("plugins:install-example") as Promise<PluginSummary[]>,
  startRun: (request: RunRequest) =>
    ipcRenderer.invoke("run:start", request) as Promise<{ ok: boolean; error?: string }>,
  cancelRun: (runId: string) =>
    ipcRenderer.invoke("run:cancel", runId) as Promise<boolean>,
  getLaunchAtLogin: () =>
    ipcRenderer.invoke("settings:launch-at-login:get") as Promise<boolean>,
  setLaunchAtLogin: (enabled: boolean) =>
    ipcRenderer.invoke("settings:launch-at-login:set", enabled) as Promise<{
      ok: boolean;
      error?: string;
    }>,
  getUpdateState: () =>
    ipcRenderer.invoke("updates:state") as Promise<UpdateState>,
  checkForUpdates: () =>
    ipcRenderer.invoke("updates:check") as Promise<UpdateState>,
  downloadUpdate: () =>
    ipcRenderer.invoke("updates:download") as Promise<UpdateState>,
  installUpdate: () =>
    ipcRenderer.invoke("updates:install") as Promise<{ ok: boolean; error?: string }>,
  setWindowOpacity: (opacity: number) =>
    ipcRenderer.send("settings:opacity", opacity),
  setExpanded: (expanded: boolean) => ipcRenderer.send("window:set-expanded", expanded),
  hide: () => ipcRenderer.send("launcher:hide"),
  onRunChunk: (callback: (event: RunChunkEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: RunChunkEvent) =>
      callback(payload);
    ipcRenderer.on("run:chunk", listener);
    return () => ipcRenderer.removeListener("run:chunk", listener);
  },
  onRunExit: (callback: (event: RunExitEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: RunExitEvent) =>
      callback(payload);
    ipcRenderer.on("run:exit", listener);
    return () => ipcRenderer.removeListener("run:exit", listener);
  },
  onShortcutStatus: (callback: (status: ShortcutStatus) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: ShortcutStatus) =>
      callback(payload);
    ipcRenderer.on("shortcut:status", listener);
    return () => ipcRenderer.removeListener("shortcut:status", listener);
  },
  onUpdateState: (callback: (state: UpdateState) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: UpdateState) =>
      callback(payload);
    ipcRenderer.on("updates:state", listener);
    return () => ipcRenderer.removeListener("updates:state", listener);
  },
  onPluginsChanged: (callback: (plugins: PluginSummary[]) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: PluginSummary[]) =>
      callback(payload);
    ipcRenderer.on("plugins:changed", listener);
    return () => ipcRenderer.removeListener("plugins:changed", listener);
  },
  onPluginPrompt: (callback: (prompt: string) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, prompt: string) =>
      callback(prompt);
    ipcRenderer.on("plugin:prompt", listener);
    return () => ipcRenderer.removeListener("plugin:prompt", listener);
  },
};

contextBridge.exposeInMainWorld("cantrip", api);
