// The Cantrip Home window: Home, Background and Tasks read from the paired Mac (read-only). Its
// IPC answers only the window's own top frame; the pairing token stays in this process.
import path from "node:path";
import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { BrowserWindow, app, ipcMain, net, safeStorage, shell } from "electron";
import type { IpcMainEvent, IpcMainInvokeEvent } from "electron";
import { HomeService } from "./home/service";
import { PairingStore } from "./home/store";
import { sendOverHTTPS, sendOverPSK } from "./home/transport";

let homeWindow: BrowserWindow | null = null;
let service: HomeService | null = null;

function rendererFile(): string {
  return path.join(__dirname, "..", "..", "dist", "renderer", "home.html");
}

function log(line: string): void {
  const file = path.join(app.getPath("userData"), "Cantrip.log");
  void appendFile(file, `[${new Date().toISOString()}] ${line}\n`, "utf8").catch(() => {});
}

function fromHomeWindow(event: IpcMainInvokeEvent | IpcMainEvent): void {
  const frame = event.senderFrame;
  if (
    !homeWindow ||
    event.sender !== homeWindow.webContents ||
    !frame ||
    frame.parent ||
    !frame.url.startsWith(pathToFileURL(rendererFile()).toString())
  ) {
    throw new Error("Not allowed.");
  }
}

export function openHomeWindow(): void {
  if (homeWindow) {
    if (homeWindow.isMinimized()) homeWindow.restore();
    homeWindow.show();
    homeWindow.focus();
    return;
  }
  homeWindow = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 520,
    minHeight: 420,
    show: false,
    title: "Cantrip Home",
    backgroundColor: "#181819",
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "..", "preload", "homePreload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webviewTag: false,
      // Its own in-memory session: nothing it loads is cached on disk, and no permission is granted.
      partition: "home-window",
    },
  });
  const contents = homeWindow.webContents;
  // Mac content never navigates this window or opens another one; links go to the browser.
  contents.setWindowOpenHandler(() => ({ action: "deny" }));
  contents.on("will-navigate", (event) => event.preventDefault());
  contents.on("will-attach-webview", (event) => event.preventDefault());
  contents.session.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  homeWindow.once("ready-to-show", () => homeWindow?.show());
  homeWindow.on("closed", () => {
    homeWindow = null;
  });
  void homeWindow.loadFile(rendererFile());
}

export function registerHomeIPC(isLauncher: (event: IpcMainEvent) => boolean): void {
  service = new HomeService(
    new PairingStore(path.join(app.getPath("userData"), "home-pairing.json"), safeStorage),
    (route, token, request) =>
      route.kind === "direct"
        ? sendOverPSK(route, token, request)
        : sendOverHTTPS(route.origin, request, net.fetch.bind(net)),
    log,
  );
  ipcMain.on("home:open", (event) => {
    if (isLauncher(event)) openHomeWindow();
  });
  ipcMain.handle("home:status", (event) => {
    fromHomeWindow(event);
    return service!.status();
  });
  ipcMain.handle("home:pair", (event, link: unknown) => {
    fromHomeWindow(event);
    return service!.pair(link);
  });
  ipcMain.handle("home:unpair", (event) => {
    fromHomeWindow(event);
    return service!.unpair();
  });
  ipcMain.handle("home:read", (event, request: unknown) => {
    fromHomeWindow(event);
    return service!.read(request);
  });
  ipcMain.handle("home:open-external", async (event, value: unknown) => {
    fromHomeWindow(event);
    if (typeof value !== "string" || value.length > 2_048) return false;
    try {
      const url = new URL(value);
      if (!["https:", "http:"].includes(url.protocol)) return false;
      await shell.openExternal(url.toString());
      return true;
    } catch {
      return false;
    }
  });
}
