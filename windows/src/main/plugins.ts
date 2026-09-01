import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, watch, type FSWatcher } from "node:fs";
import {
  appendFile,
  cp,
  mkdir,
  readFile,
  readdir,
  rename,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import {
  BrowserWindow,
  ipcMain,
  protocol,
  shell,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
} from "electron";
import {
  mergePluginMcpServers,
  parsePluginManifestText,
  pluginCapabilitySummary,
  resolveInsidePlugin,
} from "../shared/plugins";
import type {
  PluginManifest,
  PluginMcpSnapshot,
  PluginSummary,
} from "../shared/pluginTypes";

interface LoadedPlugin {
  id: string;
  directory: string;
  manifestPath: string;
  manifestHash: string;
  manifest: PluginManifest;
  panelPath?: string;
}

interface PluginState {
  enabledIds: string[];
  approvedHashes: Record<string, string>;
}

interface PluginRegistryOptions {
  root: string;
  statePath: string;
  mcpConfigPath: string;
  logPath: string;
  panelPreloadPath: string;
  examplePluginPath: string;
  onChanged: (plugins: PluginSummary[]) => void;
  onPrompt: (prompt: string) => void;
  getCantripStatus: () => Promise<Record<string, unknown>>;
  runAction: (name: string) => Promise<unknown>;
}

const MAX_DATA_INPUT = 64 * 1024;
const MAX_DATA_OUTPUT = 1024 * 1024;

function mimeType(filePath: string): string {
  const types: Record<string, string> = {
    ".css": "text/css; charset=utf-8",
    ".gif": "image/gif",
    ".html": "text/html; charset=utf-8",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".webp": "image/webp",
  };
  return types[path.extname(filePath).toLocaleLowerCase()] ?? "application/octet-stream";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class PluginRegistry {
  private plugins = new Map<string, LoadedPlugin>();
  private state: PluginState = { enabledIds: [], approvedHashes: {} };
  private watcher: FSWatcher | null = null;
  private reloadTimer: NodeJS.Timeout | null = null;
  private panelWindows = new Map<string, BrowserWindow>();
  private webContentsPlugins = new Map<number, string>();
  private pluginTokens = new Map<string, string>();

  constructor(private readonly options: PluginRegistryOptions) {}

  async initialize(): Promise<void> {
    this.registerProtocol();
    this.registerIpc();
    await mkdir(this.options.root, { recursive: true });
    await this.loadState();
    await this.reload();
    this.startWatcher();
  }

  list(): PluginSummary[] {
    return [...this.plugins.values()]
      .map((plugin) => this.summary(plugin))
      .sort((left, right) => left.name.localeCompare(right.name));
  }

  async reload(): Promise<PluginSummary[]> {
    const previousPanels = new Map(this.panelWindows);
    const discovered = new Map<string, LoadedPlugin>();
    const entries = await readdir(this.options.root, { withFileTypes: true });

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const id = entry.name;
      const directory = path.join(this.options.root, id);
      const manifestPath = path.join(directory, "manifest.json");
      try {
        const raw = await readFile(manifestPath);
        const manifest = parsePluginManifestText(raw.toString("utf8"));
        if (!manifest) continue;
        let panelPath: string | undefined;
        if (manifest.panel?.html) {
          try {
            panelPath = await resolveInsidePlugin(directory, manifest.panel.html);
          } catch (error) {
            console.warn(`Ignoring invalid panel for plugin ${id}:`, error);
          }
        }
        discovered.set(id, {
          id,
          directory,
          manifestPath,
          manifestHash: createHash("sha256").update(raw).digest("hex"),
          manifest,
          panelPath,
        });
      } catch (error) {
        console.warn(`Skipping plugin ${id}:`, error);
      }
    }

    this.plugins = discovered;
    await this.rewriteMcpConfig();
    for (const [id, window] of previousPanels) {
      const plugin = this.plugins.get(id);
      if (!plugin || !this.isActive(plugin) || !plugin.panelPath) {
        window.close();
      } else {
        void window.webContents.session.clearCache().then(() => {
          if (!window.isDestroyed()) {
            return window.loadURL(this.panelUrl(plugin, Date.now().toString(36)));
          }
          return undefined;
        });
      }
    }
    this.emitChanged();
    return this.list();
  }

  async approve(id: string): Promise<PluginSummary[]> {
    const plugin = this.requirePlugin(id);
    this.state.approvedHashes[id] = plugin.manifestHash;
    if (!this.state.enabledIds.includes(id)) this.state.enabledIds.push(id);
    await this.persistState();
    await this.rewriteMcpConfig();
    this.emitChanged();
    return this.list();
  }

  async revoke(id: string): Promise<PluginSummary[]> {
    this.requirePlugin(id);
    delete this.state.approvedHashes[id];
    this.state.enabledIds = this.state.enabledIds.filter((entry) => entry !== id);
    this.panelWindows.get(id)?.close();
    await this.persistState();
    await this.rewriteMcpConfig();
    this.emitChanged();
    return this.list();
  }

  async setEnabled(id: string, enabled: boolean): Promise<PluginSummary[]> {
    const plugin = this.requirePlugin(id);
    const enabledIds = new Set(this.state.enabledIds);
    if (enabled) enabledIds.add(id);
    else enabledIds.delete(id);
    this.state.enabledIds = [...enabledIds];
    if (!enabled) this.panelWindows.get(id)?.close();
    await this.persistState();
    await this.rewriteMcpConfig();
    this.emitChanged();
    if (enabled && !this.isApproved(plugin)) {
      return this.list();
    }
    return this.list();
  }

  async openPanel(id: string): Promise<{ ok: boolean; error?: string }> {
    const plugin = this.requirePlugin(id);
    if (!this.isActive(plugin)) {
      return { ok: false, error: "Approve and enable this plugin first." };
    }
    if (!plugin.panelPath || !plugin.manifest.panel) {
      return { ok: false, error: "This plugin does not provide a valid dashboard." };
    }

    const existing = this.panelWindows.get(id);
    if (existing && !existing.isDestroyed()) {
      existing.show();
      existing.focus();
      return { ok: true };
    }

    const bridgeToken = randomBytes(32).toString("hex");
    const window = new BrowserWindow({
      width: 980,
      height: 700,
      minWidth: 560,
      minHeight: 380,
      title: plugin.manifest.panel.title ?? plugin.manifest.name,
      backgroundColor: "#181819",
      autoHideMenuBar: true,
      webPreferences: {
        preload: this.options.panelPreloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        sandbox: true,
        partition: `plugin-${createHash("sha256").update(id).digest("hex").slice(0, 16)}`,
        additionalArguments: [`--cantrip-plugin-token=${bridgeToken}`],
      },
    });
    const panelProtocol = window.webContents.session.protocol;
    if (!panelProtocol.isProtocolHandled("cantrip-plugin")) {
      panelProtocol.handle("cantrip-plugin", (request) =>
        this.servePluginAsset(request),
      );
    }
    const webContentsId = window.webContents.id;
    this.panelWindows.set(id, window);
    this.webContentsPlugins.set(webContentsId, id);
    this.pluginTokens.set(bridgeToken, id);
    window.on("closed", () => {
      this.panelWindows.delete(id);
      this.webContentsPlugins.delete(webContentsId);
      this.pluginTokens.delete(bridgeToken);
    });
    window.webContents.setWindowOpenHandler(({ url }) => {
      if (this.validExternalUrl(url)) void shell.openExternal(url);
      return { action: "deny" };
    });
    window.webContents.on("will-navigate", (event, url) => {
      if (url.startsWith(`cantrip-plugin://${id.toLocaleLowerCase()}/`)) return;
      event.preventDefault();
      if (this.validExternalUrl(url)) void shell.openExternal(url);
    });

    await window.loadURL(this.panelUrl(plugin));
    return { ok: true };
  }

  async openFolder(): Promise<boolean> {
    return (await shell.openPath(this.options.root)) === "";
  }

  async installExample(): Promise<PluginSummary[]> {
    const destination = path.join(this.options.root, "hello-dashboard");
    if (!existsSync(destination)) {
      await cp(this.options.examplePluginPath, destination, {
        recursive: true,
        force: false,
        errorOnExist: true,
      });
    }
    return this.reload();
  }

  mcpSnapshot(): PluginMcpSnapshot | null {
    const servers = mergePluginMcpServers(
      [...this.plugins.values()]
        .filter((plugin) => this.isActive(plugin))
        .map((plugin) => ({
          id: plugin.id,
          name: plugin.manifest.name,
          manifest: plugin.manifest,
        })),
    );
    return Object.keys(servers).length
      ? { configPath: this.options.mcpConfigPath, servers }
      : null;
  }

  dispose(): void {
    this.watcher?.close();
    if (this.reloadTimer) clearTimeout(this.reloadTimer);
    for (const window of this.panelWindows.values()) window.destroy();
  }

  private summary(plugin: LoadedPlugin): PluginSummary {
    const enabled = this.state.enabledIds.includes(plugin.id);
    const approved = this.isApproved(plugin);
    return {
      id: plugin.id,
      name: plugin.manifest.name,
      version: plugin.manifest.version,
      description: plugin.manifest.description,
      manifestHash: plugin.manifestHash,
      enabled,
      approved,
      active: enabled && approved,
      hasPanel: Boolean(plugin.panelPath),
      panelTitle: plugin.manifest.panel?.title ?? plugin.manifest.name,
      capabilities: plugin.manifest.panel?.capabilities ?? [],
      capabilitySummary: pluginCapabilitySummary(plugin.manifest),
    };
  }

  private isApproved(plugin: LoadedPlugin): boolean {
    return this.state.approvedHashes[plugin.id] === plugin.manifestHash;
  }

  private isActive(plugin: LoadedPlugin): boolean {
    return this.state.enabledIds.includes(plugin.id) && this.isApproved(plugin);
  }

  private requirePlugin(id: string): LoadedPlugin {
    const plugin = this.plugins.get(id);
    if (!plugin) throw new Error("Plugin not found.");
    return plugin;
  }

  private async loadState(): Promise<void> {
    try {
      const parsed = JSON.parse(await readFile(this.options.statePath, "utf8")) as unknown;
      if (isRecord(parsed)) {
        this.state = {
          enabledIds: Array.isArray(parsed.enabledIds)
            ? parsed.enabledIds.filter((id): id is string => typeof id === "string")
            : [],
          approvedHashes: isRecord(parsed.approvedHashes)
            ? Object.fromEntries(
                Object.entries(parsed.approvedHashes).filter(
                  (entry): entry is [string, string] => typeof entry[1] === "string",
                ),
              )
            : {},
        };
      }
    } catch {
      this.state = { enabledIds: [], approvedHashes: {} };
    }
  }

  private async persistState(): Promise<void> {
    await mkdir(path.dirname(this.options.statePath), { recursive: true });
    const temporary = `${this.options.statePath}.tmp`;
    await writeFile(temporary, `${JSON.stringify(this.state, null, 2)}\n`, "utf8");
    await rename(temporary, this.options.statePath);
  }

  private async rewriteMcpConfig(): Promise<void> {
    const snapshot = this.mcpSnapshot();
    const body = `${JSON.stringify({ mcpServers: snapshot?.servers ?? {} }, null, 2)}\n`;
    await mkdir(path.dirname(this.options.mcpConfigPath), { recursive: true });
    const temporary = `${this.options.mcpConfigPath}.tmp`;
    await writeFile(temporary, body, "utf8");
    await rename(temporary, this.options.mcpConfigPath);
  }

  private startWatcher(): void {
    this.watcher = watch(this.options.root, { recursive: true }, () => {
      if (this.reloadTimer) clearTimeout(this.reloadTimer);
      this.reloadTimer = setTimeout(() => void this.reload(), 250);
    });
  }

  private emitChanged(): void {
    this.options.onChanged(this.list());
  }

  private registerProtocol(): void {
    if (!protocol.isProtocolHandled("cantrip-plugin")) {
      protocol.handle("cantrip-plugin", (request) => this.servePluginAsset(request));
    }
  }

  private async servePluginAsset(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url);
      const plugin = [...this.plugins.values()].find(
        (entry) => entry.id.toLocaleLowerCase() === url.hostname.toLocaleLowerCase(),
      );
      if (!plugin || !this.isActive(plugin)) {
        return new Response("Plugin is not active.", { status: 403 });
      }
      const relative = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
      const filePath = await resolveInsidePlugin(plugin.directory, relative);
      const bytes = await readFile(filePath);
      return new Response(bytes, {
        headers: {
          "Content-Type": mimeType(filePath),
          "Content-Security-Policy":
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src http: https: ws: wss:; img-src 'self' data: http: https:; frame-src http: https:;",
        },
      });
    } catch {
      return new Response("Plugin asset not found.", { status: 404 });
    }
  }

  private registerIpc(): void {
    ipcMain.handle("plugins:list", () => this.list());
    ipcMain.handle("plugins:rescan", () => this.reload());
    ipcMain.handle("plugins:approve", (_event, id: unknown) =>
      typeof id === "string" ? this.approve(id) : this.list(),
    );
    ipcMain.handle("plugins:revoke", (_event, id: unknown) =>
      typeof id === "string" ? this.revoke(id) : this.list(),
    );
    ipcMain.handle("plugins:set-enabled", (_event, id: unknown, enabled: unknown) =>
      typeof id === "string" && typeof enabled === "boolean"
        ? this.setEnabled(id, enabled)
        : this.list(),
    );
    ipcMain.handle("plugins:open-panel", (_event, id: unknown) =>
      typeof id === "string"
        ? this.openPanel(id)
        : { ok: false, error: "Invalid plugin." },
    );
    ipcMain.handle("plugins:open-folder", () => this.openFolder());
    ipcMain.handle("plugins:install-example", () => this.installExample());

    ipcMain.on("plugin:send-prompt", (event, token: unknown, prompt: unknown) => {
      const plugin = this.senderPlugin(event, token);
      if (plugin && typeof prompt === "string" && prompt.trim() && prompt.length <= 32_000) {
        this.options.onPrompt(prompt);
      }
    });
    ipcMain.on("plugin:log", (event, token: unknown, message: unknown) => {
      const plugin = this.senderPlugin(event, token);
      if (!plugin || typeof message !== "string") return;
      const line = `[${new Date().toISOString()}] plugin:${plugin.id} ${message.slice(0, 500)}\n`;
      void appendFile(this.options.logPath, line, "utf8");
    });
    ipcMain.on("plugin:open-url", (event, token: unknown, url: unknown) => {
      if (
        this.senderPlugin(event, token) &&
        typeof url === "string" &&
        this.validExternalUrl(url)
      ) {
        void shell.openExternal(url);
      }
    });
    ipcMain.handle(
      "plugin:request-data",
      (event, token: unknown, name: unknown, payload: unknown) =>
        this.requestData(event, token, name, payload),
    );
    ipcMain.handle("plugin:run-action", (event, token: unknown, name: unknown) =>
      this.runAction(event, token, name),
    );
  }

  private senderPlugin(
    event: IpcMainEvent | IpcMainInvokeEvent,
    token: unknown,
  ): LoadedPlugin | null {
    if (typeof token !== "string") return null;
    const id = this.webContentsPlugins.get(event.sender.id);
    if (!id || this.pluginTokens.get(token) !== id) return null;
    const plugin = id ? this.plugins.get(id) : undefined;
    if (!plugin || !this.isActive(plugin)) return null;
    return plugin;
  }

  private async requestData(
    event: IpcMainInvokeEvent,
    token: unknown,
    name: unknown,
    payload: unknown,
  ): Promise<Record<string, unknown>> {
    const plugin = this.senderPlugin(event, token);
    if (!plugin || typeof name !== "string") {
      throw new Error("Plugin access denied.");
    }
    if (payload !== undefined && !isRecord(payload)) {
      throw new Error("Plugin data payload must be a JSON object.");
    }

    const capabilities = plugin.manifest.panel?.capabilities ?? [];
    if (name === "cantripStatus") {
      if (!capabilities.includes("cantripStatus")) {
        throw new Error("The cantripStatus capability was not approved.");
      }
      return this.options.getCantripStatus();
    }
    if (name === "dailyBriefing" || name.startsWith("dailyBriefing.")) {
      throw new Error("dailyBriefing is not available on Windows yet.");
    }

    const source = plugin.manifest.dataSources?.[name];
    if (!source) throw new Error(`Unknown plugin data source: ${name}`);
    const command = path.isAbsolute(source.command)
      ? source.command
      : await resolveInsidePlugin(plugin.directory, source.command);
    if (!existsSync(command)) throw new Error(`Data source command not found: ${command}`);
    return this.runDataSource(
      command,
      source.args ?? [],
      plugin.directory,
      payload as Record<string, unknown> | undefined,
      Math.max(1, Math.min(60, source.timeoutSeconds ?? 10)),
    );
  }

  private async runAction(
    event: IpcMainInvokeEvent,
    token: unknown,
    name: unknown,
  ): Promise<unknown> {
    const plugin = this.senderPlugin(event, token);
    if (!plugin || typeof name !== "string") throw new Error("Plugin access denied.");
    if (!(plugin.manifest.panel?.capabilities ?? []).includes("cantripActions")) {
      throw new Error("The cantripActions capability was not approved.");
    }
    if (!["update", "build", "relaunch", "openRepo", "openLog"].includes(name)) {
      throw new Error("Unknown Cantrip action.");
    }
    return this.options.runAction(name);
  }

  private runDataSource(
    command: string,
    args: string[],
    cwd: string,
    payload: Record<string, unknown> | undefined,
    timeoutSeconds: number,
  ): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const extension = path.extname(command).toLocaleLowerCase();
      let executable = command;
      let processArgs = args;
      if (extension === ".ps1") {
        executable = "powershell.exe";
        processArgs = ["-NoProfile", "-NonInteractive", "-File", command, ...args];
      } else if (extension === ".cmd" || extension === ".bat") {
        executable = process.env.ComSpec ?? "cmd.exe";
        processArgs = ["/d", "/s", "/c", command, ...args];
      }

      const child = spawn(executable, processArgs, {
        cwd,
        shell: false,
        windowsHide: true,
        env: process.env,
      });
      const stdout: Buffer[] = [];
      const stderr: Buffer[] = [];
      let outputBytes = 0;
      let settled = false;
      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        child.kill();
        clearTimeout(timer);
        reject(error);
      };
      const timer = setTimeout(
        () => fail(new Error(`Data source timed out after ${timeoutSeconds}s.`)),
        timeoutSeconds * 1000,
      );
      timer.unref();

      child.stdout.on("data", (chunk: Buffer) => {
        outputBytes += chunk.length;
        if (outputBytes > MAX_DATA_OUTPUT) {
          fail(new Error("Data source output exceeds 1 MB."));
        } else {
          stdout.push(chunk);
        }
      });
      child.stderr.on("data", (chunk: Buffer) => {
        if (Buffer.concat(stderr).length < 64 * 1024) stderr.push(chunk);
      });
      child.on("error", fail);
      child.on("close", (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (code !== 0) {
          reject(
            new Error(
              Buffer.concat(stderr).toString("utf8").trim() ||
                `Data source exited with code ${code}.`,
            ),
          );
          return;
        }
        try {
          const parsed = JSON.parse(Buffer.concat(stdout).toString("utf8")) as unknown;
          if (!isRecord(parsed)) throw new Error("Data source must return a JSON object.");
          resolve(parsed);
        } catch (error) {
          reject(error);
        }
      });

      if (payload) {
        const input = JSON.stringify(payload);
        if (Buffer.byteLength(input) > MAX_DATA_INPUT) {
          fail(new Error("Plugin data payload exceeds 64 KB."));
          return;
        }
        child.stdin.end(input);
      } else {
        child.stdin.end();
      }
    });
  }

  private validExternalUrl(value: string): boolean {
    try {
      const url = new URL(value);
      return (
        ["http:", "https:"].includes(url.protocol) &&
        Boolean(url.hostname) &&
        !url.username &&
        !url.password
      );
    } catch {
      return false;
    }
  }

  private panelUrl(plugin: LoadedPlugin, revision?: string): string {
    if (!plugin.panelPath) throw new Error("Plugin panel path is unavailable.");
    const relativePanel = path
      .relative(plugin.directory, plugin.panelPath)
      .split(path.sep);
    const base = `cantrip-plugin://${plugin.id.toLocaleLowerCase()}/${relativePanel
      .map(encodeURIComponent)
      .join("/")}`;
    return revision ? `${base}?revision=${encodeURIComponent(revision)}` : base;
  }
}
