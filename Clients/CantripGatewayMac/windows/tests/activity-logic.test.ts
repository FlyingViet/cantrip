import { describe, expect, it } from "vitest";
import type { HomeBackgroundHandoff, HomeBackgroundRun, HomeBackgroundSnapshot, InputRequest, RemoteMessage, RemoteSubagent } from "../src/gateway/api/types";
import {
  activeBackground, answerResultText, APPLE_EPOCH, backgroundPollDelay, backgroundSubagents, backgroundTaskAccessibilityLabel,
  backgroundTaskIcon, backgroundTaskSummary, backgroundTaskTitle, backgroundTasksStatusLine, canStopSubagent, capitalized,
  elapsedAccessibilityLabel, elapsedLabel, handoffNeedsAnswer, handoffStatusText, handoffSummary, handoffTabTitle,
  isLabelledSummary, isLive, liveBackgroundSubagents, liveForegroundSubagents, needsInputRuns, otherRuns, promptPages,
  promptPreview, queuedRunDetail, queuePositionLabel, recentStepsTitle, relativeNamed, remainingInputs, runCanExpand, runDetail,
  runIcon, runNeedsInput, runResult, runShowsResult, runStatusText, runTabTitle, stackLayout, subagentAccessibilityLabel,
  subagentCurrentWork, subagentDisplayName, subagentMetaLine, subagentStatusText, subagentSummaryLine, summaryLabel, tokenLabel,
} from "../src/gateway/ui/activity/activityLogic";

function agent(overrides: Partial<RemoteSubagent> = {}): RemoteSubagent {
  return {
    id: "a1", agentID: "agent-1", name: "Build watcher", agentType: "task", summary: "", background: false, status: "running",
    startedAt: 1000, steps: 0, tokens: 0, canCancel: true, recentSteps: [], ...overrides,
  };
}

function input(id: string, overrides: Partial<InputRequest> = {}): InputRequest {
  return {
    id, kind: "approval", source: "Copilot", title: "Run it?", detail: "", choices: [], allowsFreeform: false, expiresAt: 9e9, ...overrides,
  };
}

function handoff(overrides: Partial<HomeBackgroundHandoff> = {}): HomeBackgroundHandoff {
  return { id: "h1", tabID: "T1", tabTitle: "Bass Compass", summary: "Fix the slices", prompt: "Long prompt", status: "running", startedAt: 1000, ...overrides };
}

function run(overrides: Partial<HomeBackgroundRun> = {}): HomeBackgroundRun {
  return {
    id: "r1", kind: "task", label: "Daily briefing", startedAt: 800000000, status: "succeeded", summary: "All good.", route: "hidden",
    handoffs: [], canStop: false, ...overrides,
  };
}

const message = (subagents: RemoteSubagent[]): RemoteMessage => ({
  id: "m", role: "assistant", text: "", thinking: "", activities: [], isLocalPrivate: false, subagents,
});

describe("durations and tokens", () => {
  it("formats elapsed labels like CantripSubagentFormat", () => {
    expect(elapsedLabel(100, 145, 0)).toBe("45s");
    expect(elapsedLabel(100, 100 + 185, 0)).toBe("3m 05s");
    expect(elapsedLabel(100, 100 + 3720, 0)).toBe("1h 02m");
    expect(elapsedLabel(100, undefined, 159.9)).toBe("59s");
    expect(elapsedLabel(undefined, 500, 1000)).toBe("0s");
    expect(elapsedLabel(200, 100, 0)).toBe("0s");
  });

  it("speaks elapsed time", () => {
    expect(elapsedAccessibilityLabel(0, 1, 0)).toBe("1 second");
    expect(elapsedAccessibilityLabel(0, 120, 0)).toBe("2 minutes");
    expect(elapsedAccessibilityLabel(0, 61, 0)).toBe("1 minute 1 second");
    expect(elapsedAccessibilityLabel(0, 3600, 0)).toBe("1 hour");
    expect(elapsedAccessibilityLabel(0, 7260, 0)).toBe("2 hours 1 minute");
  });

  it("formats tokens", () => {
    expect(tokenLabel(999)).toBe("999 tokens");
    expect(tokenLabel(1234)).toBe("1.2k tokens");
    expect(tokenLabel(2_500_000)).toBe("2.5M tokens");
    expect(tokenLabel(-5)).toBe("0 tokens");
  });
});

describe("subagents", () => {
  it("maps statuses, treating unknown ones as live Working that can't be stopped", () => {
    expect(subagentStatusText(agent({ status: "idle" }))).toBe("Waiting");
    expect(subagentStatusText(agent({ status: "completed" }))).toBe("Done");
    expect(subagentStatusText(agent({ status: "cancelled" }))).toBe("Stopped");
    const unknown = agent({ status: "paused" as RemoteSubagent["status"] });
    expect(subagentStatusText(unknown)).toBe("Working");
    expect(isLive(unknown)).toBe(true);
    expect(canStopSubagent(unknown, "S")).toBe(false);
    expect(isLive(agent({ status: "failed" }))).toBe(false);
  });

  it("names subagents like Foundation's capitalized", () => {
    expect(subagentDisplayName(agent({ name: "  Reviewer " }))).toBe("Reviewer");
    expect(subagentDisplayName(agent({ name: "", agentType: "general-purpose agent" }))).toBe("General-Purpose Agent");
    expect(subagentDisplayName(agent({ name: "", agentType: " " }))).toBe("Subagent");
    expect(capitalized("code_review agent.x")).toBe("Code_Review Agent.X");
  });

  it("shows Stop only for cancellable, cancellable-by-backend agents in a session", () => {
    expect(canStopSubagent(agent(), "S")).toBe(true);
    expect(canStopSubagent(agent({ canCancel: false }), "S")).toBe(false);
    expect(canStopSubagent(agent(), "  ")).toBe(false);
    expect(canStopSubagent(agent({ status: "completed" }), "S")).toBe(false);
  });

  it("builds the summary, Now and meta lines", () => {
    expect(subagentSummaryLine(agent({ summary: "Build watcher" }))).toBeNull();
    expect(subagentSummaryLine(agent({ summary: "Watching CI" }))).toBe("Watching CI");
    expect(subagentCurrentWork(agent({ intent: "Checking", reasoning: [{ title: "Reading logs", text: "", number: 3 }] }))).toBe("Reading logs");
    expect(subagentCurrentWork(agent({ intent: " Checking " }))).toBe("Checking");
    expect(subagentCurrentWork(agent({ status: "idle", intent: "Checking" }))).toBeNull();
    expect(subagentMetaLine(agent({ model: "gpt-5", tokens: 1500 }), 1185)).toBe("gpt-5 · 3m 05s · 1.5k tokens");
    expect(subagentMetaLine(agent({ finishedAt: 1010 }), 99999)).toBe("10s · 0 tokens");
    expect(subagentAccessibilityLabel(agent({ tokens: 2000 }), 1061)).toBe("Task subagent, Build watcher, running, 1 minute 1 second, 2.0 thousand tokens");
  });

  it("titles recent steps", () => {
    const steps = [{ title: "a", toolName: "bash", state: "succeeded" as const }];
    expect(recentStepsTitle(agent({ steps: 9, recentSteps: steps }))).toBe("Latest 1 of 9 steps");
    expect(recentStepsTitle(agent({ steps: 1, recentSteps: steps }))).toBe("1 step");
  });

  it("folds finished cards only when there are more than three", () => {
    const three = [agent({ id: "1", status: "completed" }), agent({ id: "2" }), agent({ id: "3", status: "failed" })];
    expect(stackLayout(three)).toEqual({ primary: three, finished: [] });
    const four = [...three, agent({ id: "4", status: "idle" })];
    const layout = stackLayout(four);
    expect(layout.primary.map((item) => item.id)).toEqual(["2", "4"]);
    expect(layout.finished.map((item) => item.id)).toEqual(["1", "3"]);
  });

  it("finds background and foreground subagents in a transcript", () => {
    const messages = [message([agent({ id: "1", background: true }), agent({ id: "2", background: true, status: "completed" })]), message([agent({ id: "3" })])];
    expect(backgroundSubagents(messages).map((item) => item.id)).toEqual(["1", "2"]);
    expect(liveBackgroundSubagents(messages).map((item) => item.id)).toEqual(["1"]);
    expect(liveForegroundSubagents(messages).map((item) => item.id)).toEqual(["3"]);
    expect(backgroundTasksStatusLine(backgroundSubagents(messages))).toBe("1 task is still running.");
    expect(backgroundTasksStatusLine([agent({ status: "completed" })])).toBe("All background tasks have finished.");
    expect(backgroundTasksStatusLine([agent(), agent()])).toBe("2 tasks are still running.");
  });
});

describe("background task button", () => {
  const tasks = [agent({ background: true, name: "Upload", status: "queued" }), agent({ background: true, status: "idle" }), agent({ background: false })];

  it("counts live background tasks and summarizes the first", () => {
    const active = activeBackground(tasks);
    expect(active).toHaveLength(2);
    expect(backgroundTaskTitle(active.length)).toBe("2 background tasks");
    expect(backgroundTaskTitle(1)).toBe("1 background task");
    expect(backgroundTaskSummary(active, 1180)).toBe("Upload · Queued · 3m 00s");
    expect(backgroundTaskAccessibilityLabel(active, 1180)).toBe("2 background tasks, Upload, Queued, 3 minutes");
    expect(backgroundTaskAccessibilityLabel([], 0)).toBe("No background tasks");
  });

  it("picks the spinner, clock or pause icon", () => {
    expect(backgroundTaskIcon(activeBackground(tasks))).toBe("paused");
    expect(backgroundTaskIcon([agent({ status: "queued" })])).toBe("clock");
    expect(backgroundTaskIcon([agent({ status: "queued" }), agent({ status: "running" })])).toBe("spinner");
  });
});

describe("background runs", () => {
  const now = (800000000 + 600 + APPLE_EPOCH) * 1000;

  it("needs input only while running with inputs or the needs-input activity", () => {
    expect(runNeedsInput(run({ status: "running", inputs: [input("i1")] }))).toBe(true);
    expect(runNeedsInput(run({ status: "running", activity: "Needs your input" }))).toBe(true);
    expect(runNeedsInput(run({ status: "succeeded", inputs: [input("i1")] }))).toBe(false);
    expect(runNeedsInput(run({ status: "running" }))).toBe(false);
  });

  it("splits runs answered in place from the rest and polls faster while one waits", () => {
    const waiting = run({ id: "w", status: "running", sessionID: "S", inputs: [input("i1")] });
    const noSession = run({ id: "n", status: "running", activity: "Needs your input" });
    const done = run({ id: "d" });
    const snapshot: HomeBackgroundSnapshot = {
      sessionID: "LOG", runs: [waiting, noSession, done], queued: [], revision: "r", maxParallel: 3, runningCount: 2, supportsStop: true,
    };
    expect(needsInputRuns(snapshot).map((item) => item.id)).toEqual(["w"]);
    expect(otherRuns(snapshot).map((item) => item.id)).toEqual(["n", "d"]);
    expect(backgroundPollDelay(snapshot)).toBe(2000);
    expect(backgroundPollDelay({ ...snapshot, runs: [noSession, done] })).toBe(5000);
    expect(backgroundPollDelay(null)).toBe(5000);
    expect(remainingInputs(run({ inputs: [input("a"), input("b")] }), new Set(["a"])).map((item) => item.id)).toEqual(["b"]);
  });

  it("labels statuses", () => {
    expect(runStatusText(run({ status: "succeeded" }))).toBe("Done");
    expect(runStatusText(run({ status: "cancelled" }))).toBe("Stopped");
    expect(runStatusText(run({ status: "timed out" }))).toBe("Timed Out");
  });

  it("shows a live activity or the finished summary, and never repeats a tab handoff", () => {
    expect(runResult(run({ status: "running" }), "  ")).toBe("Running…");
    expect(runResult(run({ status: "running" }), "Shared")).toBe("Shared");
    expect(runResult(run({ status: "running", activity: "Own" }), "Shared")).toBe("Own");
    expect(runResult(run({ summary: "  Done it. " }))).toBe("Done it.");
    expect(runShowsResult(run({ route: "tab", handoffs: [handoff()] }))).toBe(false);
    expect(runShowsResult(run({ summary: " " }))).toBe(false);
  });

  it("offers Show full result for long or multi-line finished results", () => {
    expect(runCanExpand(run({ summary: "x".repeat(121) }))).toBe(true);
    expect(runCanExpand(run({ summary: "x".repeat(120) }))).toBe(false);
    expect(runCanExpand(run({ summary: "a\nb" }))).toBe(true);
    expect(runCanExpand(run({ status: "running", activity: "a\nb" }))).toBe(false);
  });

  it("writes the detail line with Apple dates for the run and Unix dates for handoffs", () => {
    expect(runDetail(run({ status: "running", repeats: 2 }), now)).toBe("Scheduled task · Running for 10m 00s · reported 3 times");
    const handed = run({ kind: "incident", status: "running", route: "tab", handoffs: [handoff({ status: "queued" })] });
    expect(runDetail(handed, now)).toBe("Incident · Queued in Bass Compass for 10m 00s");
    expect(runTabTitle(run({ route: "tab", handoffs: [handoff({ tabTitle: " " })] }))).toBe("its project tab");
    const finished = run({ finishedAt: 800000000 + 174 });
    expect(runDetail(finished, (800000000 + 174 + APPLE_EPOCH + 13 * 3600) * 1000, "en")).toBe("Scheduled task · Done 13 hours ago · took 2m 54s");
    const failedInTab = run({ status: "failed", route: "tab", finishedAt: 800000000 + 60, handoffs: [handoff({ status: "failed" })] });
    expect(runDetail(failedInTab, (800000000 + 60 + APPLE_EPOCH + 120) * 1000, "en")).toBe("Scheduled task · Failed in Bass Compass 2 minutes ago · took 1m 00s");
    expect(runDetail(run({ status: "skipped", finishedAt: 800000000 }), (800000000 + APPLE_EPOCH + 30) * 1000, "en")).toBe("Scheduled task · Skipped 30 seconds ago");
  });

  it("describes waiting runs", () => {
    expect(queuedRunDetail({ id: "q", kind: "task", label: "x", reason: " " })).toBe("Scheduled task · Waiting");
    expect(queuedRunDetail({ id: "q", kind: "incident", label: "x", reason: "After Daily briefing", repeats: 1 }))
      .toBe("Incident · After Daily briefing · reported 2 times");
  });

  it("chooses the status icon", () => {
    expect(runIcon(run({ status: "running", activity: "Needs your input" }))).toBe("needsInput");
    expect(runIcon(run({ status: "running", route: "tab", handoffs: [handoff({ status: "queued" })] }))).toBe("tabQueued");
    expect(runIcon(run({ status: "running" }))).toBe("spinner");
    expect(runIcon(run({ status: "skipped" }))).toBe("skipped");
    expect(runIcon(run({ status: "interrupted" }))).toBe("stopped");
  });

  it("announces answers", () => {
    expect(answerResultText("approve")).toBe("Approved");
    expect(answerResultText("deny")).toBe("Denied");
    expect(answerResultText("cancel")).toBe("Skipped");
    expect(answerResultText("submit")).toBe("Answered");
  });
});

describe("labelled summaries", () => {
  it("recognizes a Summary: section but not a Markdown report", () => {
    expect(isLabelledSummary("Interviewing: Coinbase (screen done)\nOffers: none yet")).toBe(true);
    expect(isLabelledSummary("Interviewing: Coinbase")).toBe(false);
    expect(isLabelledSummary("- Item: one\n- Item: two")).toBe(false);
    expect(isLabelledSummary(`${"x".repeat(41)}: a\nB: c`)).toBe(false);
    expect(isLabelledSummary(Array.from({ length: 13 }, (_, index) => `L${index}: v`).join("\n"))).toBe(false);
    expect(summaryLabel("Offers: none yet")).toEqual({ label: "Offers: ", rest: "none yet" });
  });
});

describe("relative dates", () => {
  const base = new Date(2026, 9, 23, 1, 8).getTime();
  const ago = (seconds: number) => relativeNamed(new Date(base - seconds * 1000), base, "en");

  it("matches Foundation's named relative style", () => {
    expect(ago(0)).toBe("now");
    expect(ago(45)).toBe("45 seconds ago");
    expect(ago(90)).toBe("2 minutes ago");
    expect(ago(3599)).toBe("1 hour ago");
    expect(ago(3600 * 13.6)).toBe("14 hours ago");
    expect(ago(86400 * 1.5)).toBe("2 days ago");
    expect(ago(86400 * 5)).toBe("5 days ago");
    expect(ago(86400 * 14)).toBe("2 weeks ago");
    expect(ago(86400 * 29)).toBe("last month");
    expect(ago(86400 * 100)).toBe("3 months ago");
    expect(relativeNamed(new Date(base + 30000), base, "en")).toBe("in 30 seconds");
  });
});

describe("handoff cards", () => {
  it("says when a tab needs an answer, including older Macs' status text", () => {
    expect(handoffNeedsAnswer(handoff({ latestStatus: "Waiting for your input" }))).toBe(true);
    expect(handoffNeedsAnswer(handoff({ status: "queued", latestStatus: "Needs your answer" }))).toBe(false);
    expect(handoffStatusText(handoff({ latestStatus: "Needs your answer" }))).toBe("Needs your answer");
    expect(handoffStatusText(handoff({ status: "failed" }))).toBe("Failed in tab");
    expect(handoffTabTitle(handoff({ tabTitle: "" }))).toBe("Project tab");
    expect(handoffSummary(handoff({ summary: " " }))).toBe("Long prompt");
  });
});

describe("queue", () => {
  it("previews long prompts and pages the full text", () => {
    expect(promptPreview("short")).toEqual({ preview: "short", isLong: false });
    const long = "a".repeat(1201);
    expect(promptPreview(long).preview).toHaveLength(1200);
    expect(promptPreview(long).isLong).toBe(true);
    expect(promptPages("b".repeat(8001)).map((page) => page.length)).toEqual([4000, 4000, 1]);
    expect(promptPages("")).toEqual([""]);
    expect(queuePositionLabel(0)).toBe("Next in queue");
    expect(queuePositionLabel(2)).toBe("Queue position 3");
  });
});
