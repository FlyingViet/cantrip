import { describe, expect, it } from "vitest";
import type {
  CopilotQuotaBucket, CopilotUsageSnapshot, DesktopFrame, GitHubBuildJob, GitHubBuildRepository, GitHubBuildSnapshot,
  MaintenanceSnapshot, MemoryCatalog, MemoryPage, ModelSettingsSnapshot,
} from "../src/gateway/api/types";
import {
  EMPTY_READER, INVALID_RESPONSE, alignMemoryPage, codeFenceAfter, renderableMemory, NotSentError, QueueReadiness, amountRatio, assignmentText, bucketSummary, bucketTitle,
  buildEntries, buildQueue, buildsPollDelay, canStartMaintenance, capitalized, clearsPendingMaintenance, contextLabel,
  copilotAmount, decodeBase64, decryptDesktopFrame, desktopCommandJSON, encodeBase64, encryptDesktopCommand, endpointHost,
  frameAdditionalData, githubURL, graphemeCount, importDesktopKey, initialTabName, inputAdditionalData, isMaintenanceRequest,
  isUsageStale, jobStatusTitle, maintenancePollDelay, memoryCatalogPath, memoryCharacterCount, memoryDocumentPath,
  memoryEntriesByCategory, memoryName, memoryTitle, mergeCatalog, modelInfo, modelSettingsChange, modelValidationError,
  normalizeTabName, normalizedPoint, openCombined, overageAllowedText, overageText, parseContextTokens, percentageSummary,
  permissionStateLabel, pickerChoices, primaryBucket, privateModelChoices, queueReadiness, queueReason, readerApply,
  readerRequest, relativeDuration, repositoryIsStale, sealCombined, selectModel, snapshotIsComplete, tabNameError,
  tokenLabel, usageHeaderText, usagePollDelay, usedAmount, validCatalogPage, validMemoryPage, writeFailure,
} from "../src/gateway/ui/sheets/sheetLogic";

// Cases mirror Hermes/Tests (CantripModelSettingsTests, CopilotUsageTests, CantripMemoryTests,
// GitHubBuildsTests, CantripMaintenanceTests, CantripMacAccessTests).

describe("errors", () => {
  it("adds the may-have-reached note only after route failures", () => {
    expect(writeFailure(Object.assign(new Error("Busy"), { status: 409 }))).toBe("Busy");
    expect(writeFailure(Object.assign(new Error("Offline."), { status: 0 })))
      .toBe("Offline. The request may have reached Cantrip. Check the session before sending again.");
    expect(writeFailure(Object.assign(new Error("The Mac didn't answer in time. Check before trying again; it may have gone through."), { status: 0 })))
      .not.toContain("may have reached");
  });
});

describe("tab names", () => {
  it("collapses whitespace and limits names to 80 characters", () => {
    expect(normalizeTabName("  Ship   the\tbuild \n")).toBe("Ship the build");
    expect(normalizeTabName("   ")).toBe("");
    expect(tabNameError("a".repeat(80))).toBeNull();
    expect(tabNameError("a".repeat(81))).toBe("Tab names must be 80 characters or fewer.");
    expect(tabNameError(`${"a ".repeat(40)}    `)).toBeNull();
    expect(graphemeCount("👩‍👩‍👧é")).toBe(2);
    expect(tabNameError("👍🏽".repeat(80))).toBeNull();
  });

  it("starts from the custom title, else the automatic one", () => {
    expect(initialTabName({ title: "Auto", customTitle: "" })).toBe("Auto");
    expect(initialTabName({ title: "Auto", customTitle: "Mine" })).toBe("Mine");
  });
});

describe("model settings", () => {
  const settings: ModelSettingsSnapshot = {
    selection: { model: "model-a", effort: "low", contextTier: "default" },
    defaults: { model: "model-a", effort: "low", contextTier: "default" },
    usesDefaults: true, revision: "v1", isRefreshing: false,
    models: [
      { id: "model-a", reasoningEfforts: ["low", "high"], contextTiers: ["default", "long_context"], contextWindow: 1_050_000,
        defaultContextPromptTokens: 272_000, longContextPromptTokens: 1_050_000 },
      { id: "model-b", reasoningEfforts: [], contextTiers: ["default"] },
      { id: "unknown-capabilities" },
    ],
  };

  it("labels token budgets like the Mac", () => {
    expect(tokenLabel(1_050_000)).toBe("1.05M");
    expect(tokenLabel(272_000)).toBe("272k");
    expect(tokenLabel(1_000_000)).toBe("1M");
    expect(tokenLabel(128_500)).toBe("128.5k");
    expect(tokenLabel(512)).toBe("512");
    expect(tokenLabel(100)).toBe("100");
    expect(tokenLabel(0)).toBe("0");
    expect(contextLabel(settings.models[0], "default")).toBe("Standard - 272k input");
    expect(contextLabel(settings.models[0], "long_context")).toBe("Long - 1.05M input");
    expect(contextLabel(settings.models[1], "default")).toBe("Standard");
    expect(contextLabel(settings.models[1], "turbo")).toBe("turbo");
    expect(contextLabel(undefined, "default")).toBe("default");
  });

  it("validates selections against the catalog", () => {
    expect(modelValidationError(settings, { model: "model-a", effort: "high", contextTier: "long_context" })).toBeNull();
    expect(modelValidationError(settings, { model: "", effort: "", contextTier: "" })).toBeNull();
    expect(modelValidationError(settings, { model: "model-b", effort: "high", contextTier: "default" }))
      .toBe("Choose a supported effort or Model default.");
    expect(modelValidationError(settings, { model: "model-b", effort: "", contextTier: "long_context" }))
      .toBe("Choose a supported context window or CLI default.");
    expect(modelValidationError(settings, { model: "missing", effort: "", contextTier: "" }))
      .toBe("This model is no longer in the Mac's catalog.");
    expect(modelValidationError(settings, { model: "unknown-capabilities", effort: "high", contextTier: "" })).not.toBeNull();
    // "" uses the CLI's default model for capability checks.
    const withDefault = { ...settings, fileDefaultModel: "model-a" };
    expect(modelInfo(withDefault, { model: "", effort: "", contextTier: "" })?.id).toBe("model-a");
    expect(modelValidationError(withDefault, { model: "", effort: "high", contextTier: "" })).toBeNull();
    expect(modelInfo(settings, { model: "", effort: "", contextTier: "" })).toBeUndefined();
  });

  it("builds picker choices, resets on model change and encodes the change", () => {
    expect(pickerChoices(["low", "high"], "")).toEqual(["low", "high"]);
    expect(pickerChoices(["low", "high"], "max")).toEqual(["low", "high", "max"]);
    expect(pickerChoices(undefined, "low")).toEqual(["low"]);
    expect(pickerChoices(["a", "a"], "a")).toEqual(["a"]);
    expect(selectModel(settings, { model: "model-a", effort: "high", contextTier: "long_context" }, "model-b"))
      .toEqual({ model: "model-b", effort: "", contextTier: "default" });
    expect(selectModel(settings, { model: "model-a", effort: "high", contextTier: "long_context" }, "unknown-capabilities"))
      .toEqual({ model: "unknown-capabilities", effort: "", contextTier: "" });
    expect(modelSettingsChange("v1", null)).toEqual({ revision: "v1", usesDefaults: true });
    expect(Object.keys(modelSettingsChange("v1", null)).sort()).toEqual(["revision", "usesDefaults"]);
    expect(modelSettingsChange("v1", { model: "model-a", effort: "high", contextTier: "long_context" }))
      .toEqual({ revision: "v1", usesDefaults: false, model: "model-a", effort: "high", contextTier: "long_context" });
  });

  it("handles Private Local model lists and token counts", () => {
    expect(privateModelChoices(["qwen:7b", "llama3:8b"], "")).toEqual(["", "llama3:8b", "qwen:7b"]);
    expect(privateModelChoices(["qwen:7b"], "qwen:7b")).toEqual(["qwen:7b"]);
    expect(parseContextTokens("8192")).toBe(8192);
    expect(parseContextTokens(" 32,768 ")).toBe(32768);
    expect(parseContextTokens("8k")).toBeNull();
    expect(parseContextTokens("")).toBeNull();
    expect(parseContextTokens("1.5")).toBeNull();
  });
});

describe("Copilot usage", () => {
  const now = Date.parse("2026-10-23T08:00:00Z");
  const iso = (offset: number) => new Date(now + offset).toISOString();
  const bucket = (change: Partial<CopilotQuotaBucket> = {}): CopilotQuotaBucket => ({
    id: "premium_interactions", billingMode: "credits", isUnlimited: false, remainingPercent: 96.44224,
    remaining: 964422.4, entitlement: 1000000, overage: 0, overageAllowed: true, resetAt: iso(86_400_000), observedAt: iso(0),
    ...change,
  });
  const snapshot = (change: Partial<CopilotQuotaBucket> = {}, rest: Partial<CopilotUsageSnapshot> = {}): CopilotUsageSnapshot => ({
    account: { login: "quota-test", plan: "individual", buckets: [bucket(change)] }, checkedAt: iso(0), isRefreshing: false, ...rest,
  });

  it("formats amounts, ratios and percentages like the Mac", () => {
    expect(amountRatio(bucket(), false, "en-US")).toBe("35,577.6 / 1,000,000");
    expect(amountRatio(bucket(), true, "en-US")).toBe("35.5K / 1M");
    expect(bucketSummary(bucket(), "en-US")).toBe("35,577.6 / 1,000,000 AI credits used");
    expect(percentageSummary(bucket())).toBe("3.6% used / 96.4% remaining");
    expect(copilotAmount(999999.999, true, "en-US")).toBe("999.9K");
    expect(copilotAmount(0.001, false, "en-US")).toBe("<0.01");
    expect(copilotAmount(0, false, "en-US")).toBe("0");
    expect(copilotAmount(12.349, false, "de-DE")).toBe("12,34");
    for (const [remaining, expected] of [[100, "0 / 100"], [99.99, "0.01 / 100"], [99.999, "<0.01 / 100"], [0, "100 / 100"]] as const) {
      expect(amountRatio(bucket({ entitlement: 100, remaining, remainingPercent: undefined }), false, "en-US")).toBe(expected);
    }
    expect(usedAmount(300, 299.99)).toBe(0.01);
    expect(amountRatio(bucket({ entitlement: 0, remaining: 0 }), false, "en-US")).toBe("0 / 0");
  });

  it("falls back when amounts are missing or inconsistent", () => {
    for (const change of [{ remaining: undefined }, { entitlement: undefined }, { remaining: -1 }, { remaining: 1000001 }, { entitlement: -1 }]) {
      expect(bucketSummary(bucket(change))).toBe("AI-credit amounts unavailable");
      expect(usageHeaderText(snapshot(change), false, now)).toBe("--");
    }
    expect(bucketSummary(bucket({ billingMode: "requests", remaining: 225, entitlement: 300 }), "en-US")).toBe("75 / 300 requests used");
    expect(bucketSummary(bucket({ billingMode: "unknown", remainingPercent: 80 }))).toBe("20.0% used / 80.0% remaining");
    expect(bucketSummary(bucket({ billingMode: "unknown", remainingPercent: undefined }))).toBe("Premium allowance: used amount unavailable");
    expect(bucketSummary(bucket({ isUnlimited: true }))).toBe("Unlimited included ai-credit budget");
    expect(bucketTitle(bucket({ id: "chat" }))).toBe("Chat allowance");
    expect(overageAllowedText(bucket({ overageAllowed: undefined }))).toBe("Additional usage: not reported");
    expect(overageAllowedText(bucket({ overageAllowed: false }))).toBe("Additional usage: disabled");
    expect(overageText(bucket())).toBe("No additional usage reported consumed");
    expect(overageText(bucket({ overage: 25, billingMode: "requests" }), "en-US")).toBe("Additional usage consumed: 25 requests");
    expect(overageText(bucket({ overage: undefined }))).toBeNull();
  });

  it("detects stale snapshots and builds the header text", () => {
    expect(isUsageStale(snapshot(), now)).toBe(false);
    expect(isUsageStale(snapshot({}, { checkedAt: iso(-301_000) }), now)).toBe(true);
    expect(isUsageStale(snapshot({ observedAt: iso(-601_000) }), now)).toBe(true);
    expect(isUsageStale(snapshot({ resetAt: iso(-1000) }), now)).toBe(true);
    expect(isUsageStale(snapshot({}, { error: "Sign in on the Mac" }), now)).toBe(true);
    expect(isUsageStale({ isRefreshing: false }, now)).toBe(true);
    expect(isUsageStale(snapshot({}, { checkedAt: "2026-10-23T08:00:00Z" }), now)).toBe(false);
    expect(usageHeaderText(snapshot({ remaining: 0, remainingPercent: 0 }), false, now, "en-US")).toBe("1M / 1M");
    expect(usageHeaderText(snapshot({ remaining: 1000000, remainingPercent: 100 }), false, now, "en-US")).toBe("0 / 1M");
    expect(usageHeaderText(snapshot({ isUnlimited: true }), false, now)).toBe("Unlimited");
    expect(usageHeaderText(snapshot({ billingMode: "unknown", remainingPercent: 80 }), false, now)).toBe("20.0%");
    expect(usageHeaderText(snapshot(), true, now)).toBe("Stale");
    expect(usageHeaderText(null, false, now)).toBe("--");
    expect(primaryBucket({ isRefreshing: false, account: { buckets: [bucket({ id: "chat" }), bucket()] } })?.id).toBe("premium_interactions");
    expect(usagePollDelay(snapshot({}, { isRefreshing: true }))).toBe(2000);
    expect(usagePollDelay(null)).toBe(60000);
  });
});

describe("memory", () => {
  const entry = (id: string, category: "core" | "notes" | "sessions" = "notes") => ({ id, category, bytes: 40000, modifiedAt: 1_790_000_000 });

  it("names entries and builds paths", () => {
    expect(memoryTitle({ id: "MEMORY.md" })).toBe("Environment & conventions");
    expect(memoryTitle({ id: "USER.md" })).toBe("About you");
    expect(memoryTitle({ id: "notes/deploy steps.md" })).toBe("deploy steps.md");
    expect(memoryName({ id: "sessions/2026-10-22.md" })).toBe("2026-10-22.md");
    expect(memoryCatalogPath("deploy notes")).toBe("/api/v1/memory?q=deploy%20notes");
    expect(memoryCatalogPath("", "notes/a+b.md")).toBe("/api/v1/memory?q=&after=notes%2Fa%2Bb.md");
    expect(memoryDocumentPath("notes/a.md", 0)).toBe("/api/v1/memory/document?id=notes%2Fa.md&offset=0");
    expect(memoryDocumentPath("notes/a.md", 16384, "r1")).toBe("/api/v1/memory/document?id=notes%2Fa.md&offset=16384&revision=r1");
  });

  it("validates and merges catalog pages", () => {
    const first: MemoryCatalog = { enabled: true, exists: true, documents: [entry("MEMORY.md", "core"), entry("notes/a.md")], nextCursor: "notes/a.md" };
    expect(validCatalogPage(first, null)).toBe(true);
    expect(validCatalogPage({ ...first, nextCursor: "MEMORY.md" }, null)).toBe(false);
    expect(validCatalogPage(first, "notes/a.md")).toBe(false);
    expect(validCatalogPage({ ...first, documents: [], nextCursor: "x" }, null)).toBe(false);
    expect(validCatalogPage({ ...first, nextCursor: undefined }, "notes/a.md")).toBe(true);
    const second: MemoryCatalog = { enabled: false, exists: true, documents: [entry("notes/a.md"), entry("sessions/x.md", "sessions")] };
    const merged = mergeCatalog(first, second, true);
    expect(merged.documents.map((item) => item.id)).toEqual(["MEMORY.md", "notes/a.md", "sessions/x.md"]);
    expect(merged.enabled).toBe(false);
    expect(merged.nextCursor).toBeUndefined();
    expect(mergeCatalog(first, second, false).documents.map((item) => item.id)).toEqual(["notes/a.md", "sessions/x.md"]);
    expect(memoryEntriesByCategory(merged).map((group) => [group.title, group.entries.length]))
      .toEqual([["Core memory", 1], ["Saved notes", 1], ["Session history", 1]]);
  });

  it("pages through a document with Previous and Next", () => {
    const page = (offset: number, nextOffset?: number, revision = "r1"): MemoryPage => ({
      document: entry("notes/a.md"), text: "x", offset, nextOffset, revision,
    });
    expect(validMemoryPage(page(0, 16384), "notes/a.md", 0, null)).toBe(true);
    expect(validMemoryPage(page(0, 16384), "notes/b.md", 0, null)).toBe(false);
    expect(validMemoryPage(page(0, 50000), "notes/a.md", 0, null)).toBe(false);
    expect(validMemoryPage(page(16384, 16384), "notes/a.md", 16384, "r1")).toBe(false);
    expect(validMemoryPage(page(16384, 32768, "r2"), "notes/a.md", 16384, "r1")).toBe(false);

    expect(readerRequest(EMPTY_READER, "next")).toBeNull();
    expect(readerRequest(EMPTY_READER, "previous")).toBeNull();
    let reload = readerRequest(EMPTY_READER, "reload")!;
    let state = readerApply(EMPTY_READER, "reload", reload, page(0, 16384));
    const next = readerRequest(state, "next")!;
    expect(next).toEqual({ offset: 16384, index: 1, revision: "r1", fence: null });
    state = readerApply(state, "next", next, page(16384, 32768));
    state = readerApply(state, "next", readerRequest(state, "next")!, page(32768));
    expect(state.offsets).toEqual([0, 16384, 32768]);
    expect(state.pageIndex).toBe(2);
    expect(readerRequest(state, "next")).toBeNull();
    const back = readerRequest(state, "previous")!;
    expect(back).toEqual({ offset: 16384, index: 1, revision: "r1", fence: null });
    state = readerApply(state, "previous", back, page(16384, 32768));
    expect(state.offsets).toEqual([0, 16384, 32768]);
    reload = readerRequest(state, "reload")!;
    state = readerApply(state, "reload", reload, page(0, 16384, "r9"));
    expect(state).toMatchObject({ pageIndex: 0, offsets: [0] });
  });

  it("ends pages at their last line break so each renders as Markdown", () => {
    const page = (text: string, offset: number, nextOffset?: number): MemoryPage => ({
      document: entry("notes/a.md"), text, offset, nextOffset, revision: "r1",
    });
    const split = alignMemoryPage(page("# Notes\n- first item\n- second it", 100, 133));
    expect(split.text).toBe("# Notes\n- first item\n");
    expect(split.nextOffset).toBe(100 + new TextEncoder().encode("# Notes\n- first item\n").length);
    const accented = alignMemoryPage(page("Café ☕️ notes\nhalf a li", 0, 40));
    expect(accented.nextOffset).toBe(new TextEncoder().encode("Café ☕️ notes\n").length);
    expect(alignMemoryPage(page("one\r\ntwo\r\nthr", 0, 13)).text).toBe("one\r\ntwo\r\n");
    for (const same of [page("whole lines\n", 0, 12), page("last page", 0), page("x".repeat(64), 0, 64)]) {
      expect(alignMemoryPage(same)).toEqual(same);
    }
  });

  it("carries a code block that spans pages", () => {
    const opened = codeFenceAfter("Intro\n```swift\nlet a = 1\n", null);
    expect(opened).toEqual({ marker: "`", count: 3 });
    expect(renderableMemory("let b = 2\n```\nAfter", opened)).toBe("```\nlet b = 2\n```\nAfter");
    expect(codeFenceAfter("let b = 2\n```\nAfter\n", opened)).toBeNull();
    expect(codeFenceAfter("~~~~\n```\nstill code\n~~~\n", null)).toEqual({ marker: "~", count: 4 });
    expect(codeFenceAfter("  ~~~~~  \r\n", { marker: "~", count: 4 })).toBeNull();
    expect(codeFenceAfter("Inline ``code`` and `x`\n", null)).toBeNull();
    expect(codeFenceAfter("```\n``` not a close\n", null)).toEqual({ marker: "`", count: 3 });
    expect(renderableMemory("plain", null)).toBe("plain");
  });

  it("pages at line breaks and remembers each page's open code block", () => {
    const first = "# Runbook\n```sh\nmake test\nmake ap";
    const cut = new TextEncoder().encode("# Runbook\n```sh\nmake test\n").length;
    const page = (text: string, offset: number, nextOffset?: number): MemoryPage => ({
      document: { ...entry("notes/a.md"), bytes: 4096 }, text, offset, nextOffset, revision: "r1",
    });
    let state = readerApply(EMPTY_READER, "reload", readerRequest(EMPTY_READER, "reload")!, page(first, 0, first.length));
    expect(state.page?.text).toBe("# Runbook\n```sh\nmake test\n");
    expect(state.pageFence).toBeNull();
    const next = readerRequest(state, "next")!;
    expect(next).toEqual({ offset: cut, index: 1, revision: "r1", fence: { marker: "`", count: 3 } });
    state = readerApply(state, "next", next, page("make app\n```\nDone.\n", cut));
    expect(state.pageFence).toEqual({ marker: "`", count: 3 });
    const back = readerRequest(state, "previous")!;
    expect(back.fence).toBeNull();
    state = readerApply(state, "previous", back, page(first, 0, first.length));
    expect(state.pageFence).toBeNull();
    expect(readerRequest(state, "next")!.fence).toEqual({ marker: "`", count: 3 });
    state = readerApply(state, "reload", readerRequest(state, "reload")!, page("Fresh\n", 0));
    expect(state).toMatchObject({ pageIndex: 0, offsets: [0], fences: [null], pageFence: null });
  });

  it("counts MEMORY.md characters only when the whole file is shown", () => {
    const page: MemoryPage = { document: { ...entry("MEMORY.md", "core"), characterLimit: 3 }, text: "abcd", offset: 0, revision: "r" };
    expect(memoryCharacterCount(page)).toEqual({ text: "4 / 3 characters", over: true });
    expect(memoryCharacterCount({ ...page, nextOffset: 2 })).toBeNull();
    expect(memoryCharacterCount({ ...page, document: entry("notes/a.md") })).toBeNull();
  });
});

describe("GitHub builds", () => {
  const now = Date.parse("2026-09-08T10:30:00Z");
  const checked = new Date(now - 10_000).toISOString().replace(/\.\d+Z$/, "Z");
  const job = (id: string, status: string, assignment: GitHubBuildJob["assignment"], createdAt: string, url?: string): GitHubBuildJob => ({
    id, workflow: "iOS TestFlight", title: "Ship a new app feature", number: 49, attempt: 2, branch: "feature/x", commit: "abc123456789",
    status, job: "Build and upload", step: "Export", createdAt, startedAt: "2026-09-08T09:02:00Z",
    url: url ?? "https://github.com/example/app/actions/runs/50/job/1", assignment,
  });
  const repository = (name: string, jobs: GitHubBuildJob[], change: Partial<GitHubBuildRepository> = {}): GitHubBuildRepository => ({
    repository: `example/${name}`, app: name, runner: `${name}-mac`, runnerStatus: "online", busy: false, checkedAt: checked, jobs, ...change,
  });
  const aggregate: GitHubBuildSnapshot = {
    isRefreshing: false,
    repositories: [
      repository("Busy app", [job("running", "in_progress", "assigned", "2026-09-08T08:00:00Z"),
        job("busy-queue", "queued", "eligible", "2026-09-08T09:00:00Z")], { busy: true }),
      repository("Waiting app", [job("workflow-wait", "pending", "workflow", "2026-09-08T07:00:00Z")]),
      repository("Ready app", [job("ready-queue", "queued", "eligible", "2026-09-08T10:00:00Z")]),
    ],
  };

  it("estimates one queue across all apps", () => {
    const queue = buildQueue(aggregate, true, now);
    expect(queue.map((item) => item.entry.job.id)).toEqual(["ready-queue", "busy-queue", "workflow-wait"]);
    expect(queue.map((item) => item.position)).toEqual([1, 2, 3]);
    expect(queue.filter((item) => item.isUpNext).map((item) => item.entry.job.id)).toEqual(["ready-queue"]);
    expect(queue.map((item) => queueReadiness(item.entry, now)))
      .toEqual([QueueReadiness.Ready, QueueReadiness.RunnerBusy, QueueReadiness.Blocked]);
    expect(queueReason(queue[0].entry, now)).toContain("Runner available");
    expect(queueReason(queue[1].entry, now)).toContain("finish its current work");
    expect(queueReason(queue[2].entry, now)).toContain("eligibility is not yet known");
    expect(buildEntries(aggregate).filter((entry) => entry.job.status === "in_progress").map((entry) => entry.job.id)).toEqual(["running"]);
    expect(snapshotIsComplete(aggregate, now)).toBe(true);
    expect(buildQueue(aggregate, false, now).some((item) => item.isUpNext)).toBe(false);
  });

  it("keeps stale, offline and blocked work visible without an up-next guess", () => {
    const stale = { ...aggregate, repositories: [...aggregate.repositories,
      repository("Stale app", [job("stale", "queued", "eligible", "2026-09-08T06:00:00Z")], { warning: "Runner API failed" })] };
    const queue = buildQueue(stale, true, now);
    expect(queue.map((item) => item.entry.job.id)).toEqual(["ready-queue", "busy-queue", "workflow-wait", "stale"]);
    expect(queueReadiness(queue[3].entry, now)).toBe(QueueReadiness.Unknown);
    expect(queue.some((item) => item.isUpNext)).toBe(false);
    const offline = repository("Off", [job("offline", "queued", "eligible", "2026-09-08T06:00:00Z")], { runnerStatus: "offline" });
    expect(queueReason({ repository: offline, job: offline.jobs[0] }, now)).toBe("Runner Off-mac is offline; cannot predict its start");
    const approval = repository("Gate", [job("approval", "waiting", "eligible", "2026-09-08T06:00:00Z")]);
    expect(queueReason({ repository: approval, job: approval.jobs[0] }, now)).toContain("Waiting on GitHub");
    expect(repositoryIsStale(repository("Old", [], { checkedAt: new Date(now - 121_000).toISOString() }), now)).toBe(true);
    expect(repositoryIsStale(repository("None", [], { checkedAt: undefined }), now)).toBe(true);
    expect(snapshotIsComplete({ repositories: [], isRefreshing: false }, now)).toBe(false);
    expect(snapshotIsComplete({ ...aggregate, error: "Partial" }, now)).toBe(false);
    expect(buildQueue({ repositories: [], isRefreshing: false }, true, now)).toEqual([]);
  });

  it("titles statuses and only links expected GitHub runs", () => {
    expect(jobStatusTitle(job("a", "in_progress", "assigned", ""))).toBe("Running");
    expect(jobStatusTitle(job("a", "in_progress", "eligible", ""))).toBe("Awaiting runner");
    expect(jobStatusTitle(job("a", "queued", "workflow", ""))).toBe("Workflow waiting");
    expect(jobStatusTitle(job("a", "action_required", "eligible", ""))).toBe("Action Required");
    const repo = repository("app", []);
    for (const url of ["https://evil.example/example/app/actions/runs/50", "http://github.com/example/app/actions/runs/50",
      "https://github.com/other/repo/actions/runs/50", "https://user@github.com/example/app/actions/runs/50",
      "https://github.com:8443/example/app/actions/runs/50", "not a url"]) {
      expect(githubURL({ repository: repo, job: job("a", "queued", "eligible", "", url) })).toBeNull();
    }
    expect(githubURL({ repository: repo, job: job("a", "queued", "eligible", "") })).toBe("https://github.com/example/app/actions/runs/50/job/1");
    expect(assignmentText({ repository: repo, job: job("a", "queued", "eligible", "") })).toBe("Eligible for app-mac; not yet assigned");
    expect(buildsPollDelay({ ...aggregate, isRefreshing: true })).toBe(3000);
    expect(buildsPollDelay(aggregate)).toBe(10000);
  });
});

describe("maintenance", () => {
  const snapshot: MaintenanceSnapshot = {
    revision: "R1", available: true, runningBuild: "100", installedBuild: "101", busySessions: 0, branch: "main",
    localChanges: false, commitsBehind: 2, acceptedRequestIDs: [],
  };
  const state = (change: Partial<MaintenanceSnapshot> = {}, rest: Partial<Parameters<typeof canStartMaintenance>[1]> = {}) =>
    ({ snapshot: { ...snapshot, ...change }, isRequesting: false, pending: null, error: null, ...rest });

  it("disables unsafe actions for busy, dirty and stale states", () => {
    expect(canStartMaintenance("update", state())).toBe(true);
    expect(canStartMaintenance("check", state({ busySessions: 2 }))).toBe(true);
    expect(canStartMaintenance("restart", state({ busySessions: 2 }))).toBe(false);
    expect(canStartMaintenance("rebuild", state({ busySessions: 2 }))).toBe(false);
    expect(canStartMaintenance("update", state({ localChanges: true }))).toBe(false);
    expect(canStartMaintenance("rebuild", state({ localChanges: true }))).toBe(true);
    expect(canStartMaintenance("update", state({ branch: "feature" }))).toBe(false);
    expect(canStartMaintenance("restart", state({ installedBuild: undefined }))).toBe(false);
    expect(canStartMaintenance("check", state({ available: false }))).toBe(false);
    expect(canStartMaintenance("check", state({ job: { request: { id: "a", action: "rebuild", revision: "R1" }, phase: "building", message: "", output: "", startedAt: 1 } }))).toBe(false);
    expect(canStartMaintenance("check", state({}, { error: "Offline" }))).toBe(false);
    expect(canStartMaintenance("check", state({}, { pending: { id: "a", action: "check", revision: "R1" } }))).toBe(false);
    expect(canStartMaintenance("check", { snapshot: null, isRequesting: false, pending: null, error: null })).toBe(false);
  });

  it("polls faster while running and keeps uncertain requests", () => {
    expect(maintenancePollDelay(snapshot, null)).toBe(15000);
    expect(maintenancePollDelay(snapshot, { id: "a", action: "check", revision: "R1" })).toBe(3000);
    expect(maintenancePollDelay({ ...snapshot, job: { request: { id: "a", action: "check", revision: "R1" }, phase: "checking", message: "", output: "", startedAt: 1 } }, null)).toBe(3000);
    expect(clearsPendingMaintenance(Object.assign(new Error("Busy Mac tabs"), { status: 409 }))).toBe(true);
    expect(clearsPendingMaintenance(Object.assign(new Error("Unauthorized"), { status: 401 }))).toBe(true);
    expect(clearsPendingMaintenance(Object.assign(new Error("Offline"), { status: 0 }))).toBe(false);
    expect(clearsPendingMaintenance(Object.assign(new Error("Gateway"), { status: 502 }))).toBe(false);
    expect(clearsPendingMaintenance(new NotSentError("Refresh the Mac's maintenance status first."))).toBe(true);
    expect(new NotSentError("Refresh first.").message).toBe("Refresh first. The request was not sent. Check the connection and try again.");
    expect(isMaintenanceRequest({ id: "a", action: "rebuild", revision: "R" })).toBe(true);
    expect(isMaintenanceRequest({ id: "a", action: "reboot", revision: "R" })).toBe(false);
    expect(isMaintenanceRequest(null)).toBe(false);
    expect(endpointHost("HTTPS (mac.example.ts.net)", "Studio")).toBe("mac.example.ts.net");
    expect(endpointHost("Direct, encrypted (192.168.0.94:55331)", "")).toBe("192.168.0.94:55331");
    expect(endpointHost("", "Studio")).toBe("Studio");
    expect(endpointHost("", "")).toBe("Not configured");
  });
});

describe("View Mac framing", () => {
  const leaseID = "6F1C2D3E-1111-4A4A-9B9B-0123456789AB";
  const frameID = "A1B2C3D4-2222-4B4B-8C8C-0123456789CD";
  const rawKey = new Uint8Array(32).map((_, index) => index * 7 + 3);
  const keyBase64 = encodeBase64(rawKey);

  it("uses the exact additional data strings", () => {
    expect(frameAdditionalData(leaseID, frameID, 69733248, 1512, 982))
      .toBe(`cantrip-desktop|${leaseID}|${frameID}|69733248|1512|982`);
    expect(inputAdditionalData(leaseID, 7)).toBe(`cantrip-desktop|${leaseID}|input|7`);
  });

  it("rejects keys that aren't 32 bytes", async () => {
    await expect(importDesktopKey(encodeBase64(new Uint8Array(16)))).rejects.toThrow(INVALID_RESPONSE);
    await expect(importDesktopKey("%%%")).rejects.toThrow(INVALID_RESPONSE);
  });

  it("decrypts a frame sealed in CryptoKit's combined form and binds it to the frame metadata", async () => {
    const key = await importDesktopKey(keyBase64);
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 0xff, 0xd9]);
    const nonce = new Uint8Array(12).fill(9);
    const display = { id: 1, name: "Built-in", x: 0, y: 0, width: 1512, height: 982 };
    const aad = frameAdditionalData(leaseID, frameID, display.id, 1512, 982);
    const combined = await sealCombined(key, jpeg, aad, nonce);
    expect(combined.length).toBe(12 + jpeg.length + 16);
    expect(Array.from(combined.slice(0, 12))).toEqual(Array.from(nonce));
    const frame: DesktopFrame = { id: frameID, display, width: 1512, height: 982, encryptedJPEG: encodeBase64(combined) };
    expect(Array.from(await decryptDesktopFrame(key, leaseID, frame))).toEqual(Array.from(jpeg));
    // Any change to the authenticated metadata fails.
    await expect(decryptDesktopFrame(key, leaseID, { ...frame, width: 1513 })).rejects.toThrow(INVALID_RESPONSE);
    await expect(decryptDesktopFrame(key, "OTHER", frame)).rejects.toThrow(INVALID_RESPONSE);
    await expect(decryptDesktopFrame(key, leaseID, { ...frame, display: { ...display, id: 2 } })).rejects.toThrow(INVALID_RESPONSE);
    await expect(decryptDesktopFrame(key, leaseID, { ...frame, width: 0 })).rejects.toThrow(INVALID_RESPONSE);
    await expect(decryptDesktopFrame(key, leaseID, { ...frame, height: 8193 })).rejects.toThrow(INVALID_RESPONSE);
    await expect(decryptDesktopFrame(key, leaseID, { ...frame, encryptedJPEG: encodeBase64(combined.slice(0, 20)) })).rejects.toThrow(INVALID_RESPONSE);
  });

  it("encrypts input commands with increasing sequence numbers and omits absent fields", async () => {
    const key = await importDesktopKey(keyBase64);
    expect(desktopCommandJSON({ frameID, kind: "click", x: 0.25, y: 0.5 })).toBe(`{"frameID":"${frameID}","kind":"click","x":0.25,"y":0.5}`);
    expect(desktopCommandJSON({ frameID, kind: "key", key: "return" })).toBe(`{"frameID":"${frameID}","kind":"key","key":"return"}`);
    expect(desktopCommandJSON({ frameID, kind: "scroll", delta: -3 })).toBe(`{"frameID":"${frameID}","kind":"scroll","delta":-3}`);
    const encrypted = await encryptDesktopCommand(key, leaseID, 3, { frameID, kind: "text", text: "héllo" });
    const plain = await openCombined(key, decodeBase64(encrypted), inputAdditionalData(leaseID, 3));
    expect(JSON.parse(new TextDecoder().decode(plain))).toEqual({ frameID, kind: "text", text: "héllo" });
    await expect(openCombined(key, decodeBase64(encrypted), inputAdditionalData(leaseID, 4))).rejects.toThrow(INVALID_RESPONSE);
    const again = await encryptDesktopCommand(key, leaseID, 3, { frameID, kind: "text", text: "héllo" });
    expect(again).not.toBe(encrypted);
  });

  it("maps pointers and permission states", () => {
    expect(normalizedPoint(150, 75, { left: 100, top: 50, width: 200, height: 100 })).toEqual({ x: 0.25, y: 0.25 });
    expect(normalizedPoint(500, -5, { left: 100, top: 50, width: 200, height: 100 })).toEqual({ x: 1, y: 0 });
    expect(normalizedPoint(1, 1, { left: 0, top: 0, width: 0, height: 10 })).toBeNull();
    expect(permissionStateLabel("granted")).toBe("Granted");
    expect(permissionStateLabel("checkedWhenUsed")).toBe("Checked when Cantrip reads credentials");
    expect(permissionStateLabel("manualCheck")).toBe("Check on Mac");
    expect(permissionStateLabel("restartRequired")).toBe("Reopen Cantrip on the Mac");
  });
});

describe("text helpers", () => {
  it("capitalizes and describes durations", () => {
    expect(capitalized("high")).toBe("High");
    expect(capitalized("in progress")).toBe("In Progress");
    const now = Date.parse("2026-10-23T08:00:00Z");
    expect(relativeDuration(new Date(now - 3000), now)).toBe("3 seconds");
    expect(relativeDuration(new Date(now - 185_000), now)).toBe("3 minutes, 5 seconds");
    expect(relativeDuration(new Date(now - 3_600_000), now)).toBe("1 hour");
    expect(relativeDuration(new Date(now - 93_784_000), now)).toBe("1 day, 2 hours");
    expect(relativeDuration(new Date(now), now)).toBe("0 seconds");
  });
});

describe("usage limit fallback", () => {
  const snapshot = (backend: string, limited = false) => ({
    backend, primary: "Claude Code", revision: "f1",
    choices: [{ id: "Copilot", label: "Copilot" }, { id: "Codex", label: "Codex" }],
    limited: limited ? [{ backend: "Claude Code", until: "2026-10-28T12:00:00Z", untilLabel: "5:00 AM" }] : [],
  });

  it("shows the saved fallback, or Off when it is the Mac's own backend", async () => {
    const { usageFallbackSelection } = await import("../src/gateway/ui/sheets/sheetLogic");
    expect(usageFallbackSelection(snapshot("Copilot"))).toBe("Copilot");
    expect(usageFallbackSelection(snapshot(""))).toBe("");
    expect(usageFallbackSelection(snapshot("Claude Code"))).toBe("");
  });

  it("names backends at their limit and when they reset", async () => {
    const { usageFallbackStatus } = await import("../src/gateway/ui/sheets/sheetLogic");
    expect(usageFallbackStatus(snapshot("Copilot", true))).toBe("At its usage limit: Claude Code until 5:00 AM.");
    expect(usageFallbackStatus(snapshot("Copilot"))).toContain("every tab");
  });
});
