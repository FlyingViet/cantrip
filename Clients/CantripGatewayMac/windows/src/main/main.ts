import {
  app, BrowserWindow, Menu, MenuItemConstructorOptions, ipcMain, IpcMainEvent, IpcMainInvokeEvent,
  nativeTheme, net, protocol, safeStorage, session, shell,
} from "electron";
import { randomBytes } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { PairingError, ServerConfig, displayName, parsePairingLink, validateServer, validateToken } from "./pairing";
import { HostRouter, Route, describeRoute, routesFor } from "./router";
import { Pairing, SettingsStore } from "./store";
import { HostRequest, HostResponse, forwardedHeaders, sendOverHTTPS, sendOverPSK } from "./transport";

const HOST_SCHEME = "cantrip-host";
const HOST_ORIGIN = `${HOST_SCHEME}://mac/`;
// Persistent for the page's preferences (mascot, drafts, collapsed groups). The page never sees the
// pairing token; the DPAPI-encrypted settings file is its only copy.
const HOST_PARTITION = "persist:cantrip-gateway";
const LINK_SCHEME = "cantripagent";
const APP_ID = "com.itzhoang.cantripgateway.windows";
const REPOSITORY = "https://github.com/FlyingViet/CantripGatewayMac";
/** The bundled Gateway interface (Preact), served from the same origin as the Mac's API. */
const GATEWAY_ROOT = resolve(__dirname, "../gateway");
/**
 * Per-launch secret the Gateway page sends with each API call; only those calls get the pairing
 * token. The page never sees the token, and MCP App frames (sandboxed, opaque origin) get nothing.
 */
const GATEWAY_KEY = randomBytes(32).toString("base64url");
const GATEWAY_CSP = [
  // wasm-unsafe-eval and the Hugging Face hosts: the on-device speech model (downloaded once, like
  // the Mac's Parakeet) runs as WebAssembly/WebGPU in a worker.
  "default-src 'self'", "script-src 'self' 'wasm-unsafe-eval'", "style-src 'self'", "img-src 'self' data: blob: https:",
  "media-src 'self' data: blob:", "connect-src 'self' https://huggingface.co https://*.huggingface.co https://*.hf.co",
  "frame-src 'self'", "worker-src 'self' blob:",
  "object-src 'none'", "base-uri 'none'", "form-action 'none'",
].join("; ");
const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".png": "image/png", ".svg": "image/svg+xml", ".json": "application/json", ".woff2": "font/woff2", ".map": "application/json",
};
const IS_WINDOWS = process.platform === "win32";
const TOOLBAR_HEIGHT = 52;
const WINDOW_BACKGROUND = "#1e1f21";

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
let status = { connected: false, route: "", message: "", server: "" };

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
  status = {
    connected: false, route: router ? describeRoute(router.current) : "", message: "",
    server: pairing ? displayName(pairing.server) : "",
  };
}

function updateStatus(change: Partial<typeof status>): void {
  const before = JSON.stringify(status);
  status = { ...status, ...change };
  if (JSON.stringify(status) === before) return;
  if (mainWindow && pairing) {
    const state = status.connected ? status.route : `Can't reach the Mac`;
    mainWindow.setTitle(`Cantrip Gateway · ${displayName(pairing.server)} · ${state}`);
  }
  mainWindow?.webContents.send("gateway:status", status);
  settingsWindow?.webContents.send("gateway:status", status);
}

function serveGatewayFile(pathname: string): Response {
  const relative = pathname === "/" ? "index.html" : decodeURIComponent(pathname).replace(/^\/+/, "");
  const file = resolve(GATEWAY_ROOT, relative);
  if (!file.startsWith(GATEWAY_ROOT + sep)) return new Response("Not found", { status: 404 });
  try {
    const body = readFileSync(file);
    const headers: Record<string, string> = {
      "content-type": CONTENT_TYPES[extname(file).toLowerCase()] ?? "application/octet-stream",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    };
    if (file.endsWith(".html")) headers["content-security-policy"] = GATEWAY_CSP;
    return new Response(new Uint8Array(body), { status: 200, headers });
  } catch {
    return new Response("Not found", { status: 404 });
  }
}

function jsonError(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), { status, headers: { "content-type": "application/json" } });
}

async function handleHostRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.host !== "mac") return new Response("Not found", { status: 404 });
  const isAPI = url.pathname.startsWith("/api/");
  // MCP App views load from single-use URLs the host mints; they never carry the token.
  if (!isAPI && !url.pathname.startsWith("/mcp-app/") && url.pathname !== "/health") return serveGatewayFile(url.pathname);
  if (!router || !pairing) return jsonError(503, "This PC isn't paired with a Mac yet.");
  const headers = forwardedHeaders(request.headers);
  delete headers.authorization;
  if (isAPI && request.headers.get("x-cantrip-gateway") === GATEWAY_KEY) headers.authorization = `Bearer ${pairing.token}`;
  const hostRequest: HostRequest = {
    method: request.method,
    path: url.pathname + url.search,
    headers,
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
    return jsonError(502, `Can't reach your Mac. ${message}`);
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

/** App commands the Gateway page runs (menu items on macOS, the page's own shortcuts on Windows). */
export type GatewayCommand =
  | "chat" | "tasks" | "artifacts" | "background" | "newTab" | "newMessage" | "refresh" | "voiceMode"
  | "togglePause" | "modelSettings" | "startFresh" | "usage" | "memory" | "builds" | "mascot" | "toggleTerminal";

function sendCommand(command: GatewayCommand): void {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.webContents.send("gateway:command", command);
}

function createMainWindow(): void {
  if (mainWindow) {
    void mainWindow.loadURL(HOST_ORIGIN);
    mainWindow.show();
    return;
  }
  const bounds = savedBounds();
  const window = new BrowserWindow({
    width: bounds?.width ?? 1180,
    height: bounds?.height ?? 820,
    x: bounds?.x,
    y: bounds?.y,
    minWidth: 760,
    minHeight: 540,
    title: "Cantrip Gateway",
    backgroundColor: WINDOW_BACKGROUND,
    show: false,
    // A unified toolbar like the Mac app's: the page draws the title bar; Windows keeps its
    // caption buttons as an overlay in the toolbar row.
    titleBarStyle: "hidden",
    ...(IS_WINDOWS
      ? { titleBarOverlay: { color: WINDOW_BACKGROUND, symbolColor: "#e8e8ea", height: TOOLBAR_HEIGHT } }
      : process.platform === "darwin" ? { trafficLightPosition: { x: 22, y: 19 } } : {}),
    webPreferences: {
      partition: HOST_PARTITION,
      preload: join(__dirname, "../preload/gateway.js"),
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
  window.on("focus", () => window.webContents.send("gateway:active", true));
  window.on("blur", () => window.webContents.send("gateway:active", false));
  window.webContents.setWindowOpenHandler(({ url }) => {
    openExternally(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    if (isHostURL(url) && new URL(url).pathname === "/") return;
    event.preventDefault();
    openExternally(url);
  });
  window.webContents.on("before-input-event", (event, input) => {
    if (input.type !== "keyDown") return;
    const primary = IS_WINDOWS ? input.control : input.meta;
    const key = input.key.toLowerCase();
    if (primary && (key === "=" || key === "+")) window.webContents.setZoomLevel(window.webContents.getZoomLevel() + 0.5);
    else if (primary && key === "-") window.webContents.setZoomLevel(window.webContents.getZoomLevel() - 0.5);
    else if (primary && key === "0") window.webContents.setZoomLevel(0);
    else if ((primary && input.shift && key === "i") || key === "f12") window.webContents.toggleDevTools();
    else if (primary && key === ",") openSettings();
    else return;
    event.preventDefault();
  });
  updateStatus({});
  if (pairing) window.setTitle(`Cantrip Gateway · ${displayName(pairing.server)}`);
  void window.loadURL(HOST_ORIGIN);
}

const SETTINGS_PAGE = `${HOST_ORIGIN}settings.html`;

/** Settings (Ctrl+,): saved Macs and voice, like the Mac app's Settings window. Not modal. */
function openSettings(link?: string): void {
  if (link) pendingLink = link;
  if (settingsWindow) {
    if (pendingLink) settingsWindow.webContents.send("gateway:link", pendingLink);
    pendingLink = null;
    if (settingsWindow.isMinimized()) settingsWindow.restore();
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  const window = new BrowserWindow({
    width: 640,
    height: 760,
    minWidth: 480,
    minHeight: 520,
    title: "Settings · Cantrip Gateway",
    backgroundColor: WINDOW_BACKGROUND,
    show: false,
    titleBarStyle: "hidden",
    ...(IS_WINDOWS
      ? { titleBarOverlay: { color: WINDOW_BACKGROUND, symbolColor: "#e8e8ea", height: 44 } }
      : process.platform === "darwin" ? { trafficLightPosition: { x: 16, y: 14 } } : {}),
    webPreferences: {
      partition: HOST_PARTITION,
      preload: join(__dirname, "../preload/settings.js"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  settingsWindow = window;
  window.once("ready-to-show", () => window.show());
  window.on("closed", () => {
    if (settingsWindow === window) settingsWindow = null;
    if (!pairing && !mainWindow) app.quit();
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    openExternally(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("before-input-event", (event, input) => {
    if (input.type === "keyDown" && ((IS_WINDOWS ? input.control : input.meta) && input.shift && input.key.toLowerCase() === "i")) {
      window.webContents.toggleDevTools();
      event.preventDefault();
    }
  });
  void window.loadURL(SETTINGS_PAGE);
}

// MARK: - IPC

function fromSettings(event: IpcMainInvokeEvent): void {
  const frame = event.senderFrame;
  if (!settingsWindow || event.sender !== settingsWindow.webContents || !frame || frame.parent || !frame.url.startsWith(SETTINGS_PAGE)) {
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
  const form = (input ?? {}) as Partial<ServerConfig> & { token?: string; id?: string };
  const server = validateServer({
    name: String(form.name ?? ""),
    url: String(form.url ?? ""),
    directAddress: String(form.directAddress ?? ""),
    tailscaleOnly: Boolean(form.tailscaleOnly),
  });
  const typed = String(form.token ?? "").trim();
  // An empty token field keeps the saved one when testing a saved Mac.
  const saved = form.id ? store.list().servers.find((item) => item.id === form.id) : undefined;
  const token = typed ? validateToken(typed) : saved ? saved.token : validateToken("");
  return { server, token };
}

function userError(error: unknown): { error: string } {
  return { error: error instanceof PairingError || error instanceof Error ? error.message : String(error) };
}

function settingsState() {
  const list = store.list();
  return {
    servers: list.servers.map((saved) => ({
      id: saved.id,
      name: displayName(saved.server),
      customName: saved.server.name,
      url: saved.server.url,
      directAddress: saved.server.directAddress,
      tailscaleOnly: saved.server.tailscaleOnly,
      routes: routesFor(saved.server).map(describeRoute),
      tokenSuffix: saved.token.slice(-4),
    })),
    selectedID: list.selectedID,
    unreadable: list.unreadable,
    status,
    version: app.getVersion(),
    platform: process.platform,
  };
}

function pushSettingsState(): void {
  settingsWindow?.webContents.send("gateway:servers", settingsState());
}

/** Connects to the selected Mac (or disconnects when none is): the main window starts fresh. */
function activateSelection(source: string): void {
  pairing = store.load();
  configureRouter();
  log(`${source}: ${pairing ? `routes ${routesFor(pairing.server).map(describeRoute).join(", ")}` : "no Mac selected"}`);
  if (pairing) {
    if (mainWindow) {
      mainWindow.setTitle(`Cantrip Gateway · ${displayName(pairing.server)}`);
      mainWindow.webContents.reloadIgnoringCache();
    } else {
      createMainWindow();
    }
  } else if (mainWindow) {
    const old = mainWindow;
    mainWindow = null;
    if (!settingsWindow) openSettings();
    old.destroy();
  }
  pushSettingsState();
}

function registerIPC(): void {
  ipcMain.on("gateway:hello", (event: IpcMainEvent) => {
    const frame = event.senderFrame;
    const allowed = mainWindow && event.sender === mainWindow.webContents && frame && !frame.parent && isHostURL(frame.url);
    event.returnValue = allowed
      ? {
        key: GATEWAY_KEY, version: app.getVersion(), platform: process.platform, status,
        server: pairing ? displayName(pairing.server) : "", focused: mainWindow?.isFocused() ?? true,
      }
      : null;
  });
  ipcMain.on("gateway:open-settings", (event: IpcMainEvent) => {
    if (mainWindow && event.sender === mainWindow.webContents) openSettings();
  });
  ipcMain.on("gateway:open-external", (event: IpcMainEvent, url: unknown) => {
    const senders = [mainWindow?.webContents, settingsWindow?.webContents];
    if (senders.includes(event.sender) && typeof url === "string") openExternally(url);
  });
  ipcMain.on("gateway:show-log", (event: IpcMainEvent) => {
    if (mainWindow && event.sender === mainWindow.webContents) shell.showItemInFolder(logFile());
  });
  ipcMain.handle("gateway:state", (event) => {
    fromSettings(event);
    const link = pendingLink;
    const notice = pendingNotice;
    pendingLink = null;
    pendingNotice = null;
    return { ...settingsState(), link, notice };
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
  ipcMain.handle("gateway:add", async (event, form: unknown) => {
    fromSettings(event);
    try {
      const { server, token } = readForm(form);
      const checks = await checkRoutes(server, token);
      if (!checks.some((check) => check.ok)) return { checks, error: "Nothing was saved: none of the routes reached the Mac with this token." };
      const firstMac = store.list().selectedID === null;
      // A selection this account can't decrypt counts as none, so the new Mac takes over.
      const saved = store.add(server, token, { select: firstMac });
      log(`saved a Mac: ${checks.map((check) => `${check.route} ${check.ok ? "ok" : "failed"}`).join("; ")}`);
      if (firstMac || pairing === null) {
        activateSelection("connected to the new Mac");
        // First pairing: the app replaces the pairing window.
        if (firstMac) settingsWindow?.close();
      } else if (store.list().selectedID === saved.id) {
        // The selected Mac's own entry changed (new token or name): reconnect with it.
        activateSelection("updated the selected Mac");
      }
      pushSettingsState();
      return { checks, saved: true, id: saved.id, selected: store.list().selectedID === saved.id };
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:select", (event, id: unknown) => {
    fromSettings(event);
    try {
      store.select(String(id));
      activateSelection("selected a saved Mac");
      return settingsState();
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:remove", async (event, id: unknown) => {
    fromSettings(event);
    try {
      const wasSelected = store.list().selectedID === id;
      store.remove(String(id));
      if (wasSelected) {
        await session.fromPartition(HOST_PARTITION).clearCache();
        activateSelection("removed the selected Mac");
      }
      pushSettingsState();
      return settingsState();
    } catch (error) {
      return userError(error);
    }
  });
  ipcMain.handle("gateway:open-log", (event) => {
    fromSettings(event);
    shell.showItemInFolder(logFile());
  });
}

// MARK: - App

function linkFrom(argv: string[]): string | undefined {
  return argv.find((value) => value.toLowerCase().startsWith(`${LINK_SCHEME}://`));
}

/**
 * Windows has no menu bar in the unified toolbar window: the page handles its shortcuts and its
 * More menu holds every command. macOS (development) gets the Mac app's Home menu.
 */
function buildMenu(): void {
  if (process.platform !== "darwin") {
    Menu.setApplicationMenu(null);
    return;
  }
  const command = (label: string, name: GatewayCommand, accelerator?: string): MenuItemConstructorOptions =>
    ({ label, accelerator, click: () => sendCommand(name) });
  const template: MenuItemConstructorOptions[] = [
    {
      role: "appMenu",
      submenu: [
        { role: "about" },
        { type: "separator" },
        { label: "Settings…", accelerator: "Cmd+,", click: () => openSettings() },
        { type: "separator" },
        { role: "hide" }, { role: "hideOthers" }, { role: "unhide" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    { role: "editMenu" },
    {
      label: "Home",
      submenu: [
        command("Chat", "chat", "Cmd+1"), command("Tasks", "tasks", "Cmd+2"), command("Artifacts", "artifacts", "Cmd+3"),
        command("Background", "background", "Cmd+B"),
        { type: "separator" },
        command("New Tab", "newTab", "Cmd+T"), command("New Message", "newMessage", "Cmd+N"),
        command("Refresh", "refresh", "Cmd+R"), command("Voice Mode", "voiceMode", "Shift+Cmd+V"),
        command("Pause Agent", "togglePause", "Shift+Cmd+P"),
        { type: "separator" },
        command("Model Settings…", "modelSettings", "Cmd+;"), command("Start Fresh", "startFresh"),
        command("Toggle Terminal", "toggleTerminal", "Ctrl+`"),
        command("Usage Limits", "usage"), command("Cantrip Memory", "memory"), command("GitHub Builds", "builds"),
        command("Customize Mascot…", "mascot"),
      ],
    },
    { role: "viewMenu" },
    { role: "windowMenu" },
    {
      role: "help",
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
    // Development and automated QA only (ignored in installed builds): pair from a link.
    const qaLink = process.env.CANTRIP_GATEWAY_QA_PAIR_LINK;
    if (qaLink && !app.isPackaged) {
      const parsed = parsePairingLink(qaLink);
      store.add({ name: parsed.name, url: parsed.url, directAddress: parsed.directAddress, tailscaleOnly: parsed.tailscaleOnly }, parsed.token, { select: true });
    }
    pairing = store.load();
    configureRouter();
    log(`start ${app.getVersion()} on ${process.platform}-${process.arch}; ${pairing ? `paired, routes: ${routesFor(pairing.server).map(describeRoute).join(", ")}` : "not paired"}`);

    const hostSession = session.fromPartition(HOST_PARTITION);
    hostSession.protocol.handle(HOST_SCHEME, handleHostRequest);
    // The Gateway page may use the microphone (dictation, Voice Mode; audio only) and read the
    // clipboard (Paste Image). MCP App frames get neither.
    hostSession.setPermissionRequestHandler((contents, permission, callback, details) => {
      const topFrame = contents === mainWindow?.webContents && details.isMainFrame !== false
        && isHostURL(details.requestingUrl ?? "");
      if (permission === "media") {
        const types = (details as Electron.MediaAccessPermissionRequest).mediaTypes ?? [];
        callback(topFrame && types.length > 0 && types.every((type) => type === "audio"));
        return;
      }
      if (permission === "clipboard-read") { callback(topFrame); return; }
      callback(["notifications", "clipboard-sanitized-write", "fullscreen"].includes(permission));
    });
    hostSession.setPermissionCheckHandler((contents, permission, origin) =>
      ["media", "clipboard-read", "clipboard-sanitized-write"].includes(permission)
        ? contents === mainWindow?.webContents && origin.startsWith(HOST_ORIGIN.slice(0, -1))
        : ["notifications", "fullscreen"].includes(permission));
    registerIPC();
    buildMenu();

    const link = linkFrom(process.argv) ?? pendingLink ?? undefined;
    if (pairing) createMainWindow();
    if (!pairing || link) openSettings(link);
  });

  app.on("window-all-closed", () => app.quit());
}
