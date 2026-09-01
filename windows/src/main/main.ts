import path from "node:path";
import { appendFile } from "node:fs/promises";
import {
  app,
  BrowserWindow,
  desktopCapturer,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  nativeImage,
  protocol,
  screen,
  shell,
  Tray,
} from "electron";
import type { OpenDialogOptions } from "electron";
import { AppCatalog } from "./appCatalog";
import { RunManager } from "./backends";
import { UpdateManager } from "./updateManager";
import { PluginRegistry } from "./plugins";
import type { RunRequest, ShortcutStatus, UpdateState } from "../shared/types";

const appCatalog = new AppCatalog();
const runManager = new RunManager();
let launcher: BrowserWindow | null = null;
let tray: Tray | null = null;
let updateManager: UpdateManager | null = null;
let pluginRegistry: PluginRegistry | null = null;
let shortcutStatus: ShortcutStatus = {
  accelerator: null,
  displayName: "Unavailable",
  isFallback: false,
  message: "Cantrip could not register a global shortcut.",
};
let quitting = false;

protocol.registerSchemesAsPrivileged([
  {
    scheme: "cantrip-plugin",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      stream: true,
    },
  },
]);

function launcherPosition(window: BrowserWindow): { x: number; y: number } {
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const [width] = window.getSize();
  return {
    x: Math.round(display.workArea.x + (display.workArea.width - width) / 2),
    y: Math.round(display.workArea.y + display.workArea.height * 0.16),
  };
}

function showLauncher(): void {
  if (!launcher) return;
  launcher.setPosition(...Object.values(launcherPosition(launcher)) as [number, number]);
  launcher.show();
  launcher.focus();
  launcher.webContents.send("shortcut:status", shortcutStatus);
}

function toggleLauncher(): void {
  if (!launcher) return;
  if (launcher.isVisible()) launcher.hide();
  else showLauncher();
}

function createLauncher(): void {
  launcher = new BrowserWindow({
    width: 720,
    height: 350,
    minWidth: 600,
    minHeight: 240,
    show: false,
    frame: false,
    transparent: false,
    backgroundColor: "#181819",
    roundedCorners: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: true,
    webPreferences: {
      preload: path.join(__dirname, "..", "preload", "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  launcher.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  launcher.on("blur", () => {
    if (!launcher?.webContents.isDevToolsOpened()) launcher?.hide();
  });
  launcher.on("close", (event) => {
    if (!quitting) {
      event.preventDefault();
      launcher?.hide();
    }
  });

  const rendererPath = path.join(__dirname, "..", "..", "dist", "renderer", "index.html");
  void launcher.loadFile(rendererPath);
}

function createTray(): void {
  const svg = [
    '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">',
    '<rect width="32" height="32" rx="8" fill="#171421"/>',
    '<path d="M16 3l2.5 9.5L28 16l-9.5 3.5L16 29l-2.5-9.5L4 16l9.5-3.5z" fill="#b69cff"/>',
    "</svg>",
  ].join("");
  const icon = nativeImage
    .createFromDataURL(`data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`)
    .resize({ width: 16, height: 16 });
  tray = new Tray(icon);
  tray.setToolTip("Cantrip");
  updateTrayMenu();
  tray.on("click", toggleLauncher);
}

function updateTrayMenu(): void {
  if (!tray) return;
  const shortcutItems: Electron.MenuItemConstructorOptions[] = shortcutStatus.isFallback
    ? [
        {
          label: "Alt+Space is in use by another app",
          enabled: false,
        },
        {
          label: "Retry Alt+Space",
          click: registerShortcut,
        },
        { type: "separator" },
      ]
    : [];
  const updateState = updateManager?.getState();
  const updateItems: Electron.MenuItemConstructorOptions[] = [];
  if (updateState?.status === "available") {
    updateItems.push({
      label: `Download Cantrip ${updateState.availableVersion ?? "update"}`,
      click: () => void updateManager?.download(),
    });
  } else if (updateState?.status === "downloaded") {
    updateItems.push({
      label: `Restart to install ${updateState.availableVersion ?? "update"}`,
      click: () => updateManager?.install(),
    });
  } else if (updateState?.status === "downloading") {
    updateItems.push({
      label: `Downloading update ${Math.round(updateState.percent ?? 0)}%`,
      enabled: false,
    });
  } else {
    updateItems.push({
      label: updateState?.status === "checking" ? "Checking for updates…" : "Check for updates",
      enabled: updateState?.status !== "checking",
      click: () => void updateManager?.check(),
    });
  }
  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: `Show Cantrip (${shortcutStatus.displayName})`,
        click: showLauncher,
      },
      ...shortcutItems,
      { label: "Refresh apps", click: () => void appCatalog.refresh() },
      ...updateItems,
      { type: "separator" },
      {
        label: "Quit",
        click: () => {
          quitting = true;
          app.quit();
        },
      },
    ]),
  );
}

function handleUpdateState(state: UpdateState): void {
  launcher?.webContents.send("updates:state", state);
  updateTrayMenu();
}

async function runPluginAction(name: string): Promise<unknown> {
  switch (name) {
    case "update":
      return updateManager?.check();
    case "relaunch":
      setImmediate(() => {
        app.relaunch();
        app.exit(0);
      });
      return { ok: true };
    case "openRepo":
      await shell.openExternal("https://github.com/FlyingViet/cantrip");
      return { ok: true };
    case "openLog": {
      const logPath = path.join(app.getPath("userData"), "Cantrip.log");
      await appendFile(logPath, "", "utf8");
      const error = await shell.openPath(logPath);
      if (error) throw new Error(error);
      return { ok: true };
    }
    case "build":
      throw new Error("Build is only available from a source checkout.");
    default:
      throw new Error("Unknown Cantrip action.");
  }
}

function registerShortcut(): void {
  globalShortcut.unregister("Alt+Space");
  globalShortcut.unregister("CommandOrControl+Space");

  if (globalShortcut.register("Alt+Space", toggleLauncher)) {
    shortcutStatus = {
      accelerator: "Alt+Space",
      displayName: "Alt Space",
      isFallback: false,
    };
  } else if (globalShortcut.register("CommandOrControl+Space", toggleLauncher)) {
    shortcutStatus = {
      accelerator: "CommandOrControl+Space",
      displayName: "Ctrl Space",
      isFallback: true,
      message:
        "Alt+Space is already owned by another app. PowerToys Run commonly uses it; disable or change that shortcut, then retry.",
    };
  } else {
    shortcutStatus = {
      accelerator: null,
      displayName: "Unavailable",
      isFallback: false,
      message: "Both Alt+Space and Ctrl+Space are already owned by other apps.",
    };
  }

  updateTrayMenu();
  launcher?.webContents.send("shortcut:status", shortcutStatus);
}

function registerIpc(): void {
  ipcMain.handle("apps:search", (_event, query: unknown) => {
    if (typeof query !== "string" || query.length > 200) return [];
    return appCatalog.search(query);
  });
  ipcMain.handle("apps:launch", (_event, id: unknown) => {
    if (typeof id !== "string") return { ok: false, error: "Invalid app." };
    return appCatalog.launch(id);
  });
  ipcMain.handle("backends:status", () => runManager.statuses());
  ipcMain.handle("shortcut:status", () => shortcutStatus);
  ipcMain.handle("shortcut:retry", () => {
    registerShortcut();
    return shortcutStatus;
  });
  ipcMain.handle("workdir:default", () => app.getPath("documents"));
  ipcMain.handle("links:open-external", async (_event, value: unknown) => {
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
  ipcMain.handle("screens:capture", async () => {
    try {
      const sources = await desktopCapturer.getSources({
        types: ["screen"],
        thumbnailSize: { width: 1920, height: 1080 },
        fetchWindowIcons: false,
      });
      const captures = sources
        .filter((source) => !source.thumbnail.isEmpty())
        .map((source) => {
          const size = source.thumbnail.getSize();
          return {
            id: source.id,
            name: source.name,
            dataUrl: source.thumbnail.toDataURL(),
            width: size.width,
            height: size.height,
          };
        });
      return captures.length
        ? { ok: true, captures }
        : { ok: false, captures: [], error: "No displays were available to capture." };
    } catch (error) {
      return {
        ok: false,
        captures: [],
        error: error instanceof Error ? error.message : String(error),
      };
    }
  });
  ipcMain.handle("workdir:choose", async (_event, current: unknown) => {
    const options: OpenDialogOptions = {
      title: "Choose Cantrip working directory",
      defaultPath: typeof current === "string" ? current : app.getPath("documents"),
      properties: ["openDirectory"],
    };
    const result = launcher
      ? await dialog.showOpenDialog(launcher, options)
      : await dialog.showOpenDialog(options);
    return result.canceled ? null : (result.filePaths[0] ?? null);
  });
  ipcMain.handle("run:start", async (_event, request: unknown) => {
    if (!request || typeof request !== "object") return { ok: false, error: "Invalid run." };
    return runManager.start(
      request as RunRequest,
      (chunk) => launcher?.webContents.send("run:chunk", chunk),
      (exit) => launcher?.webContents.send("run:exit", exit),
    );
  });
  ipcMain.handle("run:cancel", (_event, runId: unknown) =>
    typeof runId === "string" ? runManager.cancel(runId) : false,
  );
  ipcMain.handle("settings:launch-at-login:get", () =>
    app.getLoginItemSettings().openAtLogin,
  );
  ipcMain.handle("settings:launch-at-login:set", (_event, enabled: unknown) => {
    if (typeof enabled !== "boolean") {
      return { ok: false, error: "Invalid launch-at-login setting." };
    }
    if (!app.isPackaged) {
      return { ok: false, error: "Launch at login is available in installed builds." };
    }
    try {
      app.setLoginItemSettings({ openAtLogin: enabled, path: process.execPath });
      return { ok: true };
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  });
  ipcMain.on("settings:opacity", (_event, opacity: unknown) => {
    if (!launcher || typeof opacity !== "number" || !Number.isFinite(opacity)) return;
    launcher.setOpacity(Math.min(1, Math.max(0.85, opacity)));
  });
  ipcMain.handle("updates:state", () => updateManager?.getState());
  ipcMain.handle("updates:check", () => updateManager?.check());
  ipcMain.handle("updates:download", () => updateManager?.download());
  ipcMain.handle("updates:install", () =>
    updateManager?.install() ?? { ok: false, error: "Updater is not ready." },
  );
  ipcMain.on("window:set-expanded", (_event, expanded: unknown) => {
    if (!launcher || typeof expanded !== "boolean") return;
    const [width] = launcher.getSize();
    launcher.setSize(width, expanded ? 560 : 350, true);
  });
  ipcMain.on("launcher:hide", () => launcher?.hide());
}

const instanceLock = app.requestSingleInstanceLock();
if (!instanceLock) {
  app.quit();
} else {
  app.on("second-instance", showLauncher);
  app.whenReady().then(async () => {
    app.setAppUserModelId("dev.flyingviet.cantrip.windows");
    await runManager.cleanupStaleAttachments();
    createLauncher();
    registerShortcut();
    updateManager = new UpdateManager(handleUpdateState);
    createTray();
    registerIpc();
    updateManager.initialize();
    const pluginRoot =
      process.env.CANTRIP_PLUGIN_DIR ??
      path.join(app.getPath("appData"), "cantrip", "plugins");
    pluginRegistry = new PluginRegistry({
      root: pluginRoot,
      statePath: path.join(app.getPath("userData"), "plugin-state.json"),
      mcpConfigPath: path.join(path.dirname(pluginRoot), "plugin-mcp.json"),
      logPath: path.join(app.getPath("userData"), "Cantrip.log"),
      panelPreloadPath: path.join(__dirname, "..", "preload", "pluginBridge.js"),
      examplePluginPath: app.isPackaged
        ? path.join(process.resourcesPath, "examples", "hello-dashboard")
        : path.join(app.getAppPath(), "..", "Examples", "plugins", "hello-dashboard"),
      onChanged: (plugins) => launcher?.webContents.send("plugins:changed", plugins),
      onPrompt: (prompt) => {
        showLauncher();
        launcher?.webContents.send("plugin:prompt", prompt);
      },
      getCantripStatus: async () => ({
        version: app.getVersion(),
        backends: await runManager.statuses(),
        update: updateManager?.getState(),
      }),
      runAction: runPluginAction,
    });
    await pluginRegistry.initialize();
    runManager.setMcpProvider(() => pluginRegistry?.mcpSnapshot() ?? null);
    await appCatalog.refresh();
  });
}

app.on("will-quit", () => {
  quitting = true;
  runManager.cancelAll();
  pluginRegistry?.dispose();
  globalShortcut.unregisterAll();
});

app.on("window-all-closed", () => {
  // The tray application intentionally stays running.
});
