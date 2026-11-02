import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { HomeBackgroundSnapshot, RemoteSessionSummary } from "../src/gateway/api/types";
import {
  backgroundLogID, closeBackgroundLog, FULL_LOG_HINT, FULL_LOG_LABEL, openBackgroundLog, readOnlySession, shownSessionID, type LogNavigation,
} from "../src/gateway/state/backgroundLog";

// Real host output (GET /api/v1/home/background) from a QA Mac.
const background = JSON.parse(readFileSync(new URL("./fixtures/home/background.json", import.meta.url), "utf8")) as HomeBackgroundSnapshot;
const LOG_ID = background.sessionID;
const TAB_ID = "0F5B2E7A-1C3D-4E5F-8A9B-0C1D2E3F4A5B";
const HOME_ID = "6D1C7B2A-3E4F-4A5B-9C8D-7E6F5A4B3C2D";

function navigation(start: Partial<{ sheet: { kind: string } | null; openTabID: string | null; logID: string | null }> = {}): LogNavigation {
  return {
    sheet: { value: start.sheet === undefined ? { kind: "background" } : start.sheet },
    openTabID: { value: start.openTabID ?? null },
    logID: { value: start.logID ?? null },
  };
}

describe("Full Log button", () => {
  it("shows when the Background snapshot names the log session", () => {
    expect(LOG_ID).toMatch(/^[0-9A-F-]{36}$/);
    expect(backgroundLogID(background)).toBe(LOG_ID);
    expect(backgroundLogID({ sessionID: LOG_ID.toLowerCase() })).toBe(LOG_ID.toLowerCase());
  });

  it("hides for older Macs, no snapshot yet, or anything that isn't a session ID", () => {
    expect(backgroundLogID(null)).toBeNull();
    expect(backgroundLogID(undefined)).toBeNull();
    const { sessionID: _omitted, ...older } = background;
    expect(backgroundLogID(older as HomeBackgroundSnapshot)).toBeNull();
    for (const value of ["", "log", "../sessions", `${LOG_ID}/messages`, `${LOG_ID}?x=1`, ` ${LOG_ID}`, 42, null, {}]) {
      expect(backgroundLogID({ sessionID: value as string }), String(value)).toBeNull();
    }
  });

  it("is named Full Log and says what it shows", () => {
    expect(FULL_LOG_LABEL).toBe("Full Log");
    expect(FULL_LOG_HINT).toBe("Shows the background runs' reports");
  });
});

describe("opening the log", () => {
  it("closes Background and shows the log in the detail pane", () => {
    const state = navigation();
    expect(openBackgroundLog(state, background)).toBe(true);
    expect(state.sheet.value).toBeNull();
    expect(state.logID.value).toBe(LOG_ID);
    expect(state.openTabID.value).toBeNull();
    expect(shownSessionID(state.logID.value, state.openTabID.value, HOME_ID)).toBe(LOG_ID);
  });

  it("replaces an open tab rather than opening the log as one", () => {
    const state = navigation({ openTabID: TAB_ID });
    openBackgroundLog(state, background);
    expect(state.openTabID.value).toBeNull();
    expect(state.logID.value).toBe(LOG_ID);
  });

  it("does nothing without a log", () => {
    const state = navigation();
    expect(openBackgroundLog(state, { sessionID: "" })).toBe(false);
    expect(openBackgroundLog(state, null)).toBe(false);
    expect(state.sheet.value).toEqual({ kind: "background" });
    expect(state.logID.value).toBeNull();
  });

  it("goes back to Background, or to Home", () => {
    const back = navigation({ sheet: null, logID: LOG_ID });
    closeBackgroundLog(back, true);
    expect(back.logID.value).toBeNull();
    expect(back.sheet.value).toEqual({ kind: "background" });
    expect(shownSessionID(back.logID.value, back.openTabID.value, HOME_ID)).toBe(HOME_ID);

    const home = navigation({ sheet: null, logID: LOG_ID });
    closeBackgroundLog(home, false);
    expect(home.logID.value).toBeNull();
    expect(home.sheet.value).toBeNull();
  });

  it("shows the log first, then the open tab, then Home", () => {
    expect(shownSessionID(LOG_ID, TAB_ID, HOME_ID)).toBe(LOG_ID);
    expect(shownSessionID(null, TAB_ID, HOME_ID)).toBe(TAB_ID);
    expect(shownSessionID(null, null, HOME_ID)).toBe(HOME_ID);
    expect(shownSessionID(null, null, null)).toBeNull();
  });
});

describe("the log is read-only", () => {
  it("drops the actions that would change it", () => {
    const session = {
      id: LOG_ID, title: "Background", customTitle: "", isCantripHome: false, isCantripHomeBackground: true,
      supportsDeleteMessage: true, continuableMessageIDs: ["A"], repeatedErrorMessageID: "B", pendingInputs: [{ id: "C" }],
    } as unknown as RemoteSessionSummary;
    const shown = readOnlySession(session);
    expect(shown.supportsDeleteMessage).toBe(false);
    expect(shown.continuableMessageIDs).toEqual([]);
    expect(shown.repeatedErrorMessageID).toBeUndefined();
    expect(shown.pendingInputs).toEqual([]);
    expect(shown.id).toBe(LOG_ID);
    expect(session.supportsDeleteMessage).toBe(true);
  });
});
