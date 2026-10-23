// Reply text for the ear (ChatViewModel.speakReady / cleanForSpeech / tableRowToSpeech in the Mac's
// ChatView.swift): streamed replies are spoken a sentence or paragraph at a time, with Markdown
// rewritten so the voice reads the content instead of the symbols.

/** Per-reply state: the first row of the table being read, used to label later cells. */
export interface SpeechTableState {
  header: string[] | null;
}

/**
 * Offset just past the last sentence (`. ! ?`) or paragraph (newline) break, or null when there's
 * none yet. A sentence break inside a table row isn't a cut: a row only ships once its newline arrives.
 */
export function lastSpeakableCut(text: string): number | null {
  let cut: number | null = null;
  let lineHasPipe = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "|") lineHasPipe = true;
    if (c === "\n") {
      cut = i + 1;
      lineHasPipe = false;
    } else if (c === "." || c === "!" || c === "?") {
      if (!lineHasPipe && (i + 1 >= text.length || text[i + 1] === " " || text[i + 1] === "\n")) cut = i + 1;
    }
  }
  return cut;
}

/**
 * One Markdown table row → one spoken sentence. The first content row is remembered as the header;
 * later rows pair each cell with its column ("| High | ~75°F |" → "High: Santa Clara ~75°F.").
 * Separator rows (|---|---|) say nothing.
 */
export function tableRowToSpeech(line: string, state: SpeechTableState): string | null {
  const parts = line.split("|");
  const trimmed = line.trim();
  if (trimmed.startsWith("|") && parts.length) parts.shift();
  if (trimmed.endsWith("|") && parts.length) parts.pop();
  const cells = parts.map((part) => part.trim());
  if (!cells.length) return null;
  if (cells.every((cell) => !cell || /^[-: ]+$/.test(cell))) return null;
  const header = state.header;
  if (!header) {
    state.header = cells;
    const named = cells.filter(Boolean);
    return named.length ? `${named.join(", ")}.` : null;
  }
  const label = cells[0];
  const pieces: string[] = [];
  for (let i = 1; i < cells.length; i++) {
    if (!cells[i]) continue;
    const name = i < header.length ? header[i] : "";
    pieces.push(name ? `${name} ${cells[i]}` : cells[i]);
  }
  if (!pieces.length) return label ? `${label}.` : null;
  return `${label ? `${label}: ` : ""}${pieces.join(", ")}.`;
}

/**
 * Rewrites Markdown for the ear (the on-screen reply is untouched): table rows become labeled
 * sentences, rules and code fences are dropped, list markers and emphasis vanish, links keep their
 * title, bare URLs vanish, and →, ~ and number ranges become words.
 */
export function cleanForSpeech(source: string, state: SpeechTableState = { header: null }): string {
  const out: string[] = [];
  for (const line of source.split("\n")) {
    if ((line.match(/\|/g)?.length ?? 0) >= 2) {
      const spoken = tableRowToSpeech(line, state);
      if (spoken) out.push(spoken);
    } else {
      if (line.trim()) state.header = null;
      out.push(line);
    }
  }
  let text = out.join("\n");
  text = text.replace(/^[ \t]*(?:```|~~~).*$/gm, "");
  text = text.replace(/^\s*[-_*=·•~\s]{2,}$/gm, "");
  text = text.replace(/^\s*(?:[-*+•·‣◦]|\d{1,3}[.)])\s+/gm, "");
  text = text.replace(/^[ \t]*(?:#{1,6}|>+)[ \t]*/gm, "");
  text = text.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1");
  for (const token of ["**", "__", "*", "`", "#", ">"]) text = text.split(token).join("");
  text = text.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
  text = text.replace(/https?:\/\/\S+/g, "");
  text = text.replace(/→/g, " to ");
  text = text.replace(/~/g, "about ");
  // En-dash ranges only ("10–20 mph"): a hyphen would also catch ISO dates.
  text = text.replace(/(?<=\d)\s*–\s*(?=\d)/g, " to ");
  return text;
}

/** Hands out the newly complete sentences of a streaming reply, each once. */
export class SpeechChunker {
  private spoken = 0;
  private readonly table: SpeechTableState = { header: null };

  reset(): void {
    this.spoken = 0;
    this.table.header = null;
  }

  /** The next chunk to speak, if a sentence or paragraph finished; `force` flushes the rest. */
  next(full: string, force = false): string | null {
    if (full.length <= this.spoken) return null;
    const tail = full.slice(this.spoken);
    const cut = force ? tail.length : lastSpeakableCut(tail) ?? 0;
    if (cut <= 0) return null;
    this.spoken += cut;
    const chunk = cleanForSpeech(tail.slice(0, cut), this.table);
    return chunk.trim() ? chunk.trim() : null;
  }
}

// MARK: Reply voices

export interface VoiceLike {
  name: string;
  lang: string;
  voiceURI: string;
  default?: boolean;
}

export type VoiceQuality = "Premium" | "Natural" | "Enhanced" | "Default";

export function voiceQuality(voice: Pick<VoiceLike, "name">): VoiceQuality {
  if (/premium/i.test(voice.name)) return "Premium";
  if (/natural|neural/i.test(voice.name)) return "Natural";
  if (/enhanced/i.test(voice.name)) return "Enhanced";
  return "Default";
}

const QUALITY_RANK: Record<VoiceQuality, number> = { Premium: 3, Natural: 3, Enhanced: 2, Default: 1 };

/** English voices installed on this PC, best quality first (VoiceController.voices()). */
export function englishVoices<T extends VoiceLike>(voices: readonly T[]): T[] {
  const seen = new Set<string>();
  return voices
    .filter((voice) => /^en([-_]|$)/i.test(voice.lang) && !seen.has(voice.voiceURI) && seen.add(voice.voiceURI))
    .sort((a, b) => QUALITY_RANK[voiceQuality(b)] - QUALITY_RANK[voiceQuality(a)] || a.name.localeCompare(b.name));
}

/** The chosen voice, else the best installed English voice, else the system default. */
export function pickVoice<T extends VoiceLike>(voices: readonly T[], id: string): T | null {
  if (id) {
    const chosen = voices.find((voice) => voice.voiceURI === id);
    if (chosen) return chosen;
  }
  return englishVoices(voices)[0] ?? voices.find((voice) => voice.default) ?? voices[0] ?? null;
}

/** "Microsoft David - English (United States)" → "Microsoft David". */
export function voiceDisplayName(voice: Pick<VoiceLike, "name">): string {
  return voice.name.replace(/\s+-\s+English.*$/i, "").trim() || voice.name;
}
