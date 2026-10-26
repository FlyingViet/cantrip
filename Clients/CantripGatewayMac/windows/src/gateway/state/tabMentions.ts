// @-mentions of tabs (the cross-client contract; TabMentions.swift on the Mac is the reference). Typing "@" at
// the start of a word in a composer suggests the open tabs it may point at; a picked one is sent inside the
// message text as `@[Label](cantrip-tab:<UUID>)`, so the Mac's model acts on exactly that tab. Every place that
// shows message text shows the token as "@Label". No DOM or signals here.
import type { RemoteSessionSummary } from "../api/types";

export const MENTION_SCHEME = "cantrip-tab";
export const MENTION_LABEL_LIMIT = 60;
/** How far back from the caret an "@" can start a query (characters). */
export const MENTION_QUERY_LIMIT = 48;
export const MENTION_SUGGESTION_LIMIT = 8;

/** A picked mention, kept with the composer's draft until it's sent. */
export interface TabMention {
  id: string;
  label: string;
}

/** A token found in message text; `start`/`end` are UTF-16 offsets. */
export interface ParsedMention extends TabMention {
  start: number;
  end: number;
}

const TOKEN_SOURCE = String.raw`@\[([^\[\]\n]{1,120})\]\(cantrip-tab:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)`;
/** One token at the start of a string (renderers walking text). */
export const MENTION_TOKEN_AT_START = new RegExp(`^${TOKEN_SOURCE}`);
/** Characters an "@" may follow besides whitespace: opening brackets and quotes. */
const OPENERS = "([{\"'“‘";

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function characters(text: string): string[] {
  return Array.from(graphemes.segment(text), (part) => part.segment);
}

const isWhitespace = (character: string) => /^\s/u.test(character);
const isNewline = (character: string) => /[\n\r\v\f\u0085\u2028\u2029]/u.test(character);

/** The code point ending just before `index`. */
function previousCodePoint(text: string, index: number): string {
  if (index <= 0) return "";
  const low = text.charCodeAt(index - 1);
  if (index >= 2 && low >= 0xdc00 && low <= 0xdfff) {
    const high = text.charCodeAt(index - 2);
    if (high >= 0xd800 && high <= 0xdbff) return text.slice(index - 2, index);
  }
  return text[index - 1];
}

function startsWord(text: string, index: number): boolean {
  if (index === 0) return true;
  const previous = previousCodePoint(text, index);
  return isWhitespace(previous) || OPENERS.includes(previous);
}

// MARK: Tokens

export function parseMentions(text: string): ParsedMention[] {
  const found: ParsedMention[] = [];
  for (const match of text.matchAll(new RegExp(TOKEN_SOURCE, "g"))) {
    const start = match.index ?? 0;
    found.push({ label: match[1], id: match[2].toUpperCase(), start, end: start + match[0].length });
  }
  return found;
}

/** The text as people read it: each token becomes "@Label". */
export function plainMentions(text: string): string;
export function plainMentions(text: string | undefined | null): string | undefined | null;
export function plainMentions(text: string | undefined | null): string | undefined | null {
  if (!text || !text.includes(`](${MENTION_SCHEME}:`)) return text;
  return text.replace(new RegExp(TOKEN_SOURCE, "g"), (_token, label: string) => `@${label}`);
}

/** Message text as plain runs and mentions, in order (renderers style the mentions). */
export type MentionSegment = { kind: "text"; text: string } | { kind: "mention"; label: string; id: string };

export function mentionSegments(text: string): MentionSegment[] {
  const segments: MentionSegment[] = [];
  let cursor = 0;
  for (const mention of parseMentions(text)) {
    if (mention.start > cursor) segments.push({ kind: "text", text: text.slice(cursor, mention.start) });
    segments.push({ kind: "mention", label: mention.label, id: mention.id });
    cursor = mention.end;
  }
  if (cursor < text.length || !segments.length) segments.push({ kind: "text", text: text.slice(cursor) });
  return segments;
}

/** Where to cut `text` near `limit` (UTF-16) without splitting a token: before a token the limit falls inside. */
export function mentionSafeCut(text: string, limit: number): number {
  for (const mention of parseMentions(text)) {
    if (mention.start < limit && limit < mention.end) return mention.start;
    if (mention.start >= limit) break;
  }
  return limit;
}

/** A tab title as a mention label: one line, no brackets, at most 60 characters, never empty. */
export function mentionLabel(title: string): string {
  const cleaned = title.replace(/[[\]]/g, "").split(/\s+/u).filter(Boolean).join(" ");
  const label = characters(cleaned).slice(0, MENTION_LABEL_LIMIT).join("").trim();
  return label || "tab";
}

export function mentionToken(label: string, id: string): string {
  return `@[${mentionLabel(label)}](${MENTION_SCHEME}:${id.toUpperCase()})`;
}

// MARK: Composer

/**
 * The "@query" typed just before `caret` (UTF-16 offset; end of text when omitted), or null. An "@" inside a
 * word (an email address, a handle) never starts one. `at` is the "@"'s offset.
 */
export function mentionQuery(text: string, caret: number = text.length): { at: number; query: string } | null {
  if (caret <= 0 || caret > text.length) return null;
  const at = text.lastIndexOf("@", caret - 1);
  if (at < 0) return null;
  const query = text.slice(at + 1, caret);
  if (characters(query).length > MENTION_QUERY_LIMIT) return null;
  if (!startsWord(text, at)) return null;
  if (Array.from(query).some(isNewline) || (query !== "" && isWhitespace(query))) return null;
  // Already a mention token.
  if (query.startsWith("[")) return null;
  return { at, query };
}

export interface MentionCandidate {
  id: string;
  title: string;
  workdir: string;
  parentTitle: string | null;
  isStreaming: boolean;
  needsAnswer: boolean;
  isChild: boolean;
}

/** The Mac's home folder (where a tab without a project works) and similar non-project paths. */
function isHomeFolder(path: string): boolean {
  return path === "" || path === "/" || path === "~" || /^\/(Users|home)\/[^/]+$/.test(path) || path === "/var/root";
}

/** The last path component of the tab's folder, unless it's just the home folder. */
export function mentionProject(workdir: string): string | null {
  const path = workdir.trim().replace(/\/+$/, "") || (workdir.trim().startsWith("/") ? "/" : "");
  if (isHomeFolder(path)) return null;
  const name = path.split("/").pop() ?? "";
  return name || null;
}

function sameText(a: string, b: string): boolean {
  return a.localeCompare(b, undefined, { sensitivity: "accent" }) === 0;
}

/** What helps tell tabs apart: whose child it is, its project and whether it's busy. */
export function mentionDetail(candidate: MentionCandidate): string {
  const parts: string[] = [];
  if (candidate.parentTitle) parts.push(`Child of ${candidate.parentTitle}`);
  const project = mentionProject(candidate.workdir);
  if (project && !sameText(project, candidate.title)) parts.push(project);
  if (candidate.needsAnswer) parts.push("Needs your answer");
  else if (candidate.isStreaming) parts.push("Working");
  return parts.join(" · ");
}

/** "title, child of X, project Y, working". */
export function mentionAccessibilityLabel(candidate: MentionCandidate): string {
  const parts = [candidate.title];
  if (candidate.parentTitle) parts.push(`child of ${candidate.parentTitle}`);
  const project = mentionProject(candidate.workdir);
  if (project && !sameText(project, candidate.title)) parts.push(`project ${project}`);
  if (candidate.needsAnswer) parts.push("needs your answer");
  else if (candidate.isStreaming) parts.push("working");
  return parts.join(", ");
}

/** Lowercased, diacritics folded, whitespace collapsed. */
export function normalizeMention(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").normalize("NFC").toLowerCase().split(/\s+/u).filter(Boolean).join(" ");
}

/** Tabs matching `query`, best first, then in list order; an empty query lists them all (at most 8). */
export function matchMentions<T extends Pick<MentionCandidate, "title" | "workdir">>(
  query: string, candidates: readonly T[], limit = MENTION_SUGGESTION_LIMIT,
): T[] {
  const q = normalizeMention(query);
  const words = q.split(" ").filter(Boolean);
  const scored: { score: number; index: number; candidate: T }[] = [];
  candidates.forEach((candidate, index) => {
    const title = normalizeMention(candidate.title);
    const titleWords = title.split(/[ \-_/.]/).filter(Boolean);
    let score: number;
    if (q === "" || title.startsWith(q)) score = 0;
    else if (words.length && words.every((word) => titleWords.some((part) => part.startsWith(word)))) score = 1;
    else if (title.includes(q)) score = 2;
    else {
      const project = mentionProject(candidate.workdir);
      if (project && normalizeMention(project).startsWith(q)) score = 3;
      else return;
    }
    scored.push({ score, index, candidate });
  });
  return scored.sort((a, b) => a.score - b.score || a.index - b.index).slice(0, limit).map((entry) => entry.candidate);
}

/**
 * Picks `title` for the query at `at`: "@Label " replaces text[at..<caret] (no second space when one already
 * follows); the caret goes after the space. `label` overrides the title's label (see uniqueMentionLabel).
 */
export function insertMention(title: string, at: number, caret: number, text: string, label = mentionLabel(title)): { text: string; label: string; caret: number } {
  const spaced = text[caret] === " ";
  const inserted = `@${label}${spaced ? "" : " "}`;
  return { text: text.slice(0, at) + inserted + text.slice(caret), label, caret: at + inserted.length + (spaced ? 1 : 0) };
}

/**
 * Whether the "@" at `at` starts a picked mention's "@Label" (followed by the end or a character that isn't a
 * letter, number or underscore). The list stays closed there: "@Sony TV " is itself a query that matches the pick.
 */
export function isPickedAt(at: number, text: string, picks: readonly TabMention[]): boolean {
  return picks.some((pick) => {
    const needle = `@${pick.label}`;
    if (!text.startsWith(needle, at)) return false;
    const end = at + needle.length;
    return end >= text.length || !/[\p{L}\p{N}_]/u.test(String.fromCodePoint(text.codePointAt(end)!));
  });
}

/**
 * The label for picking `candidate`: its title's label, made unique when another picked tab (a different ID)
 * already has it, since a label stands for one ID: "<label> (<project>)", else "<label> 2", "3"…
 * Re-picking the same tab keeps its label.
 */
export function uniqueMentionLabel(candidate: Pick<MentionCandidate, "id" | "title" | "workdir">, picks: readonly TabMention[]): string {
  const base = mentionLabel(candidate.title);
  const id = candidate.id.toUpperCase();
  const taken = new Set(picks.filter((pick) => pick.id.toUpperCase() !== id).map((pick) => pick.label));
  if (!taken.has(base)) return base;
  const project = mentionProject(candidate.workdir);
  if (project) {
    const withProject = suffixedLabel(base, ` (${project})`);
    if (!taken.has(withProject)) return withProject;
  }
  let number = 2;
  while (taken.has(suffixedLabel(base, ` ${number}`))) number += 1;
  return suffixedLabel(base, ` ${number}`);
}

/** `base` + `suffix` within the 60-character limit: the base is shortened, so the suffix always shows. */
function suffixedLabel(base: string, suffix: string): string {
  const room = Math.max(1, MENTION_LABEL_LIMIT - characters(suffix).length);
  return mentionLabel(characters(base).slice(0, room).join("").trim() + suffix);
}

/** The text to send: each picked mention whose "@Label" is still in the text (starting a word, ending at a word boundary) becomes a token. */
export function encodeMentions(text: string, mentions: readonly TabMention[]): string {
  let result = text;
  // Longest labels first, so "@TV" can't take the start of "@TV Remote".
  const ordered = [...mentions].sort((a, b) => characters(b.label).length - characters(a.label).length);
  for (const mention of ordered) {
    const needle = `@${mention.label}`;
    let from = 0;
    for (;;) {
      const index = result.indexOf(needle, from);
      if (index < 0) break;
      const end = index + needle.length;
      const next = end < result.length ? String.fromCodePoint(result.codePointAt(end)!) : "";
      const endsWord = next === "" || !/[\p{L}\p{N}_\[]/u.test(next);
      if (!startsWord(result, index) || !endsWord) {
        from = end;
        continue;
      }
      const token = mentionToken(mention.label, mention.id);
      result = result.slice(0, index) + token + result.slice(end);
      from = index + token.length;
    }
  }
  return result;
}

function samePick(a: TabMention, b: TabMention): boolean {
  return a.label === b.label && a.id.toUpperCase() === b.id.toUpperCase();
}

/**
 * The picks whose "@Label" is still in `text`. All picks are matched together, so "@TV" doesn't count where
 * the text says "@TV Remote" and that is picked too.
 */
export function remainingMentions(mentions: readonly TabMention[], text: string): TabMention[] {
  const encoded = encodeMentions(text, mentions);
  return mentions.filter((mention) => encoded.includes(mentionToken(mention.label, mention.id)));
}

/** `text` without `mention`: its "@Label" (and the space after each) removed; the other picks' texts stay. */
export function removeMentionText(text: string, mention: TabMention, among: readonly TabMention[]): string {
  const token = mentionToken(mention.label, mention.id);
  const picks = among.some((item) => samePick(item, mention)) ? among : [...among, mention];
  return plainMentions(encodeMentions(text, picks).split(`${token} `).join("").split(token).join(""));
}

/** Adds a pick; a pick with the same label replaces the earlier one (that "@Label" text can carry only one ID). */
export function addMention(mentions: readonly TabMention[], mention: TabMention): TabMention[] {
  return [...mentions.filter((item) => item.label !== mention.label), mention];
}

// MARK: Text from the Mac

/**
 * `value` with every string's tokens read as "@Label" (objects and arrays copied only where something changed),
 * for text the app shows but never sends back: titles derived from messages, previews, status lines, labels.
 * Keys in `skip` keep their values (transcripts keep tokens so they can be drawn as mentions).
 */
export function plainMentionsDeep<T>(value: T, skip: ReadonlySet<string> = new Set()): T {
  if (typeof value === "string") return plainMentions(value) as T;
  if (Array.isArray(value)) {
    let changed = false;
    const items = value.map((item) => {
      const next = plainMentionsDeep(item, skip);
      changed ||= next !== item;
      return next;
    });
    return (changed ? items : value) as T;
  }
  if (value && typeof value === "object") {
    let copy: Record<string, unknown> | null = null;
    for (const [key, item] of Object.entries(value)) {
      if (skip.has(key)) continue;
      const next = plainMentionsDeep(item, skip);
      if (next !== item) (copy ??= { ...(value as Record<string, unknown>) })[key] = next;
    }
    return (copy ?? value) as T;
  }
  return value;
}

/** Fields of a session that hold its conversation (drawn with mentions) or text sent back to it. */
const SESSION_CONTENT = new Set(["messages", "queued", "pendingInputs", "threadReplies"]);

/** A session from the Mac with its titles, preview, status lines and child/parent titles read as "@Label". */
export function plainSession<T extends object>(session: T): T {
  return plainMentionsDeep(session, SESSION_CONTENT);
}

// MARK: Sessions

type MentionSession = Pick<RemoteSessionSummary, "id" | "title" | "customTitle" | "workdir" | "isStreaming" | "pendingInputCount" | "parentID" | "child"> & {
  mentionable?: boolean;
};

/** Mentions are offered (and sent as tokens) only when the composing session says the Mac acts on them. */
export function supportsMentions(session: { supportsTabMentions?: boolean } | null | undefined): boolean {
  return session?.supportsTabMentions === true;
}

function sessionTitle(session: Pick<RemoteSessionSummary, "title" | "customTitle">): string {
  return plainMentions(session.customTitle?.trim() || session.title || "Tab");
}

/** The tabs a composer may suggest: `mentionable` ones in list order, except the one being written in. */
export function mentionCandidates(sessions: readonly MentionSession[], composingID: string | null): MentionCandidate[] {
  const byID = new Map(sessions.map((session) => [session.id, session]));
  return sessions.filter((session) => session.mentionable === true && session.id !== composingID).map((session) => {
    const parent = session.parentID ? byID.get(session.parentID) : undefined;
    const parentTitle = session.parentID ? (parent ? sessionTitle(parent) : session.child?.parentTitle?.trim() || null) : null;
    return {
      id: session.id,
      title: sessionTitle(session),
      workdir: session.workdir ?? "",
      parentTitle,
      isStreaming: session.isStreaming === true,
      needsAnswer: (session.pendingInputCount ?? 0) > 0,
      isChild: Boolean(session.parentID),
    };
  });
}

// MARK: Suggestions list

/** Up (-1) / Down (+1) from `current`, wrapping. */
export function moveMentionHighlight(count: number, current: number, step: 1 | -1): number {
  if (count <= 0) return -1;
  if (current < 0) return step === 1 ? 0 : count - 1;
  return (((current + step) % count) + count) % count;
}

export function mentionCountAnnouncement(count: number): string {
  return count === 1 ? "1 tab" : `${count} tabs`;
}

export function noMentionMatchText(query: string): string {
  return `No open tab matches “${query}”`;
}

/** What the list shows: rows, one info row when nothing matches, or nothing (a space with no match: plain text). */
export function mentionListState<T>(query: string, matches: readonly T[], candidateCount: number): "rows" | "empty" | "hidden" {
  if (candidateCount === 0) return "hidden";
  if (matches.length) return "rows";
  return /\s/u.test(query) ? "hidden" : "empty";
}
