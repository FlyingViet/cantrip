import {
  app, BrowserWindow, Menu, MenuItemConstructorOptions, ipcMain, IpcMainEvent, IpcMainInvokeEvent,
  nativeTheme, net, protocol, safeStorage, session, shell,
} from "electron";
import { appendFileSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { PairingError, ServerConfig, displayName, parsePairingLink, validateServer, validateToken } from "./pairing";
import { HostRouter, Route, describeRoute, routesFor } from "./router";
import { Pairing, SettingsStore } from "./store";
import { HostRequest, HostResponse, forwardedHeaders, sendOverHTTPS, sendOverPSK } from "./transport";

const HOST_SCHEME = "cantrip-host";
const HOST_ORIGIN = `${HOST_SCHEME}://mac/`;
// In memory: the page keeps the pairing token in localStorage, which a persist: partition
// would write to disk unencrypted. The DPAPI-encrypted settings file is the only copy.
const HOST_PARTITION = "cantrip-host";
const LINK_SCHEME = "cantripagent";
const APP_ID = "com.itzhoang.cantripgateway.windows";
const REPOSITORY = "https://github.com/FlyingViet/CantripGatewayMac";

protocol.registerSchemesAsPrivileged([{
  scheme: HOST_SCHEME,
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true },
}]);

// End-to-end tests run against a throwaway profile.
if (process.env.CANTRIP_GATEWAY_USER_DATA) app.setPath("userData", process.env.CANTRIP_GATEWAY_USER_DATA);

let store: SettingsStore;
let pairing: Pairing | null = null;
let router: HostRouter | null = null;
let mainWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let pendingLink: string | null = null;
let pendingNotice: string | null = null;
let status = { connected: false, route: "", message: "" };

// MARK: - Log (content-free: routes and errors, never tokens or messages)

function logFile(): string {
  return join(app.getPath("userData"), "logs", "gateway.log");
}

function log(line: string): void {
  try {
    const file = logFile();
    mkdirSync(join(app.getPath("userData"), "logs"), { recursive: true });
    try {
      if (statSync(file).size > 1_000_000) renameSync(file, `${file}.1`);
    } catch { /* first write */ }
    appendFileSync(file, `[${new Date().toISOString()}] ${line}\n`);
  } catch { /* logging must never break the app */ }
}

// MARK: - Host bridge

function sendRoute(route: Route, request: HostRequest): Promise<HostResponse> {
  if (!pairing) throw new Error("Not paired.");
  return route.kind === "direct"
    ? sendOverPSK(route, pairing.token, request)
    : sendOverHTTPS(route.origin, request, net.fetch.bind(net));
}

function configureRouter(): void {
  router = pairing
    ? new HostRouter(routesFor(pairing.server), sendRoute, (route) => {
      log(`route: ${describeRoute(route)}`);
      updateStatus({ route: describeRoute(route) });
    })
    : null;
  status = { connected: false, route: router ? describeRoute(router.current) : "", message: "" };
}

function updateStatus(change: Partial<typeof status>): void {
  const before = JSON.stringify(status);
  status = { ...status, ...change };
  if (JSON.stringify(status) === before) return;
  if (mainWindow && pairing) {
    const state = status.connected ? status.route : `Can't reach the Mac`;
    mainWindow.setTitle(`Cantrip Gateway · ${displayName(pairing.server)} · ${state}`);
  }
  settingsWindow?.webContents.send("gateway:status", status);
}

function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function offlinePage(message: string): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Can't reach your Mac</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>:root{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#1c1c1e;color:#f2f2f7;font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:520px;padding:32px}h1{font-size:22px;margin:0 0 8px}p{color:#c7c7cc}.actions{display:flex;gap:10px;margin-top:20px}
button{min-height:44px;padding:0 18px;border-radius:10px;border:1px solid #48484a;background:#2c2c2e;color:#f2f2f7;font:inherit;cursor:pointer}
button.primary{background:#0a84ff;border-color:#0a84ff;color:#fff}button:focus-visible{outline:2px solid #64d2ff;outline-offset:2px}</style></head>
<body><main><h1>Can't reach your Mac</h1><p role="alert">${escapeHTML(message)}</p>
<p>Make sure Cantrip is running on the Mac and this PC is on the same network or on Tailscale.</p>
<div class="actions"><button class="primary" id="retry" autofocus>Try again</button><button id="settings">Connection settings</button></div></main>
<script>document.getElementById("retry").onclick=()=>location.reload();document.getElementById("settings").onclick=()=>window.cantripGateway&&window.cantripGateway.openSettings();</script>
</body></html>`;
  return new Response(html, { status: 502, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

async function handleHostRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  const isDocument = url.pathname === "/" && (request.headers.get("accept") ?? "").includes("text/html");
  if (url.host !== "mac") return new Response("Not found", { status: 404 });
  if (!router) return offlinePage("This PC isn't paired with a Mac yet.");
  const hostRequest: HostRequest = {
    method: request.method,
    path: url.pathname + url.search,
    headers: forwardedHeaders(request.headers),
    body: request.method === "GET" || request.method === "HEAD" ? undefined : Buffer.from(await request.arrayBuffer()),
  };
  try {
    const response = await router.request(hostRequest);
    if (!status.connected) log(`connected: ${describeRoute(router.current)}`);
    updateStatus({ connected: true, route: describeRoute(router.current), message: "" });
    const empty = request.method === "HEAD" || [204, 304].includes(response.status);
    return new Response(empty ? null : new Uint8Array(response.body), { status: response.status, headers: response.headers });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (status.connected || status.message !== message) log(`unreachable: ${message}`);
    updateStatus({ connected: false, message });
    if (isDocument) return offlinePage(message);
    return new Response(JSON.stringify({ error: `Can't reach your Mac. ${message}` }), {
      status: 502, headers: { "content-type": "application/json" },
    });
  }
}

// MARK: - Windows

function windowStateFile(): string {
  return join(app.getPath("userData"), "window.json");
}

function savedBounds(): Electron.Rectangle | undefined {
  try {
    const bounds = JSON.parse(readFileSync(windowStateFile(), "utf8"));
    if ([bounds.x, bounds.y, bounds.width, bounds.height].every(Number.isFinite)) return bounds;
  } catch { /* first launch */ }
  return undefined;
}

function isHostURL(url: string): boolean {
  return url.startsWith(HOST_ORIGIN);
}

function openExternally(url: string): void {
  if (/^https?:\/\//i.test(url)) void shell.openExternal(url);
}

function createMainWindow(): void {
  if (mainWindow) {
    void mainWindow.loadURL(HOST_ORIGIN);
    mainWindow.show();
    return;
  }
  const bounds = savedBounds();
  const window = new BrowserWindow({
    width: bounds?.width ?? 1200,
    height: bounds?.height ?? 820,
    x: bounds?.x,
    y: bounds?.y,
    minWidth: 640,
    minHeight: 480,
    title: "Cantrip Gateway",
    backgroundColor: "#1c1c1e",
    show: false,
    webPreferences: {
      partition: HOST_PARTITION,
      preload: join(__dirname, "../preload/remote.js"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: true,
    },
  });
  mainWindow = window;
  window.on("page-title-updated", (event) => event.preventDefault());
  window.once("ready-to-show", () => window.show());
  window.on("close", () => {
    try { writeFileSync(windowStateFile(), JSON.stringify(window.getNormalBounds())); } catch { /* best effort */ }
  });
  window.on("closed", () => { if (mainWindow === window) mainWindow = null; });
  window.webContents.setWindowOpenHandler(({ url }) => {
    openExternally(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    if (isHostURL(url)) return;
    event.preventDefault();
    openExternally(url);
  });
  updateStatus({});
  if (pairing) window.setTitle(`Cantrip Gateway · ${displayName(pairing.server)}`);
  void window.loadURL(HOST_ORIGIN);
}

function openSettings(link?: string): void {
  if (link) pendingLink = link;
  if (settingsWindow) {
    settingsWindow.webContents.send("gateway:link", pendingLink);
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  const window = new BrowserWindow({
    width: 600,
    height: 760,
    minWidth: 420,
    minHeight: 480,
    title: "Connection · Cantrip Gateway",
    backgroundColor: "#1c1c1e",
    parent: mainWindow ?? undefined,
    modal: Boolean(mainWindow),
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, "../preload/settings.js"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  settingsWindow = window;
  window.once("ready-to-show", () => window.show());
  window.on("closed", () => {
    settingsWindow = null;
    if (!pairing && !mainWindow) app.quit();
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    openExternally(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  void window.loadFile(join(__dirname, "../renderer/settings.html"));
}

// MARK: - IPC

const settingsPage = () => pathToFileURL(join(__dirname, "../renderer/settings.html")).toString();

function fromSettings(event: IpcMainInvokeEvent): void {
  if (!settingsWindow || event.sender !== settingsWindow.webContents || event.senderFrame?.url !== settingsPage()) {
    throw new Error("Not allowed.");
  }
}

interface RouteCheck { route: string; ok: boolean; message: string; milliseconds: number }

async function checkRoutes(server: ServerConfig, token: string): Promise<RouteCheck[]> {
  const checks: RouteCheck[] = [];
  for (const route of routesFor(server)) {
    const started = Date.now();
    const request: HostRequest = { method: "GET", path: "/api/v1/sessions", headers: { authorization: `Bearer ${token}`, accept: "application/json" } };
    try {
      const response = route.kind === "direct"
        ? await sendOverPSK(route, token, request)
        : await sendOverHTTPS(route.origin, request, net.fetch.bind(net), 10000);
      const ok = response.status === 200;
      checks.push({
        route: describeRoute(route), ok, milliseconds: Date.now() - started,
        message: ok ? "Connected" : response.status === 401 ? "The Mac rejected the pairing token." : `The Mac answered with HTTP ${response.status}.`,
      });
    } catch (error) {
      checks.push({ route: describeRoute(route), ok: false, message: (error as Error).message, milliseconds: Date.now() - started });
    }
  }
  return checks;
}

function readForm(input: unknown): { server: ServerConfig; token: string } {
  const form = (input ?? {}) as Partial<ServerConfig> & { token?: string };
  const server = validateServer({
    name: String(form.name ?? ""),
    url: String(form.url ?? ""),
    directAddress: String(form.directAddress ?? ""),
    tailscaleOnly: Boolean(form.tailscaleOnly),
  });
  const typed = String(form.token ?? "").trim();
  // An empty token field keeps the saved one.
  const token = typed ? validateToken(typed) : pairing ? pairing.token : validateToken("");
  return { server, token };
}

function userError(error: unknown): { error: string } {
  return { error: error instanceof PairingError || error instanceof Error ? error.message : String(error) };
}

function registerIPC(): void {
  ipcMain.on("gateway:remote-token", (event: IpcMainEvent) => {
    const allowed = mainWindow && event.sender === mainWindow.webContents && isHostURL(event.senderFrame?.url ?? "");
    event.returnValue = allowed && pairing ? pairing.token : "";
  });
  ipcMain.on("gateway:open-settings", (event: IpcMainEvent) => {
    if (mainWindow && event.sender === mainWindow.webContents) openSettings();
  });
  ipcMain.handle("gateway:state", (event) => {
    fromSettings(event);
    const link = pendingLink;
    const notice = pendingNotice;
    pendingLink = null;
    pendingNotice = null;
    return {
      notice,
      server: pairing?.server ?? null,
      tokenSuffix: pairing ? pairing.token.slice(-4) : "",
      status,
      link,
      logFile: logFile(),
    };
  });
  ipcMain.handle("gateway:parse-link", (event, link: unknown) => {
    fromSettings(event);
    try {
      const parsed = parsePairingLink(String(link ?? ""));
      return { server: { name: parsed.name, url: parsed.url, directAddress: parsed.directAddress, tailscaleOnly: parsed.tailscaleOnly }, token: parsed.token };
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:test", async (event, form: unknown) => {
    fromSettings(event);
    try {
      const { server, token } = readForm(form);
      return { checks: await checkRoutes(server, token) };
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:save", async (event, form: unknown) => {
    fromSettings(event);
    try {
      const { server, token } = readForm(form);
      const checks = await checkRoutes(server, token);
      if (!checks.some((check) => check.ok)) return { checks, error: "Nothing was saved: none of the routes reached the Mac with this token." };
      pairing = store.save(server, token);
      log(`paired: ${checks.map((check) => `${check.route} ${check.ok ? "ok" : "failed"}`).join("; ")}`);
      configureRouter();
      createMainWindow();
      settingsWindow?.close();
      return { checks, saved: true };
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:forget", async (event) => {
    fromSettings(event);
    await forgetPairing("Connection settings");
    return { forgotten: true };
  });
  ipcMain.on("gateway:unpair", (event: IpcMainEvent) => {
    if (mainWindow && event.sender === mainWindow.webContents) void forgetPairing("the Mac's Unpair button");
  });
  ipcMain.handle("gateway:open-log", (event) => {
    fromSettings(event);
    shell.showItemInFolder(logFile());
  });
}

/** Removes the saved pairing and returns to Connection settings; the app stays open. */
async function forgetPairing(source: string): Promise<void> {
  store.clear();
  pairing = null;
  configureRouter();
  await session.fromPartition(HOST_PARTITION).clearStorageData();
  log(`forgot the pairing (${source})`);
  const old = mainWindow;
  mainWindow = null;
  // Settings opened from the paired app is a modal child, which Windows destroys with its owner
  // (and Electron can't detach), so swap it for a standalone one before closing the main window.
  if (settingsWindow?.getParentWindow()) {
    const modal = settingsWindow;
    settingsWindow = null;
    modal.removeAllListeners("closed");
    modal.destroy();
  }
  pendingNotice = "Forgot the Mac. Pair again to reconnect.";
  openSettings();
  old?.destroy();
}

// MARK: - App

function linkFrom(argv: string[]): string | undefined {
  return argv.find((value) => value.toLowerCase().startsWith(`${LINK_SCHEME}://`));
}

function buildMenu(): void {
  const template: MenuItemConstructorOptions[] = [
    {
      label: "&File",
      submenu: [
        { label: "Connection &Settings…", accelerator: "CmdOrCtrl+,", click: () => openSettings() },
        { label: "&Reload", accelerator: "F5", click: () => mainWindow?.webContents.reload() },
        { type: "separator" },
        { role: "quit", label: "E&xit" },
      ],
    },
    { role: "editMenu" },
    {
      label: "&View",
      submenu: [
        { role: "resetZoom", label: "Actual Size" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
        { role: "toggleDevTools" },
      ],
    },
    {
      label: "&Help",
      submenu: [
        { label: "Cantrip Gateway on GitHub", click: () => void shell.openExternal(`${REPOSITORY}/tree/main/windows`) },
        { label: "Show Log File", click: () => shell.showItemInFolder(logFile()) },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", (_event, argv) => {
    const link = linkFrom(argv);
    if (link) openSettings(link);
    else if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    } else openSettings();
  });
  app.on("open-url", (event, url) => {
    event.preventDefault();
    if (app.isReady()) openSettings(url);
    else pendingLink = url;
  });

  app.whenReady().then(() => {
    app.setAppUserModelId(APP_ID);
    if (app.isPackaged) app.setAsDefaultProtocolClient(LINK_SCHEME);
    nativeTheme.themeSource = "dark";
    store = new SettingsStore(join(app.getPath("userData"), "settings.json"), safeStorage);
    pairing = store.load();
    configureRouter();
    log(`start ${app.getVersion()} on ${process.platform}-${process.arch}; ${pairing ? `paired, routes: ${routesFor(pairing.server).map(describeRoute).join(", ")}` : "not paired"}`);

    const hostSession = session.fromPartition(HOST_PARTITION);
    hostSession.protocol.handle(HOST_SCHEME, handleHostRequest);
    hostSession.setPermissionRequestHandler((_contents, permission, callback) => {
      callback(["notifications", "clipboard-sanitized-write", "fullscreen"].includes(permission));
    });
    registerIPC();
    buildMenu();

    const link = linkFrom(process.argv) ?? pendingLink ?? undefined;
    if (pairing) createMainWindow();
    if (!pairing || link) openSettings(link);
  });

  app.on("window-all-closed", () => app.quit());
}
