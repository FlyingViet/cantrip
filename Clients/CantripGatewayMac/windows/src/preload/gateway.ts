// The Gateway page's only access to the app (top frame only; MCP App frames get nothing).
import { contextBridge, ipcRenderer } from "electron";

interface Hello {
  key: string;
  version: string;
  platform: string;
  server: string;
  focused: boolean;
  status: { connected: boolean; route: string; message: string; server: string };
}

const hello = ipcRenderer.sendSync("gateway:hello") as Hello | null;

if (hello) {
  contextBridge.exposeInMainWorld("cantripGateway", {
    key: hello.key,
    version: hello.version,
    platform: hello.platform,
    server: hello.server,
    focused: hello.focused,
    status: hello.status,
    openSettings: () => ipcRenderer.send("gateway:open-settings"),
    openExternal: (url: string) => ipcRenderer.send("gateway:open-external", url),
    showLog: () => ipcRenderer.send("gateway:show-log"),
    onStatus: (callback: (status: Hello["status"]) => void) => {
      ipcRenderer.on("gateway:status", (_event, status) => callback(status));
    },
    onCommand: (callback: (command: string) => void) => {
      ipcRenderer.on("gateway:command", (_event, command) => callback(command));
    },
    onActive: (callback: (active: boolean) => void) => {
      ipcRenderer.on("gateway:active", (_event, active) => callback(Boolean(active)));
    },
  });
}
