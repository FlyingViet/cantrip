// The local Connection settings page's only access to the app.
import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("gateway", {
  state: () => ipcRenderer.invoke("gateway:state"),
  parseLink: (link: string) => ipcRenderer.invoke("gateway:parse-link", link),
  test: (form: unknown) => ipcRenderer.invoke("gateway:test", form),
  save: (form: unknown) => ipcRenderer.invoke("gateway:save", form),
  forget: () => ipcRenderer.invoke("gateway:forget"),
  openLog: () => ipcRenderer.invoke("gateway:open-log"),
  onStatus: (callback: (status: unknown) => void) => {
    ipcRenderer.on("gateway:status", (_event, status) => callback(status));
  },
  onLink: (callback: (link: string) => void) => {
    ipcRenderer.on("gateway:link", (_event, link) => callback(link));
  },
});
