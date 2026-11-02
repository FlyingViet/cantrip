import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";

// Records the terminal window Sign in opens (cmd.exe exists only on Windows); execFile stays real.
const spawnCalls = vi.hoisted((): unknown[][] => []);
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  const { EventEmitter: Emitter } = await import("node:events");
  return {
    ...actual,
    spawn: (...args: unknown[]) => {
      spawnCalls.push(args);
      const child = Object.assign(new Emitter(), { unref: () => undefined });
      setTimeout(() => child.emit("spawn"), 0);
      return child;
    },
  };
});

import {
  AUTH_TIMEOUT_MS,
  BackendHealthMonitor,
  authFailureLine,
  deviceCode,
  openTerminalWindow,
  parseAntigravityUsage,
  parseClaudeStatus,
  parseCodexLoginStatus,
  parseCopilotConfig,
  parseVersion,
  probeBackend,
  redactSecrets,
  runCommand,
  type BackendProbe,
  type CommandResult,
  type MonitorOptions,
  type ProbeDeps,
} from "../src/main/backendHealth";
import type { CommandSpec } from "../src/main/backends";
import {
  backendCheckLine,
  backendLines,
  backendOffersSignIn,
  backendShowsCode,
  backendSignInLine,
  backendStatus,
  backendSignInPending,
  parseBackendsAction,
  routeBackend,
  withHealth,
} from "../src/shared/backendHealth";
import type { BackendHealth, BackendId, BackendStatus } from "../src/shared/types";

// Scratch files live in the project (removed afterwards), not the system temp folder.
const scratch = mkdtempSync(path.join(__dirname, ".scratch-backends-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

const NOW = Date.parse("2026-11-01T20:00:00Z");
const CLI: CommandSpec = { executable: "C:\\Tools\\cli.exe", prefixArgs: [], path: "C:\\Tools\\cli.exe" };
let stores = 0;
const monitors: BackendHealthMonitor[] = [];
afterEach(() => {
  for (const monitor of monitors.splice(0)) monitor.stop();
});

function storePath(): string {
  stores += 1;
  return path.join(scratch, `backend-status-${stores}.json`);
}

function monitor(probe: (id: BackendId) => Promise<BackendProbe>, extra: Partial<MonitorOptions> = {}) {
  const alerts: string[] = [];
  const created = new BackendHealthMonitor({
    storePath: storePath(),
    probe,
    resolve: async () => CLI,
    notify: (title, body) => alerts.push(`${title} | ${body}`),
    now: () => NOW,
    confirmDelayMs: 1,
    ...extra,
  });
  monitors.push(created);
  return { monitor: created, alerts, entry: (id: BackendId) => created.snapshot().backends.find((backend) => backend.id === id)! };
}

function result(patch: Partial<CommandResult>): CommandResult {
  return { stdout: "", stderr: "", code: 0, timedOut: false, ...patch };
}

/** A `run` that answers by arguments ("--version", "auth status", ...). */
function stubRun(answers: Record<string, Partial<CommandResult>>): ProbeDeps["run"] {
  return async (_spec, args) => result(answers[args.join(" ")] ?? { code: 1, stderr: "unexpected" });
}

const signedIn: BackendProbe = { installed: true, path: CLI.path, version: "2.1.0", signedIn: true, account: "person@example.com", authMethod: "Claude account" };
const signedOut: BackendProbe = { installed: true, path: CLI.path, version: "2.1.0", signedIn: false, problem: "Claude Code isn't signed in." };

describe("reading each CLI's answer", () => {
  it("parses versions and device codes", () => {
    expect(parseVersion("2.1.0 (Claude Code)")).toBe("2.1.0");
    expect(parseVersion("codex-cli 0.46.0-alpha.2")).toBe("0.46.0");
    expect(parseVersion("no version")).toBeUndefined();
    expect(
      deviceCode("1. Open \u001b[94mhttps://github.com/login/device\u001b[0m.\n2. Enter code: \u001b[1mABCD-1234\u001b[0m"),
    ).toEqual({ url: "https://github.com/login/device", code: "ABCD-1234" });
    expect(deviceCode("Starting…")).toEqual({});
  });

  it("reads Claude Code's auth status JSON", () => {
    expect(
      parseClaudeStatus(
        JSON.stringify({ loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", email: "person@example.com", subscriptionType: "max" }),
      ),
    ).toEqual({ signedIn: true, account: "person@example.com", method: "Claude account", plan: "Max" });
    expect(parseClaudeStatus('{"loggedIn": true, "authMethod": "console"}').method).toBe("Anthropic Console");
    expect(parseClaudeStatus('{"loggedIn": true, "authMethod": "api_key"}').method).toBe("API key");
    expect(parseClaudeStatus('{"loggedIn": true, "apiProvider": "bedrock"}').method).toBe("Amazon Bedrock");
    expect(parseClaudeStatus('{"loggedIn": true, "apiProvider": "vertex"}').method).toBe("Google Vertex AI");
    expect(parseClaudeStatus('{"loggedIn": false}')).toEqual({ signedIn: false, problem: "Claude Code isn't signed in." });
    expect(parseClaudeStatus("Error: something odd happened").signedIn).toBeUndefined();
    expect(parseClaudeStatus("").problem).toBe("Claude Code didn't report its sign-in.");
  });

  it("reads Codex's login status", () => {
    expect(parseCodexLoginStatus("Logged in using ChatGPT\n")).toEqual({ signedIn: true, method: "ChatGPT" });
    expect(parseCodexLoginStatus("Logged in using an API key - sk-proj-***ABCD")).toEqual({ signedIn: true, method: "API key" });
    expect(parseCodexLoginStatus("Not logged in")).toEqual({ signedIn: false, problem: "Not logged in" });
    expect(parseCodexLoginStatus("error: config.toml is invalid").signedIn).toBeUndefined();
  });

  it("reads Copilot CLI's config, skipping its comment lines", () => {
    const config = (body: object) => `// User settings belong in settings.json.\n// This file is managed automatically.\n${JSON.stringify(body)}`;
    expect(
      parseCopilotConfig(
        config({
          loggedInUsers: [{ host: "https://github.com", kind: "oauth", login: "hubot" }, { host: "https://github.com", login: "octocat" }],
          lastLoggedInUser: { host: "https://github.com", login: "octocat" },
        }),
      ),
    ).toEqual({ signedIn: true, account: "octocat", method: "GitHub account" });
    expect(parseCopilotConfig(config({ loggedInUsers: [{ login: "octocat" }] })).account).toBe("octocat");
    expect(parseCopilotConfig(config({ loggedInUsers: [] }))).toEqual({ signedIn: false, problem: "Copilot CLI isn't signed in." });
    expect(parseCopilotConfig(config({ model: "auto" })).signedIn).toBe(false);
    expect(parseCopilotConfig(config({ loggedInUsers: [] }), { GH_TOKEN: "placeholder" }).signedIn).toBeUndefined();
    expect(
      parseCopilotConfig(config({ loggedInUsers: [] }), { COPILOT_PROVIDER_BASE_URL: "https://models.example.com" }).signedIn,
    ).toBeUndefined();
    expect(parseCopilotConfig("{ not json").signedIn).toBeUndefined();
    expect(parseCopilotConfig(null).signedIn).toBeUndefined();
  });

  it("reads Antigravity's /usage with each window's quota used and reset time", () => {
    const usage = (geminiLeft: number, claudeLeft: number) =>
      JSON.stringify({
        status: "SUCCESS",
        command: {
          data: {
            groups: [
              {
                name: "Gemini models",
                buckets: [
                  { id: "gemini-weekly", name: "Gemini weekly", window: "weekly", remaining_fraction: 0.75, reset_time: "2026-11-07T00:00:00Z" },
                  { id: "gemini-5h", window: "5h", remaining_fraction: geminiLeft, reset_time: "2026-11-01T22:00:00Z" },
                ],
              },
              { name: "Claude and GPT models", buckets: [{ window: "weekly", remaining_fraction: claudeLeft, reset_time: "2026-11-03T00:00:00Z" }] },
            ],
          },
        },
      });
    expect(parseAntigravityUsage(usage(0, 0.5))).toEqual({
      signedIn: true,
      method: "Google account",
      quota: [
        { name: "Gemini models: weekly limit", usedPercent: 25, resetsAt: "2026-11-07T00:00:00.000Z" },
        { name: "Gemini models: 5-hour limit", usedPercent: 100, resetsAt: "2026-11-01T22:00:00.000Z" },
        { name: "Claude and GPT models: weekly limit", usedPercent: 50, resetsAt: "2026-11-03T00:00:00.000Z" },
      ],
    });
    // Every model group used up: the account is out of quota until the first group comes back.
    expect(parseAntigravityUsage(usage(0, 0)).limitedUntil).toBe("2026-11-01T22:00:00.000Z");
    expect(parseAntigravityUsage('{"status": "ERROR", "error": "User is not logged in"}')).toEqual({
      signedIn: false,
      problem: "User is not logged in",
    });
    expect(parseAntigravityUsage('{"status": "UNAUTHENTICATED"}').signedIn).toBe(false);
    expect(parseAntigravityUsage("", "Error: not signed in. Run agy to sign in.").signedIn).toBe(false);
    expect(parseAntigravityUsage('{"status": "ERROR", "error": "network unreachable"}')).toEqual({ problem: "network unreachable" });
    expect(parseAntigravityUsage("").signedIn).toBeUndefined();
  });

  it("finds a sign-in failure in a run's output without keeping keys", () => {
    expect(authFailureLine("Working…\nInvalid API key · Please run /login\n")).toBe("Invalid API key · Please run /login");
    expect(authFailureLine("API Error: 401 authentication_error: OAuth token has expired")).toContain("authentication_error");
    expect(authFailureLine("Error: 401 Unauthorized")).toBe("Error: 401 Unauthorized");
    expect(authFailureLine("All tests passed")).toBeNull();
    const key = `sk-ant-api03-${"A".repeat(40)}`;
    expect(authFailureLine(`invalid api key: ${key}`)).toBe("invalid api key: [redacted]");
    expect(redactSecrets(`Authorization: Bearer ${"x".repeat(30)} and ghp_${"b".repeat(36)}`)).toBe(
      "Authorization: Bearer [redacted] and [redacted]",
    );
  });
});

describe("checking a backend", () => {
  it("reports a signed-in CLI's path, version, account and method", async () => {
    const run = stubRun({
      "--version": { stdout: "2.1.0 (Claude Code)\n" },
      "auth status": { stdout: JSON.stringify({ loggedIn: true, authMethod: "claude.ai", email: "person@example.com", subscriptionType: "pro" }) },
    });
    expect(await probeBackend("claude", { resolve: async () => CLI, run, home: "C:\\Users\\octocat" })).toEqual({
      installed: true,
      path: CLI.path,
      version: "2.1.0",
      signedIn: true,
      account: "person@example.com",
      authMethod: "Claude account",
      plan: "Pro",
      quota: undefined,
      limitedUntil: undefined,
      problem: undefined,
    });
  });

  it("reads Codex's and Antigravity's own commands, which spend no quota", async () => {
    const run = vi.fn(stubRun({
      "--version": { stdout: "codex-cli 0.46.0" },
      "login status": { stderr: "Not logged in", code: 1 },
      "-p /usage --output-format json": { stdout: '{"status":"SUCCESS","command":{"data":{"groups":[]}}}' },
    }));
    const codex = await probeBackend("codex", { resolve: async () => CLI, run, home: "C:\\Users\\octocat" });
    expect(codex).toMatchObject({ installed: true, version: "0.46.0", signedIn: false });
    const agy = await probeBackend("agy", { resolve: async () => CLI, run, home: "C:\\Users\\octocat" });
    expect(agy).toMatchObject({ signedIn: true, authMethod: "Google account", quota: [] });
    expect(run.mock.calls.map(([, args, timeout]) => [args.join(" "), timeout])).toEqual([
      ["--version", 20_000],
      ["login status", AUTH_TIMEOUT_MS],
      ["--version", 20_000],
      ["-p /usage --output-format json", 45_000],
    ]);
  });

  it("reads Copilot's sign-in from its config folder", async () => {
    const home = mkdtempSync(path.join(scratch, "home-"));
    const run = stubRun({ "--version": { stdout: "GitHub Copilot CLI 1.0.105" } });
    const deps = { resolve: async () => CLI, run, home };
    // No config yet: it can't tell, so routing keeps the backend.
    const unread = await probeBackend("copilot", deps);
    expect(unread).toMatchObject({ installed: true, version: "1.0.105", problem: expect.any(String) });
    expect(unread.signedIn).toBeUndefined();
    const folder = path.join(home, ".copilot");
    mkdirSync(folder);
    writeFileSync(
      path.join(folder, "config.json"),
      '// Managed by Copilot CLI\n{"loggedInUsers":[{"host":"https://github.com","kind":"oauth","login":"octocat"}],"lastLoggedInUser":{"login":"octocat"}}',
    );
    expect(await probeBackend("copilot", deps)).toMatchObject({ signedIn: true, account: "octocat", authMethod: "GitHub account" });
    writeFileSync(path.join(folder, "config.json"), '// Managed by Copilot CLI\n{"loggedInUsers":[]}');
    expect(await probeBackend("copilot", deps)).toMatchObject({ signedIn: false });
    // Copilot can fall back to the GitHub CLI's sign-in, so that's not called signed out.
    const viaGitHubCli = await probeBackend("copilot", { ...deps, githubCliSignedIn: async () => true });
    expect(viaGitHubCli.signedIn).toBeUndefined();
    expect(viaGitHubCli.problem).toContain("GitHub CLI");
    expect(await probeBackend("copilot", { ...deps, githubCliSignedIn: async () => false })).toMatchObject({ signedIn: false });
  });

  it("calls a slow CLI unknown, never signed out", async () => {
    const run = stubRun({ "--version": { stdout: "2.1.0" }, "auth status": { timedOut: true, code: null } });
    const probe = await probeBackend("claude", { resolve: async () => CLI, run, home: "C:\\Users\\octocat" });
    expect(probe.signedIn).toBeUndefined();
    expect(probe.problem).toBe("Claude Code didn't answer within 45 s.");

    const { monitor: checks, entry, alerts } = monitor(async () => probe);
    await checks.check(["claude"]);
    expect(entry("claude")).toMatchObject({ state: "unknown", unavailable: false, summary: "Claude Code didn't answer within 45 s." });
    expect(backendOffersSignIn(entry("claude"))).toBe(true);
    expect(alerts).toEqual([]);
  });

  it("calls a missing CLI not installed", async () => {
    expect(await probeBackend("codex", { resolve: async () => null, run: stubRun({}), home: "C:\\" })).toEqual({ installed: false });
    const { monitor: checks, entry } = monitor((id) => probeBackend(id, { resolve: async () => null, run: stubRun({}), home: "C:\\" }));
    await checks.check();
    const codex = entry("codex");
    expect(codex).toMatchObject({ state: "notInstalled", summary: "Not installed on this PC", unavailable: false });
    expect(backendOffersSignIn(codex)).toBe(false);
    expect(backendLines(codex, "on this PC", NOW).map((line) => line.text)).toContain("Install Codex on this PC to use it.");
  });

  it("stops a command at its time limit", async () => {
    const node = { executable: process.execPath, prefixArgs: [] };
    const started = Date.now();
    const slow = await runCommand(node, ["-e", "setTimeout(() => {}, 20000)"], 300);
    expect(slow.timedOut).toBe(true);
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(await runCommand(node, ["-e", "console.log('codex-cli 0.46.0')"], 10_000)).toMatchObject({
      stdout: "codex-cli 0.46.0\n",
      code: 0,
      timedOut: false,
    });
    expect((await runCommand({ executable: path.join(scratch, "missing-cli"), prefixArgs: [] }, ["--version"], 5_000)).error).toBe("ENOENT");
  });
});

describe("the backend monitor", () => {
  it("confirms a sign-out with a second check before routing skips the backend", async () => {
    const probe = vi.fn(async () => signedOut);
    const { monitor: checks, entry, alerts } = monitor(probe);
    await checks.check(["claude"]);
    expect(probe).toHaveBeenCalledTimes(2);
    expect(entry("claude")).toMatchObject({
      state: "signedOut",
      unavailable: true,
      summary: "Skipped by routing: your backups run until you sign in.",
      checkedAt: new Date(NOW).toISOString(),
    });
    expect(alerts).toEqual([
      "Claude Code is signed out | Cantrip uses your backups until you sign in. Open Settings › Backends to sign in.",
    ]);
    // The label is the state alone: the summary says routing skips it.
    expect(backendStatus(entry("claude"))).toEqual({ text: "Signed out", tone: "warning" });
    expect(backendLines(entry("claude"), "on this PC", NOW)[0].text).toBe(
      "Skipped by routing: your backups run until you sign in.",
    );
    // Already signed out: the next answer counts at once.
    await checks.check(["claude"]);
    expect(probe).toHaveBeenCalledTimes(3);
  });

  it("ignores one signed-out answer the second check contradicts", async () => {
    const probe = vi.fn().mockResolvedValueOnce(signedOut).mockResolvedValue(signedIn);
    const { monitor: checks, entry, alerts } = monitor(probe);
    await checks.check(["claude"]);
    expect(probe).toHaveBeenCalledTimes(2);
    expect(entry("claude")).toMatchObject({
      state: "ready",
      unavailable: false,
      summary: "Signed in",
      account: "person@example.com",
      authMethod: "Claude account",
    });
    expect(alerts).toEqual([]);
  });

  it("alerts once when a backend goes down, not while it stays down, and once when it's back", async () => {
    let answer = signedIn;
    const store = storePath();
    const first = monitor(async () => answer, { storePath: store });
    await first.monitor.check(["claude"]);
    answer = signedOut;
    await first.monitor.check(["claude"]);
    await first.monitor.check(["claude"]);
    expect(first.alerts).toEqual([
      "Claude Code is signed out | Cantrip uses your backups until you sign in. Open Settings › Backends to sign in.",
    ]);
    first.monitor.stop();

    // A restart remembers the alert (and the cached result: no check needed to show it).
    const second = monitor(async () => answer, { storePath: store });
    expect(second.entry("claude")).toMatchObject({ state: "signedOut", unavailable: true });
    await second.monitor.check(["claude"]);
    expect(second.alerts).toEqual([]);
    answer = signedIn;
    await second.monitor.check(["claude"]);
    await second.monitor.check(["claude"]);
    expect(second.alerts).toEqual(["Claude Code is back | It's signed in again, so Cantrip uses it again."]);
  });

  it("shows Checking… at once and the result when the check ends", async () => {
    let finish: (probe: BackendProbe) => void = () => undefined;
    const changes: boolean[] = [];
    const { monitor: checks, entry } = monitor(() => new Promise((resolve) => (finish = resolve)), {
      onChange: (snapshot) => changes.push(snapshot.backends.find((backend) => backend.id === "codex")!.checking),
    });
    expect(checks.snapshot().backends.map((backend) => backend.name)).toEqual(["Claude Code", "Copilot CLI", "Codex", "Antigravity"]);
    const snapshot = await checks.perform({ action: "check", id: "codex" });
    expect(snapshot.backends.find((backend) => backend.id === "codex")?.checking).toBe(true);
    expect(backendStatus(entry("codex"))).toEqual({ text: "Checking…", tone: "" });
    expect(backendCheckLine(entry("codex"))).toBe("Checking…");
    finish({ ...signedIn, account: undefined, authMethod: "ChatGPT" });
    await vi.waitFor(() => expect(entry("codex").checking).toBe(false));
    expect(entry("codex").state).toBe("ready");
    expect(backendStatus(entry("codex"))).toEqual({ text: "Ready", tone: "" });
    expect(entry("codex").summary).toBe("Signed in");
    expect(backendLines(entry("codex"), "on this PC", NOW).map((line) => line.text)).toContain("Account: ChatGPT");
    expect(backendCheckLine(entry("codex"), NOW)).toMatch(/^Checked /);
    expect(changes.slice(-2)).toEqual([true, false]);
  });

  it("records a successful run and a sign-in failure, rechecking at most every 2 minutes", async () => {
    let clock = NOW;
    const probe = vi.fn(async () => signedIn);
    const { monitor: checks, entry } = monitor(probe, { now: () => clock });
    checks.runFinished("claude", 0, undefined, "Done.");
    expect(entry("claude").lastSuccessAt).toBe(new Date(NOW).toISOString());
    checks.runFinished("claude", null, undefined, "Stopped by the person");
    checks.runFinished("claude", 1, undefined, "Tests failed: 3 of 10");
    expect(entry("claude").lastAuthError).toBeUndefined();
    expect(probe).not.toHaveBeenCalled();

    clock += 1_000;
    checks.runFinished("claude", 1, undefined, "API Error: 401 {\"type\":\"authentication_error\"}\nPlease run /login");
    expect(entry("claude").lastAuthError).toEqual({
      message: 'API Error: 401 {"type":"authentication_error"}',
      at: new Date(clock).toISOString(),
    });
    await vi.waitFor(() => expect(entry("claude").checking).toBe(false));
    expect(probe).toHaveBeenCalledTimes(1);
    clock += 60_000;
    checks.runFinished("claude", 1, undefined, "Invalid API key · Please run /login");
    expect(probe).toHaveBeenCalledTimes(1);
    clock += 61_000;
    checks.runFinished("claude", 1, undefined, "Invalid API key · Please run /login");
    await vi.waitFor(() => expect(probe).toHaveBeenCalledTimes(2));
    const lines = backendLines(entry("claude"), "on this PC", clock).map((line) => line.text);
    expect(lines.some((line) => line.startsWith("Last sign-in error: Invalid API key · Please run /login ("))).toBe(true);
    expect(lines.some((line) => line.startsWith("Last successful run: "))).toBe(true);
  });

  it("checks when the 2 minutes are up after a sign-in failure it couldn't check at once", async () => {
    vi.useFakeTimers();
    try {
      let clock = NOW;
      const probe = vi.fn(async () => signedIn);
      const { monitor: checks } = monitor(probe, { now: () => clock });
      checks.runFinished("codex", 1, undefined, "Error: 401 Unauthorized");
      await vi.advanceTimersByTimeAsync(0);
      expect(probe).toHaveBeenCalledTimes(1);
      clock += 60_000;
      checks.runFinished("codex", 1, undefined, "Error: 401 Unauthorized");
      checks.runFinished("codex", 1, undefined, "Error: 401 Unauthorized");
      await vi.advanceTimersByTimeAsync(59_000);
      expect(probe).toHaveBeenCalledTimes(1);
      clock += 60_000;
      await vi.advanceTimersByTimeAsync(1_000);
      expect(probe).toHaveBeenCalledTimes(2);
      await vi.advanceTimersByTimeAsync(10 * 60_000);
      expect(probe).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows a device sign-in's link and code, and Cancel stops it", async () => {
    class FakeProcess extends EventEmitter {
      stdout = new EventEmitter();
      stderr = new EventEmitter();
      killed = false;
      kill(): boolean {
        this.killed = true;
        this.emit("close", null);
        return true;
      }
    }
    const children: FakeProcess[] = [];
    const spawned: string[][] = [];
    const probe = vi.fn(async () => signedOut);
    const { monitor: checks, entry } = monitor(probe, {
      spawnSignIn: (_spec, args) => {
        spawned.push(args);
        const child = new FakeProcess();
        children.push(child);
        return child;
      },
    });
    expect(await checks.signIn("codex")).toBe("Starting Codex sign-in…");
    expect(spawned).toEqual([["login", "--device-auth"]]);
    expect(backendSignInPending(entry("codex"))).toBe(true);
    children[0].stdout.emit(
      "data",
      Buffer.from("1. Open \u001b[94mhttps://auth.example.com/codex/device\u001b[0m\n2. Enter this one-time code \u001b[94mWXYZ-12345\u001b[0m\n"),
    );
    expect(entry("codex").signIn).toMatchObject({
      mode: "deviceCode",
      command: "codex login --device-auth",
      url: "https://auth.example.com/codex/device",
      code: "WXYZ-12345",
      message: "Open the link on any device and enter the code.",
    });
    // The code box carries the instructions, so the row has no separate sign-in line.
    expect(backendShowsCode(entry("codex"))).toBe(true);
    expect(backendSignInLine(entry("codex"))).toBeNull();
    expect(await checks.signIn("codex")).toBe("The Codex sign-in is already waiting.");
    const cancelled = await checks.perform({ action: "cancelSignIn", id: "codex" });
    expect(cancelled.message).toBe("Sign-in cancelled.");
    expect(children[0].killed).toBe(true);
    expect(entry("codex").signIn.url).toBeUndefined();
    expect(backendSignInPending(entry("codex"))).toBe(false);
    expect(backendSignInLine(entry("codex"))).toBe("Sign-in cancelled.");
    expect(probe).not.toHaveBeenCalled();

    expect(await checks.signIn("copilot")).toBe("Starting Copilot CLI sign-in…");
    expect(spawned[1]).toEqual(["login", "--device-code"]);
    children[1].emit("close", 0);
    expect(entry("copilot").signIn.message).toBe("Signed in. Checking Copilot CLI…");
    await vi.waitFor(() => expect(probe).toHaveBeenCalled());
  });

  it("opens a terminal window for Claude Code and Antigravity", async () => {
    const opened: string[][] = [];
    let answer = signedOut;
    const { monitor: checks, entry } = monitor(async () => answer, {
      openTerminal: async (command, args) => {
        opened.push([command, ...args]);
      },
    });
    await checks.check(["claude"]);
    // Before Sign in: the terminal hint; after it, the sign-in's own message in its place.
    expect(backendSignInLine(entry("claude"))).toBe(entry("claude").signIn.hint);
    expect(entry("claude").signIn.hint).toContain("terminal window");
    expect(await checks.signIn("claude")).toBe("Finish signing in in the terminal window.");
    expect(backendSignInLine(entry("claude"))).toBe("Finish signing in in the terminal window.");
    expect(await checks.signIn("agy")).toBe("Finish signing in in the terminal window.");
    expect(opened).toEqual([["claude", "auth", "login"], ["agy"]]);
    expect(entry("claude").signIn).toMatchObject({ mode: "terminal", command: "claude auth login", message: "Finish signing in in the terminal window." });
    expect(entry("agy").signIn.hint).toContain("terminal window");
    // Once a check finds it signed in, the finished sign-in's message goes.
    answer = signedIn;
    await checks.check(["claude"]);
    expect(entry("claude").signIn.message).toBeUndefined();
    expect(backendSignInLine(entry("claude"))).toBeNull();
    const none = monitor(async () => signedOut, { resolve: async () => null });
    expect(await none.monitor.signIn("claude")).toBe("Claude Code isn't installed on this PC.");

    spawnCalls.length = 0;
    await openTerminalWindow("claude", ["auth", "login"]);
    expect(spawnCalls).toEqual([
      [
        "cmd.exe",
        ["/c", "start", "", "cmd", "/k", "claude", "auth", "login"],
        { detached: true, shell: false, stdio: "ignore", windowsHide: false },
      ],
    ]);
  });
});

describe("routing and Settings requests", () => {
  const statuses: BackendStatus[] = [
    { id: "claude", label: "Claude Code", available: true, detail: "C:\\Tools\\claude.exe" },
    { id: "copilot", label: "GitHub Copilot", available: true, detail: "C:\\Tools\\copilot.cmd" },
    { id: "codex", label: "OpenAI Codex", available: false, detail: "codex was not found on PATH" },
    { id: "agy", label: "Google Antigravity", available: true, detail: "C:\\Tools\\agy.exe" },
  ];
  const health = (id: BackendId, unavailable: boolean) => ({ id, unavailable }) as Pick<BackendHealth, "id" | "unavailable">;

  it("skips a signed-out backend and uses the next one as its backup", () => {
    const routed = withHealth(statuses, [health("claude", true), health("copilot", false)]);
    expect(routed[0]).toEqual({
      id: "claude",
      label: "Claude Code",
      available: false,
      detail: "Claude Code is signed out. Sign in from Settings › Backends.",
    });
    expect(routeBackend("claude", routed)).toBe("copilot");
    expect(routeBackend("agy", routed)).toBe("agy");
    expect(routeBackend("claude", withHealth(statuses, [health("claude", false)]))).toBe("claude");
    expect(routeBackend(null, statuses)).toBe("claude");
    expect(routeBackend("claude", statuses.map((status) => ({ ...status, available: false })))).toBeNull();
  });

  it("shows `problem` only when a check couldn't tell, and only when the summary doesn't already say it", async () => {
    const { monitor: checks, entry } = monitor(async (id) =>
      id === "claude" ? { ...signedOut } : id === "codex" ? { ...signedIn, problem: "Not logged in" } : { installed: true, problem: "Antigravity didn't answer within 45 s." },
    );
    await checks.check();
    const problems = (id: BackendId) => backendLines(entry(id), "on this PC", NOW).filter((line) => line.key === "problem");
    expect(entry("claude").state).toBe("signedOut");
    expect(problems("claude")).toEqual([]);
    expect(entry("codex").state).toBe("ready");
    expect(problems("codex")).toEqual([]);
    // Unknown: the summary is the problem, so it isn't repeated.
    expect(entry("agy")).toMatchObject({ state: "unknown", summary: "Antigravity didn't answer within 45 s." });
    expect(problems("agy")).toEqual([]);
    const differs = backendLines({ ...entry("agy"), summary: "Couldn't check the sign-in" }, "on this PC", NOW);
    expect(differs.filter((line) => line.key === "problem").map((line) => line.text)).toEqual([
      "Antigravity didn't answer within 45 s.",
    ]);
  });

  it("accepts only Check now, Sign in and Cancel for a known backend", () => {
    expect(parseBackendsAction({ action: "check" })).toEqual({ action: "check" });
    expect(parseBackendsAction({ action: "check", id: "agy" })).toEqual({ action: "check", id: "agy" });
    expect(parseBackendsAction({ id: "codex", action: "signIn" })).toEqual({ action: "signIn", id: "codex" });
    expect(parseBackendsAction({ action: "cancelSignIn", id: "copilot" })).toEqual({ action: "cancelSignIn", id: "copilot" });
    expect(parseBackendsAction({ action: "signIn" })).toBeNull();
    expect(parseBackendsAction({ action: "signIn", id: "antigravity" })).toBeNull();
    expect(parseBackendsAction({ action: "signOut", id: "codex" })).toBeNull();
    expect(parseBackendsAction({ action: "check", id: "claude", command: "calc.exe" })).toBeNull();
    expect(parseBackendsAction(["check"])).toBeNull();
    expect(parseBackendsAction(null)).toBeNull();
  });
});
