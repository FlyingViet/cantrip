// A reply's progress notes vs. its answer (`work` from the Mac): text written before the reply's last
// tool call is notes, folded into one row above the answer.

import type { RemoteWork } from "../../api/types";

/** Where each reply block starts: blank-line separated, code fences kept whole (the Mac splits the same way). */
export function replyBlockStarts(text: string): number[] {
  const starts: number[] = [];
  let offset = 0;
  let fence = "";
  let afterBlank = true;
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (fence) {
      if (trimmed.startsWith(fence)) fence = "";
      afterBlank = false;
    } else if (!trimmed) afterBlank = true;
    else {
      if (afterBlank) starts.push(offset);
      afterBlank = false;
      if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) fence = trimmed.slice(0, 3);
    }
    offset += line.length + 1;
  }
  return starts;
}

export interface WorkFold {
  notes: string;
  answer: string;
  noteBlocks: number;
  work: RemoteWork;
  /** Still running: the row shows Working and the latest note. */
  working: boolean;
}

/**
 * The reply cut at its notes, or null when there's nothing to fold (no split from the Mac, or a
 * finished run with no answer after its notes, which then show in full).
 */
export function workFold(text: string, work: RemoteWork | undefined, streaming: boolean): WorkFold | null {
  if (!work || work.noteBlocks <= 0 || !(streaming || work.hasAnswer)) return null;
  const starts = replyBlockStarts(text);
  const cut = work.noteBlocks < starts.length ? starts[work.noteBlocks] : text.length;
  const notes = text.slice(0, cut).replace(/\s+$/, "");
  const answer = text.slice(cut);
  if (!notes || (!streaming && !answer.trim())) return null;
  return { notes, answer, noteBlocks: work.noteBlocks, work, working: streaming };
}

/** "3 notes · 12 steps". */
export function workSummary(work: RemoteWork): string {
  const notes = Math.max(1, work.notes);
  return `${notes} ${notes === 1 ? "note" : "notes"} · ${work.steps} ${work.steps === 1 ? "step" : "steps"}`;
}

/** The newest note, for the row while the reply runs. */
export function latestNote(notes: string): string {
  const starts = replyBlockStarts(notes);
  return notes.slice(starts[starts.length - 1] ?? 0).trim();
}
