// Backend slash-command suggestions for the composer: when to show them, matching and ranking,
// choosing a row, and the per-session cache of GET /api/v1/sessions/<id>/commands. The same rules
// as every other Cantrip client (the host's commands contract). No DOM or signals here.
import type { BackendCommand, BackendCommandsResponse } from "../api/types";

/** Rows shown at most (the list scrolls). */
export const MAX_SUGGESTIONS = 50;
/** A cached list is refetched on the next slash entry once it's this old. */
export const COMMANDS_MAX_AGE_MS = 30_000;
/** A failed first fetch is retried on a later slash entry after this long. */
export const COMMANDS_RETRY_MS = 5_000;

/**
 * The lowercased token after "/" while the whole composer text is "/token" (no leading
 * whitespace, no whitespace or newline anywhere, no second "/" as in a path); else null.
 */
export function slashToken(text: string): string | null {
  if (!text.startsWith("/") || /\s/u.test(text)) return null;
  const token = text.slice(1);
  return token.includes("/") ? null : token.toLowerCase();
}

export interface CommandMatch {
  command: BackendCommand;
  /** 0 exact name, 1 name prefix, 2 alias prefix, 3 name contains, 4 description word prefix. */
  score: number;
  /** Position in the host's list. */
  index: number;
}

export function isUnavailable(command: BackendCommand): boolean {
  return command.availability === "unavailable";
}

const SEPARATORS = /[-_:]/g;

/** The lowest matching rule's score for a lowercased token, or null when nothing matches. */
export function matchScore(command: BackendCommand, token: string): number | null {
  if (token === "") return 1;
  const name = command.name.toLowerCase();
  if (name === token) return 0;
  if (name.startsWith(token)) return 1;
  const aliases = Array.isArray(command.aliases) ? command.aliases : [];
  if (aliases.some((alias) => typeof alias === "string" && alias.toLowerCase().startsWith(token))) return 2;
  const bare = token.replace(SEPARATORS, "");
  if (name.includes(token) || (bare !== "" && name.replace(SEPARATORS, "").includes(bare))) return 3;
  if (Array.from(token).length >= 2) {
    const description = typeof command.description === "string" ? command.description : "";
    const words = description.toLowerCase().split(/[^\p{L}\p{N}]+/u);
    if (words.some((word) => word !== "" && word.startsWith(token))) return 4;
  }
  return null;
}

/** Matching commands, unavailable ones last, then by score, then in host order (at most 50). */
export function matchCommands(commands: readonly BackendCommand[], token: string): CommandMatch[] {
  const matches: CommandMatch[] = [];
  commands.forEach((command, index) => {
    const score = matchScore(command, token);
    if (score !== null) matches.push({ command, score, index });
  });
  matches.sort((a, b) => Number(isUnavailable(a.command)) - Number(isUnavailable(b.command)) || a.score - b.score || a.index - b.index);
  return matches.slice(0, MAX_SUGGESTIONS);
}

/** The row Return chooses before any arrow key: the first, only for a typed token matching by name or alias. */
export function defaultHighlight(matches: readonly CommandMatch[], token: string): number | null {
  const first = matches[0];
  return token !== "" && first && first.score <= 2 && !isUnavailable(first.command) ? 0 : null;
}

/** Up (-1) / Down (+1) from `current`, wrapping and skipping unavailable rows; null when none can be chosen. */
export function moveHighlight(matches: readonly CommandMatch[], current: number | null, step: 1 | -1): number | null {
  const count = matches.length;
  if (!count) return null;
  let index = current ?? (step === 1 ? -1 : count);
  for (let tried = 0; tried < count; tried++) {
    index = (((index + step) % count) + count) % count;
    if (!isUnavailable(matches[index].command)) return index;
  }
  return null;
}

/** The first row that can be chosen (Tab with nothing highlighted). */
export function firstChoosable(matches: readonly CommandMatch[]): number | null {
  const index = matches.findIndex((match) => !isUnavailable(match.command));
  return index < 0 ? null : index;
}

/** Return or click sends the command right away (nothing to type after it). */
export function runsImmediately(command: BackendCommand): boolean {
  return command.requiresInput === false && !command.inputHint?.trim();
}

export interface CommandChoice {
  /** The composer's new text. When `send`, exactly what is sent. */
  text: string;
  /** Send the text now. */
  send: boolean;
  /** Open the session's model settings instead (the text is cleared). */
  openModelSettings: boolean;
}

/**
 * Choosing a row with Tab (insert only) or Return / click (insert, then send when the command
 * takes nothing after it). Unavailable rows can't be chosen (null).
 */
export function chooseCommand(command: BackendCommand, via: "tab" | "return", canOpenModelSettings: boolean): CommandChoice | null {
  if (isUnavailable(command)) return null;
  if (command.action === "modelSettings" && canOpenModelSettings) return { text: "", send: false, openModelSettings: true };
  if (via === "return" && runsImmediately(command)) return { text: command.insert.trim(), send: true, openModelSettings: false };
  return { text: command.insert, send: false, openModelSettings: false };
}

/** A row's title: the first word of what it inserts ("/plan", or "$imagegen" for a Codex skill). */
export function commandTitle(command: BackendCommand): string {
  return command.insert.trim().split(/\s+/u)[0] || `/${command.name}`;
}

/** Accessible label: "title, description, source[, note]". */
export function commandLabel(command: BackendCommand): string {
  return [commandTitle(command), command.description, command.source, command.note]
    .map((part) => part?.trim())
    .filter(Boolean)
    .join(", ");
}

/** Accessible hint for a row (unavailable rows have none; their note says why). */
export function commandHint(command: BackendCommand, canOpenModelSettings: boolean): string | null {
  if (isUnavailable(command)) return null;
  if (command.action === "modelSettings" && canOpenModelSettings) return "Opens model settings";
  return runsImmediately(command) ? "Runs the command" : "Inserts the command";
}

export function countAnnouncement(count: number): string {
  return count === 1 ? "1 command" : `${count} commands`;
}

// MARK: Cache

/** What a session's list depends on; a change means the tab's backend or folder changed. */
export interface CommandsSession {
  id: string;
  workdir?: string;
  modelSettingsRevision?: string;
  supportsBackendCommands?: boolean;
}

export interface CommandsState {
  /** The session's list; null until a fetch succeeds (or after the backend changed). */
  response: BackendCommandsResponse | null;
  /** A fetch is in flight. */
  loading: boolean;
}

interface Entry {
  response: BackendCommandsResponse | null;
  /** The backend key `response` (or the failed fetch) was for. */
  key: string;
  fetchedAt: number;
  failedAt: number | null;
  /** The fetch whose answer counts; earlier ones are dropped when they arrive. */
  pending: number | null;
}

function backendKey(session: CommandsSession): string {
  return `${session.workdir ?? ""}\n${session.modelSettingsRevision ?? ""}`;
}

/** A well-formed response, else null (treated like a failed fetch). */
export function validCommandsResponse(value: unknown): BackendCommandsResponse | null {
  const response = value as BackendCommandsResponse | null;
  if (!response || typeof response !== "object" || !Array.isArray(response.commands)) return null;
  const commands = response.commands.filter((command) =>
    command && typeof command === "object" && typeof command.name === "string" && command.name !== "" && typeof command.insert === "string");
  return commands.length === response.commands.length ? response : { ...response, commands };
}

/**
 * Lists per session id. `refresh` fetches on a session's first slash entry, when its list is
 * older than 30 s, or when its workdir / model settings changed (the old list is dropped then);
 * otherwise the cached list shows at once. A newer request for the same session supersedes older
 * ones, so a late answer never replaces a newer list.
 */
export class CommandsCache {
  private readonly entries = new Map<string, Entry>();
  private sequence = 0;
  private readonly now: () => number;
  private readonly onChange: () => void;

  constructor(
    private readonly load: (sessionID: string) => Promise<unknown>,
    options: { now?: () => number; onChange?: () => void } = {},
  ) {
    this.now = options.now ?? Date.now;
    this.onChange = options.onChange ?? (() => {});
  }

  get(sessionID: string): CommandsState | null {
    const entry = this.entries.get(sessionID);
    return entry ? { response: entry.response, loading: entry.pending !== null } : null;
  }

  /** Starts a fetch when one is due; true when it did. Sessions without `supportsBackendCommands` never fetch. */
  refresh(session: CommandsSession): boolean {
    if (session.supportsBackendCommands !== true) return false;
    const key = backendKey(session);
    const entry = this.entries.get(session.id);
    const now = this.now();
    if (entry && entry.key === key) {
      if (entry.pending !== null) return false;
      if (entry.failedAt !== null ? now - entry.failedAt < COMMANDS_RETRY_MS : now - entry.fetchedAt < COMMANDS_MAX_AGE_MS) return false;
    }
    const sequence = ++this.sequence;
    const kept = entry && entry.key === key ? entry : null;
    this.entries.set(session.id, { response: kept?.response ?? null, key, fetchedAt: kept?.fetchedAt ?? 0, failedAt: null, pending: sequence });
    this.onChange();
    let request: Promise<unknown>;
    try {
      request = this.load(session.id);
    } catch (error) {
      request = Promise.reject(error);
    }
    request.then(
      (value) => this.settle(session.id, sequence, validCommandsResponse(value)),
      () => this.settle(session.id, sequence, null),
    );
    return true;
  }

  clear(): void {
    this.entries.clear();
    this.onChange();
  }

  private settle(sessionID: string, sequence: number, response: BackendCommandsResponse | null): void {
    const entry = this.entries.get(sessionID);
    if (!entry || entry.pending !== sequence) return;
    const now = this.now();
    if (response) {
      const same = entry.response?.revision !== undefined && entry.response.revision === response.revision;
      this.entries.set(sessionID, { response: same ? entry.response : response, key: entry.key, fetchedAt: now, failedAt: null, pending: null });
    } else {
      // A failed refetch keeps the list it had; a failed first fetch shows nothing.
      this.entries.set(sessionID, { ...entry, failedAt: now, pending: null });
    }
    this.onChange();
  }
}
