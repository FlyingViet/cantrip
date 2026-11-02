// A tab's terminal (CantripTerminal.swift): the Mac's persistent shell for the tab, the same one as the
// Cantrip panel's terminal mode. Polled every 0.4 s while a command runs and 1.5 s otherwise, only while
// the pane is open; replies apply by offset so a poll and a command's reply never show output twice.
import { signal } from "@preact/signals";
import { api, APIError, pathComponent } from "../api/client";
import type { TerminalSnapshot } from "../api/types";

export const MAX_OUTPUT = 120_000;
export const UNSUPPORTED = "Update Cantrip on the Mac to use the terminal from here.";

export interface TerminalBuffer {
  output: string;
  /** Null asks the Mac for everything it kept (first read, or after a gap). */
  epoch: string | null;
  /** The Mac's offset just after `output` (Unicode code points); the next poll reads from here. */
  end: number;
}

export const emptyBuffer = (): TerminalBuffer => ({ output: "", epoch: null, end: 0 });

export function applySnapshot(buffer: TerminalBuffer, snapshot: TerminalSnapshot): TerminalBuffer {
  let next: TerminalBuffer;
  if (snapshot.reset || snapshot.epoch !== buffer.epoch) {
    next = { output: snapshot.text, epoch: snapshot.epoch, end: snapshot.end };
  } else if (snapshot.end <= buffer.end) {
    return buffer;
  } else if (snapshot.start > buffer.end) {
    return { ...buffer, epoch: null };
  } else {
    const fresh = Array.from(snapshot.text).slice(buffer.end - snapshot.start).join("");
    next = { output: buffer.output + fresh, epoch: buffer.epoch, end: snapshot.end };
  }
  if (next.output.length > MAX_OUTPUT) next = { ...next, output: next.output.slice(next.output.length - (MAX_OUTPUT * 3) / 4) };
  return next;
}

/** Up/Down through the commands the shell has run, keeping the draft typed before browsing. */
export interface HistoryCursor {
  index: number | null;
  draft: string;
}

export const freshCursor = (): HistoryCursor => ({ index: null, draft: "" });

/** The command line after Up (`backward`) or Down, or null when it doesn't change. */
export function historyStep(cursor: HistoryCursor, backward: boolean, history: string[], current: string): { cursor: HistoryCursor; line: string } | null {
  if (!history.length) return null;
  if (backward) {
    const index = cursor.index === null ? history.length - 1 : Math.max(0, Math.min(cursor.index, history.length) - 1);
    return { cursor: { index, draft: cursor.index === null ? current : cursor.draft }, line: history[index] };
  }
  if (cursor.index === null) return null;
  if (cursor.index < history.length - 1) return { cursor: { ...cursor, index: cursor.index + 1 }, line: history[cursor.index + 1] };
  return { cursor: freshCursor(), line: cursor.draft };
}

export function terminalPath(sessionID: string, action: string | null, buffer: TerminalBuffer): string {
  const query = new URLSearchParams({ from: String(buffer.end) });
  if (buffer.epoch) query.set("epoch", buffer.epoch);
  return `/api/v1/sessions/${pathComponent(sessionID)}/terminal${action ? `/${pathComponent(action)}` : ""}?${query}`;
}

export function terminalError(error: unknown): string {
  if (error instanceof APIError && (error.status === 404 || error.status === 405)) return UNSUPPORTED;
  return (error as Error).message || "The terminal couldn't reach the Mac.";
}

export interface TerminalState {
  sessionID: string | null;
  buffer: TerminalBuffer;
  isRunning: boolean;
  agentCommandRunning: boolean;
  history: string[];
  workdir: string;
  error: string | null;
  loaded: boolean;
  sending: boolean;
}

const initial = (sessionID: string | null): TerminalState => ({
  sessionID, buffer: emptyBuffer(), isRunning: false, agentCommandRunning: false, history: [], workdir: "", error: null, loaded: false, sending: false,
});

export const terminal = signal<TerminalState>(initial(null));
let timer: ReturnType<typeof setTimeout> | null = null;
let generation = 0;

export const isBusy = (state: TerminalState): boolean => state.isRunning || state.agentCommandRunning;

function apply(sessionID: string, snapshot: TerminalSnapshot): void {
  const state = terminal.value;
  if (state.sessionID !== sessionID) return;
  terminal.value = {
    ...state, buffer: applySnapshot(state.buffer, snapshot), isRunning: snapshot.isRunning,
    agentCommandRunning: snapshot.agentCommandRunning, history: snapshot.history, workdir: snapshot.workdir, error: null, loaded: true,
  };
}

function fail(sessionID: string, error: unknown): void {
  if (terminal.value.sessionID === sessionID) terminal.value = { ...terminal.value, error: terminalError(error) };
}

export async function poll(): Promise<void> {
  const { sessionID, buffer } = terminal.value;
  if (!sessionID) return;
  try {
    apply(sessionID, await api<TerminalSnapshot>(terminalPath(sessionID, null, buffer)));
  } catch (error) {
    fail(sessionID, error);
  }
}

/** Shows `sessionID`'s terminal and keeps it current until `stop()`. */
export function start(sessionID: string): void {
  if (terminal.value.sessionID !== sessionID) {
    stop();
    terminal.value = initial(sessionID);
  }
  if (timer !== null) return;
  const run = ++generation;
  const tick = async () => {
    await poll();
    if (run !== generation) return;
    const state = terminal.value;
    timer = setTimeout(() => void tick(), state.error ? 4000 : isBusy(state) ? 400 : 1500);
  };
  timer = setTimeout(() => void tick(), 0);
}

export function stop(): void {
  generation++;
  if (timer !== null) clearTimeout(timer);
  timer = null;
}

async function send(action: string | null, body: Record<string, string>): Promise<boolean> {
  const { sessionID, buffer, sending } = terminal.value;
  if (!sessionID || sending) return false;
  terminal.value = { ...terminal.value, sending: true };
  try {
    apply(sessionID, await api<TerminalSnapshot>(terminalPath(sessionID, action, buffer), { method: "POST", body }));
    return true;
  } catch (error) {
    fail(sessionID, error);
    return false;
  } finally {
    if (terminal.value.sessionID === sessionID) terminal.value = { ...terminal.value, sending: false };
  }
}

/** Runs one line in the tab's shell (while a command runs, the line is its input); true when the Mac took it. */
export function run(command: string): Promise<boolean> {
  const line = command.trim();
  if (!line || /[\r\n]/.test(line)) return Promise.resolve(false);
  return send(null, { command: line });
}

/** Control-C: stops the running command (or the agent, when only its command runs). */
export const interrupt = (): Promise<boolean> => send("interrupt", {});
export const clear = (): Promise<boolean> => send("clear", {});
export const restart = (): Promise<boolean> => send("restart", {});
