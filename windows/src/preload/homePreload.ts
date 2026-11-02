import { contextBridge, ipcRenderer } from "electron";
import type { CantripHomeApi, HomePairResult, HomeRead, HomeReadResult, HomeStatus } from "../shared/home";

const api: CantripHomeApi = {
  status: () => ipcRenderer.invoke("home:status") as Promise<HomeStatus>,
  pair: (link: string) => ipcRenderer.invoke("home:pair", link) as Promise<HomePairResult>,
  unpair: () => ipcRenderer.invoke("home:unpair") as Promise<HomeStatus>,
  read: (request: HomeRead) => ipcRenderer.invoke("home:read", request) as Promise<HomeReadResult>,
  openExternal: (url: string) => ipcRenderer.invoke("home:open-external", url) as Promise<boolean>,
};

contextBridge.exposeInMainWorld("cantripHome", api);
