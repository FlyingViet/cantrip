// Cantrip Home's background log (Background › Full Log, like Cantrip Agent's): the hidden conversation that keeps
// every background run's report. The Mac never lists it, so the detail pane shows it by ID, read-only, instead of
// as a tab. No DOM or signals here, so vitest covers it (tests/background-log.test.ts).
import type { HomeBackgroundSnapshot, RemoteSessionSummary } from "../api/types";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const FULL_LOG_LABEL = "Full Log";
export const FULL_LOG_HINT = "Shows the background runs' reports";

/** The log Full Log opens: the snapshot's `sessionID` when it is a session ID (older Macs send none). */
export function backgroundLogID(snapshot: Pick<HomeBackgroundSnapshot, "sessionID"> | null | undefined): string | null {
  const id: unknown = snapshot?.sessionID;
  return typeof id === "string" && UUID.test(id) ? id : null;
}

/** The navigation state Full Log changes (nav.ts's signals). */
export interface LogNavigation {
  sheet: { value: { kind: string } | null };
  openTabID: { value: string | null };
  logID: { value: string | null };
}

/** Full Log: closes Background and shows the log in the detail pane. False (and nothing changes) without a log. */
export function openBackgroundLog(navigation: LogNavigation, snapshot: Pick<HomeBackgroundSnapshot, "sessionID"> | null | undefined): boolean {
  const id = backgroundLogID(snapshot);
  if (!id) return false;
  navigation.sheet.value = null;
  navigation.openTabID.value = null;
  navigation.logID.value = id;
  return true;
}

/** Leaves the log for Home; `toBackground` reopens the Background sheet it came from. */
export function closeBackgroundLog(navigation: LogNavigation, toBackground: boolean): void {
  navigation.logID.value = null;
  if (toBackground) navigation.sheet.value = { kind: "background" };
}

/** The session the detail pane shows: the log, else the open tab, else Home. */
export function shownSessionID(logID: string | null, openTabID: string | null, homeID: string | null): string | null {
  return logID ?? openTabID ?? homeID;
}

/** The log as the transcript draws it: Cantrip's own record, so no Delete Message, Continue or retry actions. */
export function readOnlySession<T extends RemoteSessionSummary>(session: T): T {
  return { ...session, supportsDeleteMessage: false, continuableMessageIDs: [], repeatedErrorMessageID: undefined, pendingInputs: [] };
}
