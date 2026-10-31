// The preload's `cantripGateway` object (see src/preload/gateway.ts).
export interface HostStatus {
  connected: boolean;
  /** "Direct, encrypted (192.168.0.10:55331)" or "HTTPS (host)". */
  route: string;
  message: string;
  server: string;
}

export type GatewayCommand =
  | "chat" | "tasks" | "artifacts" | "background" | "newTab" | "newMessage" | "refresh" | "voiceMode"
  | "togglePause" | "modelSettings" | "startFresh" | "usage" | "memory" | "builds" | "mascot" | "toggleTerminal";

interface Bridge {
  key: string;
  version: string;
  platform: string;
  server: string;
  focused: boolean;
  status: HostStatus;
  openSettings(): void;
  openExternal(url: string): void;
  showLog(): void;
  onStatus(callback: (status: HostStatus) => void): void;
  onCommand(callback: (command: GatewayCommand) => void): void;
  onActive(callback: (active: boolean) => void): void;
}

declare global {
  interface Window { cantripGateway?: Bridge }
}

const fallback: Bridge = {
  key: "", version: "dev", platform: "browser", server: "", focused: true,
  status: { connected: false, route: "", message: "", server: "" },
  openSettings() {}, openExternal(url) { window.open(url, "_blank", "noopener"); }, showLog() {},
  onStatus() {}, onCommand() {}, onActive() {},
};

export const bridge: Bridge = window.cantripGateway ?? fallback;
export const isWindows = bridge.platform === "win32";
/** Ctrl on Windows, ⌘ on macOS (development builds). */
export const primaryKeyLabel = bridge.platform === "darwin" ? "⌘" : "Ctrl+";
export function shortcut(keys: string): string {
  return bridge.platform === "darwin" ? keys.replace(/Ctrl\+/g, "⌘").replace(/Shift\+/g, "⇧") : keys;
}
