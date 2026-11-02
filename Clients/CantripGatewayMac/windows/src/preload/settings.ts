// The Settings window's only access to the app (saved Macs, pairing links, the log, and the Mac's
// shared MCP list and backend status through the main process, which holds the token).
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("gatewaySettings", {
  state: () => ipcRenderer.invoke("gateway:state"),
  parseLink: (link: string) => ipcRenderer.invoke("gateway:parse-link", link),
  test: (form: unknown) => ipcRenderer.invoke("gateway:test", form),
  add: (form: unknown) => ipcRenderer.invoke("gateway:add", form),
  select: (id: string) => ipcRenderer.invoke("gateway:select", id),
  remove: (id: string) => ipcRenderer.invoke("gateway:remove", id),
  openLog: () => ipcRenderer.invoke("gateway:open-log"),
  mcp: (request: unknown) => ipcRenderer.invoke("gateway:mcp", request),
  backends: (request: unknown) => ipcRenderer.invoke("gateway:backends", request),
  githubSignIn: () => ipcRenderer.invoke("gateway:github-sign-in"),
  openExternal: (url: string) => ipcRenderer.send("gateway:open-external", url),
  onStatus: (callback: (status: unknown) => void) => {
    ipcRenderer.on("gateway:status", (_event, status) => callback(status));
  },
  onServers: (callback: (state: unknown) => void) => {
    ipcRenderer.on("gateway:servers", (_event, state) => callback(state));
  },
  onLink: (callback: (link: string) => void) => {
    ipcRenderer.on("gateway:link", (_event, link) => callback(link));
  },
});
