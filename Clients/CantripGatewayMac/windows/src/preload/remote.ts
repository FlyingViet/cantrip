// Runs before the Mac's web client in the main window (top frame only; MCP App frames get nothing).
// The web client reads its pairing token from localStorage, like Mac Remote's injected script.
import { contextBridge, ipcRenderer } from "electron";

if (location.protocol === "cantrip-host:") {
  const token = ipcRenderer.sendSync("gateway:remote-token");
  if (typeof token === "string" && token) localStorage.setItem("cantripToken", token);
  contextBridge.exposeInMainWorld("cantripGateway", {
    platform: "windows",
    // The web client shows its left tab list, as in Mac Remote.
    sidebarLayout: true,
    openSettings: () => ipcRenderer.send("gateway:open-settings"),
    // The web client's Unpair button: forget the saved token too, not just the page's copy.
    unpair: () => ipcRenderer.send("gateway:unpair"),
  });
}
