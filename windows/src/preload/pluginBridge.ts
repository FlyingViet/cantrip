import { contextBridge, ipcRenderer } from "electron";
import type { PluginBridgeApi } from "../shared/pluginTypes";

const tokenArgument = process.argv.find((argument) =>
  argument.startsWith("--cantrip-plugin-token="),
);
const bridgeToken = tokenArgument?.slice("--cantrip-plugin-token=".length) ?? "";

const bridge: PluginBridgeApi = {
  sendPrompt: (text: string) => {
    if (typeof text === "string" && text.trim() && text.length <= 32_000) {
      ipcRenderer.send("plugin:send-prompt", bridgeToken, text);
    }
  },
  log: (text: string) => {
    if (typeof text === "string") {
      ipcRenderer.send("plugin:log", bridgeToken, text.slice(0, 500));
    }
  },
  openURL: (url: string) => {
    if (typeof url === "string") {
      ipcRenderer.send("plugin:open-url", bridgeToken, url);
    }
  },
  requestData: (name: string, payload?: Record<string, unknown>) =>
    ipcRenderer.invoke("plugin:request-data", bridgeToken, name, payload) as Promise<
      Record<string, unknown>
    >,
  runAction: (name: string) =>
    ipcRenderer.invoke("plugin:run-action", bridgeToken, name),
};

contextBridge.exposeInMainWorld("cantrip", bridge);
