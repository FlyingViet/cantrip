// Delete Message: a prompt's, reply's or error's menu deletes that whole exchange on the Mac after asking. Sessions
// list what was deleted (from any device) in `deletedMessageIDs`, and every cached copy drops those messages:
// the transcript, older pages and fetched threads.
import type { RemoteMessage, RemoteSessionSummary } from "../api/types";

export const DELETE_MESSAGE_LABEL = "Delete Message…";

/** The same wording on every platform. */
export const DELETE_MESSAGE_CONFIRMATION = {
  title: "Delete this message?",
  message: "This removes the message and its reply from this tab's history on the Mac, and the model won't have them anymore. This can't be undone.",
  confirm: "Delete",
  cancel: "Cancel",
  destructive: true,
} as const;

const DELETABLE_ROLES: ReadonlySet<string> = new Set(["user", "assistant", "error"]);

/** Prompts, replies and errors, when the Mac offers it and the tab isn't working; never dividers or handoff/child cards. */
export function canDeleteMessage(
  session: Pick<RemoteSessionSummary, "supportsDeleteMessage" | "isStreaming">,
  message: Pick<RemoteMessage, "role" | "childResult" | "handoffResult">,
): boolean {
  return session.supportsDeleteMessage === true && !session.isStreaming && DELETABLE_ROLES.has(message.role)
    && !message.childResult && !message.handoffResult;
}

/** UUIDs compare case-insensitively (the Mac sends them uppercase). */
function key(id: string): string {
  return id.toUpperCase();
}

export function deletedSet(ids: readonly string[] | null | undefined): ReadonlySet<string> {
  return new Set((ids ?? []).filter((id) => typeof id === "string").map(key));
}

export function isDeleted(id: string, deleted: ReadonlySet<string>): boolean {
  return deleted.size > 0 && deleted.has(key(id));
}

/** `messages` without the deleted ones; the same array when none of them is. */
export function withoutDeleted<T extends { id: string }>(messages: T[], deleted: ReadonlySet<string>): T[] {
  if (!deleted.size || !messages.some((message) => isDeleted(message.id, deleted))) return messages;
  return messages.filter((message) => !isDeleted(message.id, deleted));
}
