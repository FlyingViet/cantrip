// The Settings window's only access to the app (saved Macs, pairing links, the log).
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("gatewaySettings", {
  state: () => ipcRenderer.invoke("gateway:state"),
  parseLink: (link: string) => ipcRenderer.invoke("gateway:parse-link", link),
  test: (form: unknown) => ipcRenderer.invoke("gateway:test", form),
  add: (form: unknown) => ipcRenderer.invoke("gateway:add", form),
  select: (id: string) => ipcRenderer.invoke("gateway:select", id),
  remove: (id: string) => ipcRenderer.invoke("gateway:remove", id),
  openLog: () => ipcRenderer.invoke("gateway:open-log"),
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
