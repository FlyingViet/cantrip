// Checks each backend CLI on this PC the way Cantrip on the Mac does (BackendStatus.swift): installed
// path and version, signed in or not (account and method, never a token) and Antigravity's quota, with
// cheap commands that make no model calls, each under a time limit. Results are cached in userData so
// nothing waits on a check; a sign-out is confirmed by a second check before routing skips the backend,
// and going down or coming back sends one alert each.
import { execFile, spawn } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";
import { BACKEND_IDS, BACKEND_NAMES, backendTime } from "../shared/backendHealth";
import type {
  BackendHealth,
  BackendId,
  BackendQuota,
  BackendSignIn,
  BackendsAction,
  BackendsSnapshot,
} from "../shared/types";
import { ansiPattern, commandSpec, type CommandSpec } from "./backends";

export const VERSION_TIMEOUT_MS = 20_000;
export const AUTH_TIMEOUT_MS = 45_000;
const CHECK_INTERVAL_MS = 30 * 60_000;
const FIRST_CHECK_MS = 20_000;
const CONFIRM_DELAY_MS = 3_000;
const SIGN_IN_TIMEOUT_MS = 15 * 60_000;
const RECHECK_AFTER_FAILURE_MS = 2 * 60_000;
const TERMINAL_RECHECKS_MS = [30_000, 90_000, 180_000, 300_000];

// MARK: Running a CLI

export interface CommandResult {
  stdout: string;
  stderr: string;
  /** The exit code; null when it was killed or couldn't start. */
  code: number | null;
  timedOut: boolean;
  /** Why it couldn't start (ENOENT, EACCES, ...). */
  error?: string;
}

/**
 * Ends a process and, on Windows, everything it started: npm's Codex runs its real CLI as a child of
 * node.exe, which a plain kill would leave running.
 */
export function killTree(child: { pid?: number; kill(signal?: NodeJS.Signals): boolean }, signal?: NodeJS.Signals): void {
  if (process.platform !== "win32" || !child.pid) {
    child.kill(signal);
    return;
  }
  execFile("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true }, (error) => {
    if (error) child.kill(signal);
  });
}

/** Runs `spec` with `args` (no shell); after `timeoutMs` it and its children are killed. Never rejects. */
export function runCommand(spec: CommandSpec, args: string[], timeoutMs: number): Promise<CommandResult> {
  return new Promise((resolve) => {
    let settled = false;
    let timedOut = false;
    let limit: ReturnType<typeof setTimeout> | undefined;
    let guard: ReturnType<typeof setTimeout> | undefined;
    const finish = (result: CommandResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(limit);
      clearTimeout(guard);
      resolve(result);
    };
    try {
      const child = execFile(
        spec.executable,
        [...spec.prefixArgs, ...args],
        {
          cwd: homedir(),
          env: { ...process.env, NO_COLOR: "1", TERM: "dumb" },
          windowsHide: true,
          maxBuffer: 1_000_000,
          encoding: "utf8",
        },
        (error, stdout, stderr) => {
          const failure = error as (Error & { code?: number | string | null }) | null;
          const startError =
            typeof failure?.code === "string" && failure.code !== "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";
          finish({
            stdout: String(stdout ?? ""),
            stderr: String(stderr ?? ""),
            code: timedOut ? null : failure ? (typeof failure.code === "number" ? failure.code : null) : 0,
            timedOut,
            error: !timedOut && startError ? String(failure.code) : undefined,
          });
        },
      );
      limit = setTimeout(() => {
        timedOut = true;
        killTree(child, "SIGKILL");
        // execFile waits for its pipes to close; a process still holding them mustn't stretch the limit.
        guard = setTimeout(() => {
          child.stdout?.destroy();
          child.stderr?.destroy();
          finish({ stdout: "", stderr: "", code: null, timedOut: true });
        }, 2_000);
      }, timeoutMs);
    } catch (error) {
      finish({ stdout: "", stderr: "", code: null, timedOut: false, error: error instanceof Error ? error.message : String(error) });
    }
  });
}

// MARK: Reading what the CLIs say

export interface Auth {
  /** Absent when the answer couldn't tell. */
  signedIn?: boolean;
  account?: string;
  method?: string;
  plan?: string;
  problem?: string;
  quota?: BackendQuota[];
  limitedUntil?: string;
}

const SIGNED_OUT_PHRASES = ["not logged in", "not signed in", "unauthenticated", "not authenticated"];
const AUTH_FAILURE_PHRASES = [
  "failed to authenticate",
  "oauth token",
  "invalid api key",
  "run /login",
  "not logged in",
  "authentication_error",
  "authentication failed",
  "unauthorized",
];

export function saysSignedOut(text: string): boolean {
  const lowered = text.toLowerCase();
  return SIGNED_OUT_PHRASES.some((phrase) => lowered.includes(phrase));
}

/** Keys, tokens and other long opaque strings out of text that may be shown or saved. */
export function redactSecrets(text: string): string {
  return text
    .replace(/\b(?:Bearer|token)\s+[A-Za-z0-9._~+/=-]{12,}/gi, (match) => `${match.split(/\s+/)[0]} [redacted]`)
    .replace(/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}/g, "[redacted]")
    .replace(/\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{8,}/g, "[redacted]")
    .replace(/\bAIza[0-9A-Za-z_-]{20,}/g, "[redacted]")
    .replace(/\b[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}/g, "[redacted]")
    .replace(/[A-Za-z0-9+_-]{40,}={0,2}/g, "[redacted]");
}

/** The first non-empty line, keys redacted, for a row's problem text. */
export function firstLine(text: string): string {
  return redactSecrets(
    text
      .replace(ansiPattern, "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) ?? "",
  ).slice(0, 200);
}

/** The line of a failed run that names a sign-in failure (keys redacted), or null. */
export function authFailureLine(text: string): string | null {
  const lines = text.replace(ansiPattern, "").split(/\r?\n/);
  const line = lines.find((entry) => {
    const lowered = entry.toLowerCase();
    return AUTH_FAILURE_PHRASES.some((phrase) => lowered.includes(phrase));
  });
  return line ? redactSecrets(line.trim()).slice(0, 240) : null;
}

export function parseVersion(text: string): string | undefined {
  return text.match(/\d+\.\d+\.\d+/)?.[0];
}

function jsonIn(text: string): Record<string, unknown> | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const value: unknown = JSON.parse(text.slice(start, end + 1));
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function capitalized(value: unknown): string | undefined {
  const word = text(value);
  return word ? word.charAt(0).toUpperCase() + word.slice(1).toLowerCase() : undefined;
}

/** `claude auth status`: JSON with loggedIn, authMethod, apiProvider, email and subscriptionType. */
export function parseClaudeStatus(output: string): Auth {
  const json = jsonIn(output);
  if (json && typeof json.loggedIn === "boolean") {
    if (!json.loggedIn) return { signedIn: false, problem: "Claude Code isn't signed in." };
    const method = text(json.authMethod);
    let label: string;
    if (json.apiProvider === "bedrock") label = "Amazon Bedrock";
    else if (json.apiProvider === "vertex") label = "Google Vertex AI";
    else if (method === "claude.ai") label = "Claude account";
    else if (method === "console" || method === "oauth_console") label = "Anthropic Console";
    else if (method && /key/i.test(method)) label = "API key";
    else label = method ?? "Claude account";
    return {
      signedIn: true,
      account: text(json.email) ?? text(json.orgName),
      method: label,
      plan: capitalized(json.subscriptionType),
    };
  }
  if (saysSignedOut(output)) return { signedIn: false, problem: firstLine(output) };
  return { problem: output.trim() ? firstLine(output) : "Claude Code didn't report its sign-in." };
}

/** `codex login status`: "Logged in using ChatGPT", "Logged in using an API key" or "Not logged in". */
export function parseCodexLoginStatus(output: string): Auth {
  const lowered = output.toLowerCase();
  if (lowered.includes("not logged in")) return { signedIn: false, problem: firstLine(output) };
  if (lowered.includes("logged in using chatgpt")) return { signedIn: true, method: "ChatGPT" };
  if (lowered.includes("logged in") && lowered.includes("api key")) return { signedIn: true, method: "API key" };
  if (lowered.includes("logged in")) return { signedIn: true };
  return { problem: output.trim() ? firstLine(output) : "Codex didn't report its sign-in." };
}

/**
 * Copilot CLI has no status command: `.copilot\config.json` (opening with `//` comment lines) lists the
 * signed-in GitHub users by host and login, never a token. `null` means the file couldn't be read.
 */
export function parseCopilotConfig(contents: string | null, env: NodeJS.ProcessEnv = {}): Auth {
  if (contents === null) return { problem: "Couldn't read Copilot CLI's settings (.copilot\\config.json)." };
  let config: unknown;
  try {
    config = JSON.parse(
      contents
        .split(/\r?\n/)
        .filter((line) => !line.trim().startsWith("//"))
        .join("\n"),
    );
  } catch {
    return { problem: "Copilot CLI's settings (.copilot\\config.json) aren't valid JSON." };
  }
  if (!config || typeof config !== "object") return { problem: "Copilot CLI's settings are empty." };
  const fields = config as { loggedInUsers?: unknown; lastLoggedInUser?: { login?: unknown } };
  const users = Array.isArray(fields.loggedInUsers)
    ? fields.loggedInUsers.filter((user): user is { login?: unknown } => Boolean(user) && typeof user === "object")
    : [];
  if (users.length) {
    return {
      signedIn: true,
      account: text(fields.lastLoggedInUser?.login) ?? users.map((user) => text(user.login)).find(Boolean),
      method: "GitHub account",
    };
  }
  // Copilot also signs in from a token or a model provider in the environment, which the file doesn't list.
  if (env.COPILOT_GITHUB_TOKEN || env.GH_TOKEN || env.GITHUB_TOKEN || env.COPILOT_PROVIDER_BASE_URL) {
    return { problem: "No GitHub account is saved in Copilot CLI; it may be using a token or provider from the environment." };
  }
  return { signedIn: false, problem: "Copilot CLI isn't signed in." };
}

function antigravityQuota(json: Record<string, unknown>): Pick<Auth, "quota" | "limitedUntil"> {
  const raw = (json.command as { data?: { groups?: unknown } } | undefined)?.data?.groups;
  const groups = Array.isArray(raw) ? (raw as Record<string, unknown>[]) : [];
  const quota: BackendQuota[] = [];
  // The account is out of quota only when every model group has a used-up window.
  let limitedUntil: number | undefined;
  let everyGroupLimited = groups.length > 0;
  for (const group of groups) {
    const groupName = text(group?.name);
    const buckets = Array.isArray(group?.buckets) ? (group.buckets as Record<string, unknown>[]) : [];
    let groupLimit: number | undefined;
    let groupLimited = false;
    for (const bucket of buckets) {
      const fraction = typeof bucket?.remaining_fraction === "number" ? bucket.remaining_fraction : Number.NaN;
      if (!groupName || !Number.isFinite(fraction)) continue;
      const window = text(bucket.window);
      const title =
        window === "weekly" ? "Weekly limit" : window === "5h" || window === "five_hour" ? "5-hour limit" : text(bucket.name) ?? groupName;
      const reset = Date.parse(text(bucket.reset_time) ?? "");
      quota.push({
        name: `${groupName}: ${title.toLowerCase()}`,
        usedPercent: Math.min(100, Math.max(0, (1 - fraction) * 100)),
        ...(Number.isFinite(reset) ? { resetsAt: new Date(reset).toISOString() } : {}),
      });
      if (fraction <= 0) {
        groupLimited = true;
        if (Number.isFinite(reset)) groupLimit = Math.max(groupLimit ?? reset, reset);
      }
    }
    if (!buckets.length) continue;
    if (!groupLimited || groupLimit === undefined) everyGroupLimited = false;
    else limitedUntil = Math.min(limitedUntil ?? groupLimit, groupLimit);
  }
  return {
    quota,
    ...(everyGroupLimited && limitedUntil !== undefined ? { limitedUntil: new Date(limitedUntil).toISOString() } : {}),
  };
}

/** `agy -p /usage --output-format json`, answered by the CLI itself (no model call, no quota). */
export function parseAntigravityUsage(stdout: string, stderr = ""): Auth {
  const json = jsonIn(stdout);
  if (json && typeof json.status === "string") {
    if (json.status === "SUCCESS") return { signedIn: true, method: "Google account", ...antigravityQuota(json) };
    const error = json.error as { message?: unknown } | string | undefined;
    const message =
      text(error) ?? text(typeof error === "object" ? error?.message : undefined) ?? text(json.response) ?? json.status;
    if (saysSignedOut(message) || saysSignedOut(json.status)) return { signedIn: false, problem: firstLine(message) };
    return { problem: firstLine(message) };
  }
  const output = `${stdout}\n${stderr}`;
  if (saysSignedOut(output)) return { signedIn: false, problem: firstLine(output) };
  return { problem: output.trim() ? firstLine(output) : "Antigravity didn't report its sign-in." };
}

/** The first link and device code a CLI's sign-in prints. */
export function deviceCode(output: string): { url?: string; code?: string } {
  const plain = output.replace(ansiPattern, "");
  const url = plain.match(/https:\/\/[^\s"'<>)]+/)?.[0]?.replace(/[.,;]+$/, "");
  const code = plain.match(/\b[A-Z0-9]{4,5}-[A-Z0-9]{4,5}\b/)?.[0];
  return { ...(url ? { url } : {}), ...(code ? { code } : {}) };
}

// MARK: Checking one backend

/** What one check found. Never a token or key. */
export interface BackendProbe {
  installed: boolean;
  path?: string;
  version?: string;
  signedIn?: boolean;
  account?: string;
  authMethod?: string;
  plan?: string;
  quota?: BackendQuota[];
  limitedUntil?: string;
  problem?: string;
}

export interface ProbeDeps {
  resolve(id: BackendId): Promise<CommandSpec | null>;
  run(spec: CommandSpec, args: string[], timeoutMs: number): Promise<CommandResult>;
  home: string;
  env?: NodeJS.ProcessEnv;
  readFile?(file: string): Promise<string>;
  /** Copilot falls back to the GitHub CLI's sign-in; true when `gh auth status` succeeds. */
  githubCliSignedIn?(): Promise<boolean>;
}

/** `gh auth status` exits 0 when the GitHub CLI is signed in (its output, which names a masked token, is ignored). */
export async function githubCliSignedIn(): Promise<boolean> {
  const gh = await commandSpec("gh").catch(() => null);
  if (!gh) return false;
  return (await runCommand(gh, ["auth", "status"], VERSION_TIMEOUT_MS)).code === 0;
}

async function authCheck(id: BackendId, spec: CommandSpec, deps: ProbeDeps): Promise<Auth> {
  const name = BACKEND_NAMES[id];
  if (id === "copilot") {
    const file = path.join(deps.home, ".copilot", "config.json");
    const contents = await (deps.readFile ?? ((target: string) => readFile(target, "utf8")))(file).catch(() => null);
    const auth = parseCopilotConfig(contents, deps.env ?? {});
    if (auth.signedIn === false && (await deps.githubCliSignedIn?.().catch(() => false))) {
      return { problem: "No GitHub account is saved in Copilot CLI; it may be using the GitHub CLI's sign-in." };
    }
    return auth;
  }
  const args = id === "claude" ? ["auth", "status"] : id === "codex" ? ["login", "status"] : ["-p", "/usage", "--output-format", "json"];
  const result = await deps.run(spec, args, AUTH_TIMEOUT_MS);
  if (result.timedOut) return { problem: `${name} didn't answer within ${Math.round(AUTH_TIMEOUT_MS / 1000)} s.` };
  if (result.error) return { problem: `${name} couldn't start (${result.error}).` };
  if (id === "agy") return parseAntigravityUsage(result.stdout, result.stderr);
  const output = `${result.stdout}\n${result.stderr}`;
  return id === "claude" ? parseClaudeStatus(output) : parseCodexLoginStatus(output);
}

/** Install, version and sign-in of one backend. A slow or failing check leaves `signedIn` unset. */
export async function probeBackend(id: BackendId, deps: ProbeDeps): Promise<BackendProbe> {
  let spec: CommandSpec | null;
  try {
    spec = await deps.resolve(id);
  } catch {
    spec = null;
  }
  if (!spec) return { installed: false };
  const version = await deps.run(spec, ["--version"], VERSION_TIMEOUT_MS);
  if (version.error === "ENOENT") return { installed: false };
  let auth: Auth;
  try {
    auth = await authCheck(id, spec, deps);
  } catch (error) {
    auth = { problem: `${BACKEND_NAMES[id]}'s check failed: ${error instanceof Error ? error.message : String(error)}` };
  }
  return {
    installed: true,
    path: spec.path ?? spec.prefixArgs[0] ?? spec.executable,
    version: version.timedOut ? undefined : parseVersion(`${version.stdout}\n${version.stderr}`),
    signedIn: auth.signedIn,
    account: auth.account,
    authMethod: auth.method,
    plan: auth.plan,
    quota: auth.quota,
    limitedUntil: auth.limitedUntil,
    problem: auth.problem,
  };
}

// MARK: Sign in

const DEVICE_HINT = "Sign in shows a link and a code here. Open the link on any device and enter the code.";

export const SIGN_IN: Record<BackendId, { mode: BackendSignIn["mode"]; args: string[]; hint: string }> = {
  copilot: { mode: "deviceCode", args: ["login", "--device-code"], hint: DEVICE_HINT },
  codex: { mode: "deviceCode", args: ["login", "--device-auth"], hint: DEVICE_HINT },
  claude: {
    mode: "terminal",
    args: ["auth", "login"],
    hint: "Claude Code finishes its sign-in in its own terminal, so Sign in opens a terminal window for it.",
  },
  agy: {
    mode: "terminal",
    args: [],
    hint: "Antigravity signs in only in its own interactive mode, so Sign in opens agy in a terminal window.",
  },
};

function signInBase(id: BackendId): BackendSignIn {
  const { mode, args, hint } = SIGN_IN[id];
  return { mode, command: [id, ...args].join(" "), hint };
}

/** A running device sign-in, as `spawn` returns it. */
export interface SignInProcess {
  pid?: number;
  stdout: { on(event: "data", listener: (data: Buffer | string) => void): unknown } | null;
  stderr: { on(event: "data", listener: (data: Buffer | string) => void): unknown } | null;
  on(event: "close", listener: (code: number | null) => void): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
  kill(signal?: NodeJS.Signals): boolean;
}

export function spawnSignInProcess(spec: CommandSpec, args: string[]): SignInProcess {
  return spawn(spec.executable, [...spec.prefixArgs, ...args], {
    cwd: homedir(),
    env: { ...process.env, NO_COLOR: "1" },
    shell: false,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/** `cmd.exe /c start "" cmd /k <cli> <args>`: a terminal window the person signs in from. */
export function openTerminalWindow(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn("cmd.exe", ["/c", "start", "", "cmd", "/k", command, ...args], {
      detached: true,
      shell: false,
      stdio: "ignore",
      windowsHide: false,
    });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });
}

// MARK: The monitor

export interface MonitorOptions {
  /** The JSON cache in userData. */
  storePath: string;
  probe(id: BackendId): Promise<BackendProbe>;
  resolve(id: BackendId): Promise<CommandSpec | null>;
  notify(title: string, body: string): void;
  onChange?(snapshot: BackendsSnapshot): void;
  spawnSignIn?(spec: CommandSpec, args: string[]): SignInProcess;
  openTerminal?(command: string, args: string[]): Promise<void>;
  now?(): number;
  confirmDelayMs?: number;
}

interface Saved {
  probes: Partial<Record<BackendId, BackendProbe>>;
  checkedAt: Partial<Record<BackendId, string>>;
  lastSuccessAt: Partial<Record<BackendId, string>>;
  lastAuthError: Partial<Record<BackendId, { message: string; at: string }>>;
  /** The down state each backend was alerted for; cleared (with an alert) when it's back. */
  alerted: Partial<Record<BackendId, string>>;
}

function emptySaved(): Saved {
  return { probes: {}, checkedAt: {}, lastSuccessAt: {}, lastAuthError: {}, alerted: {} };
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Keeps every backend's install and sign-in current: soon after launch, every 30 minutes, after a run
 * fails with a sign-in error and on Check now. While one is signed out it's `unavailable`, so routing
 * uses a backup.
 */
export class BackendHealthMonitor {
  private saved: Saved = emptySaved();
  private statuses: BackendHealth[] = [];
  private revision = 0;
  private readonly checking = new Set<BackendId>();
  private readonly lastRecheck = new Map<BackendId, number>();
  private readonly pendingRecheck = new Map<BackendId, ReturnType<typeof setTimeout>>();
  private readonly signIns = new Map<BackendId, SignInProcess>();
  private readonly signInState = new Map<BackendId, BackendSignIn>();
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private interval: ReturnType<typeof setInterval> | undefined;
  private wake: ReturnType<typeof setTimeout> | undefined;
  private readonly now: () => number;

  constructor(private readonly options: MonitorOptions) {
    this.now = options.now ?? Date.now;
    try {
      const loaded = JSON.parse(readFileSync(options.storePath, "utf8")) as Partial<Saved>;
      const saved = emptySaved();
      for (const key of Object.keys(saved) as (keyof Saved)[]) {
        const value = loaded?.[key];
        if (value && typeof value === "object" && !Array.isArray(value)) Object.assign(saved[key], value);
      }
      this.saved = saved;
    } catch {
      // First launch, or an unreadable cache: start empty.
    }
    this.publish();
  }

  /** Checks after `firstCheckMs`, then every 30 minutes. */
  start(firstCheckMs = FIRST_CHECK_MS): void {
    this.later(firstCheckMs, () => void this.check());
    clearInterval(this.interval);
    this.interval = setInterval(() => void this.check(), CHECK_INTERVAL_MS);
  }

  stop(): void {
    clearInterval(this.interval);
    clearTimeout(this.wake);
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
    for (const child of this.signIns.values()) killTree(child);
    this.signIns.clear();
    this.pendingRecheck.clear();
  }

  snapshot(): BackendsSnapshot {
    return { backends: this.statuses, checkInterval: CHECK_INTERVAL_MS / 1000, revision: this.revision };
  }

  /** Checks `ids` (every backend by default); one already being checked isn't started twice. */
  async check(ids: BackendId[] = BACKEND_IDS): Promise<void> {
    const wanted = ids.filter((id) => BACKEND_IDS.includes(id) && !this.checking.has(id));
    if (!wanted.length) return;
    for (const id of wanted) this.checking.add(id);
    this.publish();
    await Promise.all(wanted.map((id) => this.runProbe(id)));
  }

  async perform(action: BackendsAction): Promise<BackendsSnapshot> {
    let message: string | undefined;
    if (action.action === "check") void this.check(action.id ? [action.id] : undefined);
    else if (action.action === "signIn") message = await this.signIn(action.id);
    else message = this.cancelSignIn(action.id);
    return message ? { ...this.snapshot(), message } : this.snapshot();
  }

  /** A run finished: success is remembered; a sign-in failure is remembered and checked (at most every 2 minutes). */
  runFinished(id: BackendId, exitCode: number | null, error: string | undefined, output: string): void {
    if (!BACKEND_IDS.includes(id)) return;
    const now = this.now();
    if (exitCode === 0 && !error) {
      this.saved.lastSuccessAt[id] = new Date(now).toISOString();
      this.save();
      this.publish();
      return;
    }
    if (exitCode === null && !error) return;
    const line = authFailureLine(`${output.slice(-4_000)}\n${error ?? ""}`);
    if (!line) return;
    this.saved.lastAuthError[id] = { message: line, at: new Date(now).toISOString() };
    this.save();
    this.publish();
    const last = this.lastRecheck.get(id);
    if (last !== undefined && now - last < RECHECK_AFTER_FAILURE_MS) {
      // Too soon for another check: one runs when the 2 minutes are up.
      if (!this.pendingRecheck.has(id)) {
        this.pendingRecheck.set(id, this.later(RECHECK_AFTER_FAILURE_MS - (now - last), () => this.recheck(id)));
      }
      return;
    }
    this.recheck(id);
  }

  private recheck(id: BackendId): void {
    const pending = this.pendingRecheck.get(id);
    if (pending) this.cancelLater(pending);
    this.pendingRecheck.delete(id);
    this.lastRecheck.set(id, this.now());
    void this.check([id]);
  }

  /** Starts the CLI's own sign-in: a device link and code shown in Settings, or a terminal window. */
  async signIn(id: BackendId): Promise<string> {
    const name = BACKEND_NAMES[id];
    const spec = await this.options.resolve(id).catch(() => null);
    if (!spec) return `${name} isn't installed on this PC.`;
    const base = signInBase(id);
    if (base.mode === "terminal") {
      let message: string;
      try {
        await (this.options.openTerminal ?? openTerminalWindow)(id, SIGN_IN[id].args);
        message = "Finish signing in in the terminal window.";
      } catch {
        message = `Couldn't open a terminal. Run \`${base.command}\` in one.`;
      }
      this.signInState.set(id, { ...base, message });
      for (const delay of TERMINAL_RECHECKS_MS) this.later(delay, () => void this.check([id]));
      this.publish();
      return message;
    }
    if (this.signIns.has(id)) return `The ${name} sign-in is already waiting.`;
    let child: SignInProcess;
    try {
      child = (this.options.spawnSignIn ?? spawnSignInProcess)(spec, SIGN_IN[id].args);
    } catch {
      return `Couldn't start \`${base.command}\`.`;
    }
    this.signIns.set(id, child);
    this.signInState.set(id, { ...base, startedAt: new Date(this.now()).toISOString(), message: `Starting ${name} sign-in…` });
    let output = "";
    const decoder = new StringDecoder("utf8");
    const read = (data: Buffer | string) => {
      if (this.signIns.get(id) !== child) return;
      output = (output + (typeof data === "string" ? data : decoder.write(data))).slice(-64_000);
      const found = deviceCode(output);
      const state = this.signInState.get(id) ?? base;
      if (found.url === state.url && found.code === state.code) return;
      this.signInState.set(id, {
        ...state,
        ...found,
        message: found.url ? "Open the link on any device and enter the code." : state.message,
      });
      this.publish();
    };
    child.stdout?.on("data", read);
    child.stderr?.on("data", read);
    const finished = (signedIn: boolean) => {
      if (this.signIns.get(id) !== child) return;
      this.signIns.delete(id);
      this.signInState.set(id, {
        ...base,
        message: signedIn ? `Signed in. Checking ${name}…` : `The ${name} sign-in ended without signing in.`,
      });
      this.publish();
      void this.check([id]);
    };
    child.on("close", (code) => finished(code === 0));
    child.on("error", () => finished(false));
    this.later(SIGN_IN_TIMEOUT_MS, () => {
      if (this.signIns.get(id) === child) this.cancelSignIn(id, "The sign-in timed out after 15 minutes.");
    });
    this.publish();
    return `Starting ${name} sign-in…`;
  }

  cancelSignIn(id: BackendId, message = "Sign-in cancelled."): string {
    const child = this.signIns.get(id);
    if (!child) return "No sign-in is waiting.";
    this.signIns.delete(id);
    killTree(child);
    this.signInState.set(id, { ...signInBase(id), message });
    this.publish();
    return message;
  }

  private later(delay: number, run: () => void): ReturnType<typeof setTimeout> {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      run();
    }, delay);
    this.timers.add(timer);
    return timer;
  }

  private cancelLater(timer: ReturnType<typeof setTimeout>): void {
    clearTimeout(timer);
    this.timers.delete(timer);
  }

  private async safeProbe(id: BackendId): Promise<BackendProbe> {
    try {
      return await this.options.probe(id);
    } catch (error) {
      const previous = this.saved.probes[id];
      return {
        installed: true,
        path: previous?.path,
        version: previous?.version,
        problem: `${BACKEND_NAMES[id]}'s check failed: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  }

  private async runProbe(id: BackendId): Promise<void> {
    let probe = await this.safeProbe(id);
    // One "signed out" answer is checked again before routing changes.
    if (probe.signedIn === false && this.saved.probes[id]?.signedIn !== false) {
      await sleep(this.options.confirmDelayMs ?? CONFIRM_DELAY_MS);
      probe = await this.safeProbe(id);
    }
    this.checking.delete(id);
    // Signed in: an earlier sign-in's "finish in the terminal" or "checking…" has done its job.
    if (probe.signedIn === true && !this.signIns.has(id)) this.signInState.delete(id);
    this.saved.probes[id] = probe;
    this.saved.checkedAt[id] = new Date(this.now()).toISOString();
    this.save();
    this.publish();
  }

  private compose(id: BackendId, now: number): BackendHealth {
    const probe = this.saved.probes[id];
    const name = BACKEND_NAMES[id];
    const checkedAt = this.saved.checkedAt[id];
    const lastAuthError = this.saved.lastAuthError[id];
    const status: BackendHealth = {
      id,
      name,
      state: "unknown",
      summary: "",
      quota: probe?.quota ?? [],
      checking: this.checking.has(id),
      unavailable: false,
      signIn: this.signInState.get(id) ?? signInBase(id),
    };
    const optional: Partial<BackendHealth> = {
      path: probe?.path,
      version: probe?.version,
      signedIn: probe?.signedIn,
      account: probe?.account,
      authMethod: probe?.authMethod,
      plan: probe?.plan,
      lastSuccessAt: this.saved.lastSuccessAt[id],
      lastAuthError,
      checkedAt,
      problem: probe?.problem,
    };
    for (const [key, value] of Object.entries(optional)) {
      if (value !== undefined) Object.assign(status, { [key]: value });
    }
    const limited = probe?.limitedUntil && Date.parse(probe.limitedUntil) > now ? probe.limitedUntil : undefined;
    if (!probe) {
      status.summary = status.checking ? "Checking…" : "Not checked yet";
    } else if (!probe.installed) {
      status.state = "notInstalled";
      status.summary = "Not installed on this PC";
    } else if (probe.signedIn === false) {
      status.state = "signedOut";
      status.unavailable = true;
      status.summary = "Skipped by routing: your backups run until you sign in.";
    } else if (limited) {
      status.state = "outOfQuota";
      status.limitedUntil = limited;
      status.summary = `Out of quota until ${backendTime(limited, now) ?? limited}`;
    } else if (probe.signedIn === true) {
      status.state = "ready";
      // The Account line names the account, method and plan.
      status.summary = "Signed in";
    } else {
      status.summary = probe.problem ?? "Couldn't check the sign-in";
    }
    // A sign-in error from a run newer than the last check counts until a check says otherwise.
    if (status.state === "ready" && lastAuthError && (!checkedAt || Date.parse(lastAuthError.at) > Date.parse(checkedAt))) {
      status.summary += ". A run just failed to sign in: checking again";
    }
    return status;
  }

  private publish(): void {
    const now = this.now();
    const next = BACKEND_IDS.map((id) => this.compose(id, now));
    this.reconcileAlerts(next);
    this.scheduleWake(next, now);
    if (JSON.stringify(next) === JSON.stringify(this.statuses)) return;
    this.statuses = next;
    this.revision += 1;
    this.options.onChange?.(this.snapshot());
  }

  private reconcileAlerts(statuses: BackendHealth[]): void {
    let changed = false;
    for (const status of statuses) {
      if (status.state === "signedOut" && !this.saved.alerted[status.id]) {
        this.saved.alerted[status.id] = status.state;
        changed = true;
        this.options.notify(
          `${status.name} is signed out`,
          "Cantrip uses your backups until you sign in. Open Settings › Backends to sign in.",
        );
      } else if (status.state === "ready" && this.saved.alerted[status.id]) {
        delete this.saved.alerted[status.id];
        changed = true;
        this.options.notify(`${status.name} is back`, "It's signed in again, so Cantrip uses it again.");
      }
    }
    if (changed) this.save();
  }

  /** Re-reads the state when a quota limit lifts. */
  private scheduleWake(statuses: BackendHealth[], now: number): void {
    const next = statuses
      .map((status) => (status.limitedUntil ? Date.parse(status.limitedUntil) : Number.NaN))
      .filter((time) => Number.isFinite(time) && time > now);
    clearTimeout(this.wake);
    const delay = Math.min(Math.min(...next) - now + 5_000, 2_000_000_000);
    this.wake = next.length ? setTimeout(() => this.publish(), delay) : undefined;
    this.wake?.unref?.();
  }

  private save(): void {
    try {
      mkdirSync(path.dirname(this.options.storePath), { recursive: true });
      const temporary = `${this.options.storePath}.tmp`;
      writeFileSync(temporary, JSON.stringify(this.saved), "utf8");
      renameSync(temporary, this.options.storePath);
    } catch {
      // The cache only saves a wait at startup.
    }
  }
}
