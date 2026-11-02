import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../src/gateway/bridge", () => ({
  bridge: {
    key: "gateway-key", version: "test", platform: "win32", server: "", focused: true,
    status: { connected: true, route: "", message: "", server: "" },
    openSettings() {}, openExternal() {}, showLog() {}, onStatus() {}, onCommand() {}, onActive() {},
  },
  isWindows: true,
  primaryKeyLabel: "Ctrl+",
  shortcut: (keys: string) => keys,
}));

import type { TerminalSnapshot } from "../src/gateway/api/types";
import {
  applySnapshot, emptyBuffer, freshCursor, historyStep, poll, run, start, stop, terminal, terminalError, terminalPath, UNSUPPORTED,
} from "../src/gateway/state/terminal";
import { APIError } from "../src/gateway/api/client";

// Cases mirror Hermes/Tests/CantripTerminalTests.swift.

const SESSION = "00000000-0000-0000-0000-0000000000a7";

function snapshot(text: string, start: number, options: Partial<TerminalSnapshot> = {}): TerminalSnapshot {
  return {
    epoch: "e1", start, end: start + Array.from(text).length, text, reset: false, isRunning: false, agentCommandRunning: false,
    history: [], workdir: "C:/Users/me/Plexa", ...options,
  };
}

describe("terminal buffer", () => {
  it("appends by offset and never shows overlapping output twice", () => {
    let buffer = applySnapshot(emptyBuffer(), snapshot("$ ls\n", 0, { reset: true }));
    expect(buffer).toEqual({ output: "$ ls\n", epoch: "e1", end: 5 });
    buffer = applySnapshot(buffer, snapshot("a.txt\n", 5));
    buffer = applySnapshot(buffer, snapshot("ls\na.txt\nb.txt\n", 2));
    expect(buffer.output).toBe("$ ls\na.txt\nb.txt\n");
    expect(applySnapshot(buffer, snapshot("a.txt\n", 5))).toBe(buffer);
    buffer = applySnapshot(buffer, snapshot("é🙂\n", buffer.end));
    expect(buffer.end).toBe(20);
    expect(buffer.output.endsWith("é🙂\n")).toBe(true);
  });

  it("resets on clear or trim and re-reads after a gap", () => {
    let buffer = applySnapshot(emptyBuffer(), snapshot("old\n", 0, { reset: true }));
    buffer = applySnapshot(buffer, snapshot("", 0, { epoch: "e2", reset: true }));
    expect(buffer).toEqual({ output: "", epoch: "e2", end: 0 });
    buffer = applySnapshot(buffer, snapshot("kept\n", 40, { epoch: "e2" }));
    expect(buffer.epoch).toBeNull();
    buffer = applySnapshot(buffer, snapshot("kept\n", 40, { epoch: "e2", reset: true }));
    expect(buffer).toEqual({ output: "kept\n", epoch: "e2", end: 45 });
  });

  it("caps very long output", () => {
    const buffer = applySnapshot(emptyBuffer(), snapshot("a".repeat(130_000), 0, { reset: true }));
    expect(buffer.output.length).toBe(90_000);
    expect(buffer.end).toBe(130_000);
  });
});

describe("terminal history", () => {
  it("browses with Up/Down and restores the draft", () => {
    const commands = ["ls", "git status", "make test"];
    let cursor = freshCursor();
    expect(historyStep(cursor, false, commands, "gi")).toBeNull();
    const lines: string[] = [];
    for (const [backward, current] of [[true, "gi"], [true, ""], [true, ""], [true, ""], [false, ""], [false, ""], [false, ""]] as const) {
      const step = historyStep(cursor, backward, commands, current);
      if (!step) throw new Error("expected a step");
      cursor = step.cursor;
      lines.push(step.line);
    }
    expect(lines).toEqual(["make test", "git status", "ls", "ls", "git status", "make test", "gi"]);
    expect(cursor.index).toBeNull();
    expect(historyStep(cursor, true, [], "x")).toBeNull();
  });
});

describe("terminal requests", () => {
  afterEach(() => {
    stop();
    vi.unstubAllGlobals();
  });

  it("carries the client's place", () => {
    expect(terminalPath(SESSION, null, emptyBuffer())).toBe(`/api/v1/sessions/${SESSION}/terminal?from=0`);
    expect(terminalPath(SESSION, "interrupt", { output: "", epoch: "a b", end: 12 }))
      .toBe(`/api/v1/sessions/${SESSION}/terminal/interrupt?from=12&epoch=a+b`);
    expect(terminalError(new APIError("not found", 404))).toBe(UNSUPPORTED);
    expect(terminalError(new APIError("Shell commands and tools are disabled in Private Local.", 409)))
      .toBe("Shell commands and tools are disabled in Private Local.");
  });

  it("polls, runs a command once and reports older Macs", async () => {
    let text = "";
    const commands: string[] = [];
    const calls: string[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      calls.push(`${init.method} ${url}`);
      const query = new URL(url, "http://mac").searchParams;
      if (init.method === "POST") {
        const command = (JSON.parse(String(init.body)) as { command: string }).command;
        commands.push(command);
        text += `$ ${command}\n`;
      }
      const from = Number(query.get("from") ?? 0);
      const points = Array.from(text);
      const body: TerminalSnapshot = {
        epoch: "e1", start: Math.min(from, points.length), end: points.length, text: points.slice(from).join(""), reset: !query.get("epoch"),
        isRunning: false, agentCommandRunning: false, history: commands, workdir: "C:/Users/me/Plexa",
      };
      return new Response(JSON.stringify(body), { status: 200 });
    });
    start(SESSION);
    stop();
    await poll();
    expect(terminal.value.loaded).toBe(true);
    expect(terminal.value.workdir).toBe("C:/Users/me/Plexa");
    expect(await run("echo one\necho two")).toBe(false);
    expect(await run("  git status  ")).toBe(true);
    expect(commands).toEqual(["git status"]);
    expect(calls.filter((call) => call.startsWith("POST"))).toHaveLength(1);
    expect(terminal.value.buffer.output).toBe("$ git status\n");
    expect(terminal.value.history).toEqual(["git status"]);
    await poll();
    expect(terminal.value.buffer.output).toBe("$ git status\n");

    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ error: "not found" }), { status: 404 }));
    await poll();
    expect(terminal.value.error).toBe(UNSUPPORTED);
  });
});
