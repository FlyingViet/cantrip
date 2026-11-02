import { describe, expect, it } from "vitest";
import type { HomeArtifact, HomeTask, HomeTaskListPresentation, HomeTaskRecord, HomeTaskWorkspace } from "../src/gateway/api/types";
import { APPLE_EPOCH } from "../src/gateway/state/format";
import {
  applyMove, artifactAccessibilityText, artifactFileName, artifactGlyph, artifactKey, badgeTone, canSaveRecord, capitalized,
  dateTimeValue, dateValue, displayValue, durationLabel, fileSize, filterRecords, fromLocalInput, groupStateKey,
  initialRecordValues, isLabelledSummary, isSectionCollapsed, loadGroupState, OTHER_GROUP_ID, parseDate, parseDateTime,
  recordBadge, recordDate, recordSubtitle, recordTitle, reorderMove, saveGroupState, spokenDuration, summaryLabelLength,
  summaryLines, supportsThumbnail, taskModelSummary, taskStatusKind, taskSubtitle, taskTimeLine, toLocalInput, waitingRuns, workspaceSections,
} from "../src/gateway/ui/home/homeLogic";

const stages = [
  "Applied", "Recruiter conversation scheduled", "Recruiter screen complete", "Technical interview scheduled", "Interviewing",
  "Final round", "Offer", "Rejected", "Withdrawn",
];

let nextID = 0;
function record(values: Record<string, string>): HomeTaskRecord {
  nextID++;
  return { id: `00000000-0000-0000-0000-${String(nextID).padStart(12, "0")}`, values, createdAt: 0, updatedAt: 0 };
}

function workspace(list: Partial<HomeTaskListPresentation>, rows: [string, string | null][]): HomeTaskWorkspace {
  return {
    recordLabel: "interview application",
    recordLabelPlural: "interview applications",
    icon: "briefcase.fill",
    fields: [
      { key: "company", label: "Company", kind: "text", required: true },
      { key: "role", label: "Role", kind: "text", required: false },
      { key: "stage", label: "Current stage", kind: "choice", required: false, options: stages },
      { key: "applied", label: "Applied on", kind: "date", required: false },
      { key: "remote", label: "Remote", kind: "boolean", required: false },
    ],
    list: { titleField: "company", subtitleFields: ["role"], badgeField: "stage", ...list },
    detailSections: [],
    records: rows.map(([company, stage]) => record(stage === null ? { company } : { company, stage })),
  };
}

const trackerGroups: Partial<HomeTaskListPresentation> = {
  groupField: "stage",
  groups: [
    { title: "In progress", values: ["Recruiter conversation scheduled", "Recruiter screen complete", "Technical interview scheduled", "Interviewing", "Final round", "Offer"], collapsed: false },
    { title: "Applied", values: ["Applied"], collapsed: false },
    { title: "Done", values: ["Rejected", "Withdrawn"], collapsed: true },
  ],
};

function task(overrides: Partial<HomeTask> = {}): HomeTask {
  return {
    id: "10000000-0000-0000-0000-000000000001", title: "Daily tracker", prompt: "Track things",
    schedule: { kind: "weekdays", summary: "Weekdays at 9:00 AM", timeZone: "America/Los_Angeles" },
    enabled: true, createdAt: 0, updatedAt: 0, state: "scheduled", runs: [], ...overrides,
  };
}

const appleSeconds = (ms: number) => ms / 1000 - APPLE_EPOCH;

describe("workspace grouping", () => {
  it("stays flat without a group field", () => {
    const flat = workspace({}, [["Headway", "Recruiter conversation scheduled"]]);
    expect(workspaceSections(flat, flat.records)).toBeNull();
  });

  it("keeps saved order, counts and starting collapse", () => {
    const tracker = workspace(trackerGroups, [
      ["Headway", "Recruiter conversation scheduled"], ["Legora", "Technical interview scheduled"], ["Persona", "Applied"],
      ["Rippling", "Technical interview scheduled"], ["Pinterest", "Applied"], ["Betterment", "Rejected"],
      ["Datalab", "Recruiter screen complete"], ["Ro", "Rejected"], ["Brex", "Withdrawn"],
    ]);
    const sections = workspaceSections(tracker, tracker.records)!;
    expect(sections.map((section) => section.title)).toEqual(["In progress", "Applied", "Done"]);
    expect(sections.map((section) => section.records.map((item) => item.values.company))).toEqual([
      ["Headway", "Legora", "Rippling", "Datalab"], ["Persona", "Pinterest"], ["Betterment", "Ro", "Brex"],
    ]);
    expect(sections.map((section) => section.startsCollapsed)).toEqual([false, false, true]);
    expect(sections.map((section) => section.id)).toEqual(["In progress", "Applied", "Done"]);
    const moved = tracker.records.map((item) => (item.values.company === "Legora" ? { ...item, values: { company: "Legora", stage: "Rejected" } } : item));
    expect(workspaceSections(tracker, moved)!.map((section) => section.records.length)).toEqual([3, 2, 4]);
  });

  it("puts unlisted and missing values under Other and keeps empty explicit groups", () => {
    const tracker = workspace({ groupField: "stage", groups: [{ title: "Applied", values: ["Applied"] }, { title: "Offers", values: ["Offer"] }] },
      [["Ro", "Rejected"], ["Persona", "Applied"], ["Unknown", null], ["Brex", "Withdrawn"]]);
    const sections = workspaceSections(tracker, tracker.records)!;
    expect(sections.map((section) => section.title)).toEqual(["Applied", "Offers", "Other"]);
    expect(sections.map((section) => section.records.length)).toEqual([1, 0, 3]);
    expect(sections[2].id).toBe(OTHER_GROUP_ID);
    expect(sections[2].records.map((item) => item.values.company)).toEqual(["Ro", "Unknown", "Brex"]);
    const searched = workspaceSections(tracker, filterRecords(tracker.records, "persona"), true)!;
    expect(searched.map((section) => section.title)).toEqual(["Applied"]);
  });

  it("makes one section per used option when only the group field is set", () => {
    const tracker = workspace({ groupField: "stage" }, [["Ro", "Rejected"], ["Persona", "Applied"], ["Pinterest", "Applied"]]);
    const sections = workspaceSections(tracker, tracker.records)!;
    expect(sections.map((section) => section.title)).toEqual(["Applied", "Rejected"]);
    expect(sections.map((section) => section.records.length)).toEqual([2, 1]);
  });

  it("remembers collapse state per task under the web client's key", () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => { store.set(key, value); },
      removeItem: (key: string) => { store.delete(key); },
    };
    expect(groupStateKey("ABC")).toBe("cantrip.workspaceGroups.ABC");
    expect(loadGroupState("ABC", storage)).toEqual({});
    saveGroupState("ABC", { Done: false, Applied: true }, storage);
    expect(loadGroupState("ABC", storage)).toEqual({ Done: false, Applied: true });
    expect(loadGroupState("OTHER", storage)).toEqual({});
    saveGroupState("ABC", {}, storage);
    expect(store.has("cantrip.workspaceGroups.ABC")).toBe(false);
    store.set("cantrip.workspaceGroups.BAD", "not json");
    expect(loadGroupState("BAD", storage)).toEqual({});
    const section = { id: "Done", title: "Done", records: [], startsCollapsed: true };
    expect(isSectionCollapsed(section, {})).toBe(true);
    expect(isSectionCollapsed(section, { Done: false })).toBe(false);
  });
});

describe("search", () => {
  it("matches any value, ignoring case and surrounding spaces", () => {
    const tracker = workspace({}, [["Headway", "Applied"], ["Legora", "Offer"]]);
    expect(filterRecords(tracker.records, "  OFFER ").map((item) => item.values.company)).toEqual(["Legora"]);
    expect(filterRecords(tracker.records, "")).toBe(tracker.records);
    expect(filterRecords(tracker.records, "zzz")).toEqual([]);
  });
});

describe("record values", () => {
  const field = (kind: "boolean" | "date" | "dateTime" | "text") => ({ kind });

  it("formats booleans, dates and date-times, passing through what doesn't parse", () => {
    expect(displayValue("true", field("boolean"))).toBe("Yes");
    expect(displayValue("false", field("boolean"))).toBe("No");
    expect(displayValue("2026-10-03", field("date"), "en-US")).toBe("Oct 3, 2026");
    expect(displayValue("2026-02-30", field("date"), "en-US")).toBe("2026-02-30");
    expect(displayValue("soon", field("dateTime"))).toBe("soon");
    expect(displayValue("2026-10-03T22:05:00.123Z", field("dateTime"))).toBe("2026-10-03T22:05:00.123Z");
    expect(displayValue("2026-10-03T22:05:00Z", field("dateTime"), "en-US")).toMatch(/Oct [34], 2026/);
    expect(displayValue("anything", field("text"))).toBe("anything");
  });

  it("round-trips the editor's date formats", () => {
    expect(dateValue(new Date(2026, 0, 5))).toBe("2026-01-05");
    expect(parseDate("2026-01-05")?.getDate()).toBe(5);
    expect(parseDate("2026-1-5")).toBeNull();
    const instant = new Date(Date.UTC(2026, 9, 23, 7, 48, 3, 250));
    expect(dateTimeValue(instant)).toBe("2026-10-23T07:48:03Z");
    expect(parseDateTime("2026-10-23T07:48:03Z")?.getTime()).toBe(Date.UTC(2026, 9, 23, 7, 48, 3));
    expect(parseDateTime("2026-10-23T09:48:03+0200")?.getTime()).toBe(Date.UTC(2026, 9, 23, 7, 48, 3));
    const local = toLocalInput("2026-10-23T07:48:03Z");
    expect(local).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/);
    expect(fromLocalInput(local)).toBe("2026-10-23T07:48:00Z");
    expect(toLocalInput(undefined)).toBe("");
    expect(fromLocalInput("")).toBeNull();
  });

  it("starts editors with switches off and required dates today", () => {
    const tracker = workspace({}, []);
    tracker.fields.push({ key: "due", label: "Due", kind: "date", required: true }, { key: "at", label: "At", kind: "dateTime", required: true });
    const now = new Date(2026, 9, 23, 1, 2, 3);
    const values = initialRecordValues(tracker, null, now);
    expect(values).toEqual({ remote: "false", due: "2026-10-23", at: dateTimeValue(now) });
    expect(initialRecordValues(tracker, record({ company: "Ro", remote: "true" }), now).remote).toBe("true");
    expect(canSaveRecord(tracker, values)).toBe(false);
    expect(canSaveRecord(tracker, { ...values, company: "  " })).toBe(false);
    expect(canSaveRecord(tracker, { ...values, company: "Ro" })).toBe(true);
  });

  it("builds record rows from the list presentation", () => {
    const tracker = workspace({ subtitleFields: ["role", "remote", "missing"], dateField: "applied" }, []);
    const item = record({ company: "Ro", role: "Staff Engineer", remote: "true", stage: "Offer", applied: "2026-10-03" });
    expect(recordTitle(tracker, item)).toBe("Ro");
    expect(recordTitle(tracker, record({ role: "x" }))).toBe("interview application");
    expect(recordSubtitle(tracker, item)).toBe("Role: Staff Engineer · Remote: Yes");
    expect(recordBadge(tracker, item)).toBe("Offer");
    expect(recordBadge(tracker, record({ stage: "" }))).toBeNull();
    expect(recordDate(tracker, item, "en-US")).toBe("Oct 3, 2026");
    expect(recordDate(tracker, record({}))).toBeNull();
  });
});

describe("badge tone", () => {
  it("uses hiring lifecycle semantics", () => {
    expect(badgeTone("Rejected")).toBe("rejected");
    expect(badgeTone("Application declined")).toBe("rejected");
    expect(badgeTone("Offer")).toBe("offer");
    expect(badgeTone(" Applied ")).toBe("applied");
    expect(badgeTone("Application received")).toBe("applied");
    expect(badgeTone("Recruiter conversation scheduled")).toBe("inProgress");
    expect(badgeTone("Healthy")).toBe("accent");
  });
});

describe("task rows", () => {
  const now = Date.UTC(2026, 9, 23, 8, 0, 0);

  it("shows the next run, pause, or last update with the latest run's status", () => {
    const next = task({ nextRunAt: appleSeconds(now + 52 * 60000), runs: [{ id: "r", startedAt: 0, finishedAt: 0, status: "succeeded", summary: "" }] });
    expect(taskTimeLine(next, now)).toEqual({ icon: "clock", text: "in 52 minutes", status: "Succeeded" });
    expect(taskTimeLine({ ...next, enabled: false }, now)).toMatchObject({ icon: "pause", text: "Paused" });
    expect(taskTimeLine(task(), now)).toEqual({ icon: "pause", text: "Paused", status: null });
    const manual = task({ hasSchedule: false, updatedAt: appleSeconds(now - 3 * 3600000) });
    expect(taskTimeLine(manual, now)).toEqual({ icon: "rectangle.stack", text: "Updated 3 hours ago", status: null });
  });

  it("counts workspace records or shows the schedule", () => {
    const tracker = workspace({}, [["Ro", null], ["Brex", null]]);
    expect(taskSubtitle(task({ workspace: tracker }))).toBe("2 interview applications");
    expect(taskSubtitle(task({ workspace: { ...tracker, records: tracker.records.slice(0, 1) } }))).toBe("1 interview application");
    expect(taskSubtitle(task({ workspace: { ...tracker, recordLabel: "trip", recordLabelPlural: undefined } }))).toBe("2 trips");
    expect(taskSubtitle(task())).toBe("Weekdays at 9:00 AM");
  });

  it("adds the task's own model to its subtitle", () => {
    expect(taskModelSummary(task())).toBeUndefined();
    expect(taskSubtitle(task({ model: "claude-sonnet-5.5" }))).toBe("Weekdays at 9:00 AM · claude-sonnet-5.5");
    expect(taskModelSummary(task({ model: "claude-sonnet-5.5", effort: "high" }))).toBe("claude-sonnet-5.5 · high effort");
    expect(taskModelSummary(task({ effort: "low" }))).toBe("Home's model · low effort");
  });

  it("picks the status glyph", () => {
    expect(taskStatusKind({ state: "running" }, true)).toBe("needsInput");
    expect(taskStatusKind({ state: "running" }, false)).toBe("running");
    expect(taskStatusKind({ state: "ready" }, false)).toBe("ready");
    expect(taskStatusKind({ state: "scheduled" }, false)).toBe("scheduled");
  });

  it("finds runs waiting on the user", () => {
    const run = (overrides: object) => ({
      id: "x", kind: "task", label: "", startedAt: 0, status: "running", summary: "", route: "hidden", handoffs: [], canStop: true, ...overrides,
    });
    const snapshot = {
      sessionID: "log", queued: [], revision: "1", maxParallel: 3, runningCount: 2, supportsStop: true as const,
      runs: [
        run({ taskID: "aaa", sessionID: "s1", activity: "Needs your input" }),
        run({ taskID: "bbb", sessionID: "s2" }),
        run({ taskID: "ccc", sessionID: "s3", status: "succeeded", activity: "Needs your input" }),
      ],
    } as Parameters<typeof waitingRuns>[0];
    expect([...waitingRuns(snapshot)]).toEqual([["AAA", "s1"]]);
    expect(waitingRuns(null).size).toBe(0);
  });

  it("capitalizes run statuses like Swift", () => {
    expect(capitalized("succeeded")).toBe("Succeeded");
    expect(capitalized("in progress")).toBe("In Progress");
    expect(capitalized("PDF")).toBe("Pdf");
  });
});

describe("run summaries", () => {
  const summary = "Upcoming interviews: Fri Oct 16, 10 AM · Headway (recruiter call)\n"
    + "Interviewing: Coinbase (screen done, awaiting next steps)\n\n"
    + "  Applied, waiting (6 companies): Airbnb, Anthropic\n"
    + "Changes: Headway booked a recruiter call; Bloomberg rejected.";

  it("splits lines and finds short labels", () => {
    expect(summaryLines(summary)).toHaveLength(4);
    expect(isLabelledSummary(summary)).toBe(true);
    expect(summaryLabelLength("Interviewing: Coinbase (screen done)")).toBe("Interviewing: ".length);
    expect(summaryLabelLength("Call at 10:00 AM, then lunch")).toBe(0);
    expect(summaryLabelLength("**Bills:** nothing due.")).toBe(0);
    expect(summaryLabelLength(`${"x".repeat(41)}: too long`)).toBe(0);
    expect(isLabelledSummary("Starting with the tracker procedure note, then refreshing Mail. Mail refreshed.")).toBe(false);
    expect(isLabelledSummary("Mail refreshed.\n\n**Bills:** nothing due.\n- Paid: rent")).toBe(false);
  });
});

describe("reordering", () => {
  it("maps every list drop to a relative move", () => {
    const ids = ["a", "b", "c", "d"];
    for (let source = 0; source < ids.length; source++) {
      for (let destination = 0; destination <= ids.length; destination++) {
        const expected = ids.slice();
        const [item] = expected.splice(source, 1);
        expected.splice(destination > source ? destination - 1 : destination, 0, item);
        const move = reorderMove(ids, source, destination);
        if (!move) {
          expect(expected).toEqual(ids);
          continue;
        }
        expect(move.id).toBe(ids[source]);
        const relative = ids.filter((id) => id !== move.id);
        relative.splice(relative.indexOf(move.targetID) + (move.after ? 1 : 0), 0, move.id);
        expect(relative).toEqual(expected);
        expect(applyMove(ids.map((id) => ({ id })), move.id, move.targetID, move.after)!.map((entry) => entry.id)).toEqual(expected);
      }
    }
    expect(applyMove([{ id: "a" }], "a", "zzz", true)).toBeNull();
  });
});

describe("artifacts", () => {
  const artifact = (overrides: Partial<HomeArtifact>): HomeArtifact => ({
    id: "20000000-0000-0000-0000-000000000007", title: "Set walk-in", relativePath: "media/walkin.mov", kind: "video",
    mimeType: "video/quicktime", size: 2048, createdAt: 1_790_000_000 - APPLE_EPOCH, ...overrides,
  });

  it("keys thumbnails by file revision", () => {
    expect(artifactKey(artifact({}))).toBe("20000000-0000-0000-0000-000000000007-2048-1790000000000");
    expect(artifactKey(artifact({ size: 2049 }))).not.toBe(artifactKey(artifact({})));
  });

  it("only requests thumbnails for images and videos and picks icons", () => {
    expect(supportsThumbnail(artifact({}))).toBe(true);
    expect(supportsThumbnail(artifact({ kind: "document", mimeType: "image/png" }))).toBe(true);
    expect(supportsThumbnail(artifact({ kind: "audio", mimeType: "audio/mp4" }))).toBe(false);
    expect(artifactGlyph(artifact({ kind: "document", mimeType: "application/pdf" }))).toBe("doc.richtext.fill");
    expect(artifactGlyph(artifact({ kind: "document", mimeType: "text/markdown" }))).toBe("doc.text.fill");
    expect(artifactGlyph(artifact({ kind: "audio", mimeType: "audio/mp4" }))).toBe("waveform");
  });

  it("formats durations, sizes and the spoken label like the Mac", () => {
    expect(durationLabel(0.4)).toBe("0:01");
    expect(durationLabel(12.4)).toBe("0:12");
    expect(durationLabel(754)).toBe("12:34");
    expect(durationLabel(3723)).toBe("1:02:03");
    expect(spokenDuration(65)).toBe("1 minute, 5 seconds");
    expect(spokenDuration(3600)).toBe("1 hour");
    expect(fileSize(0)).toBe("Zero KB");
    expect(fileSize(1)).toBe("1 byte");
    expect(fileSize(999)).toBe("999 bytes");
    expect(fileSize(7000)).toBe("7 KB");
    expect(fileSize(607_400)).toBe("607 KB");
    expect(fileSize(999_700)).toBe("1 MB");
    expect(fileSize(1_250_000)).toBe("1.3 MB");
    expect(fileSize(2_000_000)).toBe("2 MB");
    expect(fileSize(3_456_000_000)).toBe("3.46 GB");
    expect(artifactAccessibilityText(artifact({}), 12.4)).toBe("Set walk-in, Video, 12 seconds, 2 KB");
    expect(artifactAccessibilityText(artifact({}), null)).toBe("Set walk-in, Video, 2 KB");
  });

  it("names saved files after the title with the file's extension", () => {
    expect(artifactFileName(artifact({ title: "Manual job applications - Oct 3", relativePath: "docs/jobs.md" }))).toBe("Manual job applications - Oct 3.md");
    expect(artifactFileName(artifact({ title: "Report.PDF", relativePath: "report.pdf" }))).toBe("Report.PDF");
    expect(artifactFileName(artifact({ title: "Q3/Q4: plan", relativePath: "plan" }))).toBe("Q3_Q4_ plan");
  });
});
