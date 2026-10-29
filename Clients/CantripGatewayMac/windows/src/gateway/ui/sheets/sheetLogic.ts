// Pure rules behind the tool sheets, ported from the shared Hermes Swift views so they can be unit
// tested: model settings (CantripModelSettings.swift), tab names (ChatTabMetadata.swift), Copilot
// usage (CopilotUsageView.swift), memory paging (CantripMemoryView.swift), GitHub builds
// (GitHubBuildsView.swift), maintenance (CantripMaintenanceView.swift) and View Mac's AES-GCM framing
// (CantripMacAccess.swift). No DOM or API client imports, so it runs under Node.
import type {
  CopilotQuotaBucket, CopilotUsageSnapshot, DesktopCommand, DesktopFrame, GitHubBuildJob, GitHubBuildRepository,
  GitHubBuildSnapshot, MacPermissionState, MaintenanceAction, MaintenanceJob, MaintenanceRequest, MaintenanceSnapshot,
  MemoryCatalog, MemoryCategory, MemoryEntry, MemoryPage, ModelOption, ModelSelection, ModelSettingsSnapshot,
  ModelSettingsUpdateRequest, PrivateLocalConfiguration, RemoteSessionSummary, UsageFallbackSnapshot,
  ClaudeLimitWindow, ClaudeUsageState,
} from "../../api/types";

// MARK: Errors

/** `CantripRemoteError.invalidResponse`. */
export const INVALID_RESPONSE = "Cantrip returned an invalid HTTP response.";

export class InvalidResponseError extends Error {
  constructor() {
    super(INVALID_RESPONSE);
  }
}

/** The HTTP status of an `APIError`-like error (0 when the Mac couldn't be reached). */
export function errorStatus(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null | undefined)?.status;
  return typeof status === "number" ? status : undefined;
}

export function errorText(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

/** 404/405: Cantrip on the Mac predates the route. */
export function isUnsupported(error: unknown): boolean {
  const status = errorStatus(error);
  return status === 404 || status === 405;
}

/** Transport failures and 502/503/504 (`CantripRemoteError.isRouteFailure`). */
export function isRouteFailure(error: unknown): boolean {
  const status = errorStatus(error);
  return status === 0 || status === 502 || status === 503 || status === 504;
}

/** A failed write's message; after a route failure it may still have reached the Mac (CantripRemoteModel.mutate). */
export function writeFailure(error: unknown): string {
  const message = errorText(error);
  if (!isRouteFailure(error) || /may have (gone through|reached)/i.test(message)) return message;
  return `${message} The request may have reached Cantrip. Check the session before sending again.`;
}

// MARK: Text

const graphemes = typeof Intl !== "undefined" && "Segmenter" in Intl
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
  : null;

/** Swift's `String.count` (extended grapheme clusters). */
export function graphemeCount(text: string): number {
  if (!graphemes) return Array.from(text).length;
  let count = 0;
  for (const _ of graphemes.segment(text)) count++;
  return count;
}

/** Foundation's `capitalized`: each whitespace-separated word gets an uppercase first letter. */
export function capitalized(text: string): string {
  return text.replace(/\S+/g, (word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase());
}

export function utf8Length(text: string): number {
  return new TextEncoder().encode(text).length;
}

/** "Oct 23, 2026, 1:08 AM" (`formatted(date: .abbreviated, time: .shortened)`). */
export function formatDateTime(date: Date, locale?: string): string {
  return date.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
}

/** SwiftUI `Text(date, style: .relative)`: the two largest units, e.g. "3 minutes, 5 seconds". */
export function relativeDuration(date: Date, now = Date.now()): string {
  const seconds = Math.floor(Math.abs(now - date.getTime()) / 1000);
  const units: [string, number][] = [["day", 86400], ["hour", 3600], ["minute", 60], ["second", 1]];
  const counts = units.map(([name, size], index) => {
    const larger = index === 0 ? Infinity : units[index - 1][1];
    return { name, count: Math.floor((seconds % larger) / size) };
  });
  const first = counts.findIndex((unit) => unit.count > 0);
  if (first < 0) return "0 seconds";
  return counts.slice(first, first + 2).filter((unit) => unit.count > 0)
    .map((unit) => `${unit.count} ${unit.name}${unit.count === 1 ? "" : "s"}`).join(", ");
}

// MARK: Rename tab (ChatTabMetadata.rename)

export const TAB_NAME_LIMIT = 80;

/** The rename field's starting text: the custom title, else the automatic one. */
export function initialTabName(session: Pick<RemoteSessionSummary, "title" | "customTitle">): string {
  return session.customTitle ? session.customTitle : session.title;
}

/** Whitespace runs collapse to one space; "" means "use the automatic name". */
export function normalizeTabName(name: string): string {
  return name.split(/[\s\u0085]+/).filter(Boolean).join(" ");
}

export function tabNameError(name: string): string | null {
  return graphemeCount(normalizeTabName(name)) > TAB_NAME_LIMIT ? "Tab names must be 80 characters or fewer." : null;
}

// MARK: Model settings (CantripModelSettings.swift)

/** "272k", "1.05M" (CantripModelOption.tokenLabel). */
export function tokenLabel(tokens: number): string {
  const divisor = tokens >= 1_000_000 ? 1_000_000 : tokens >= 1000 ? 1000 : 1;
  const suffix = divisor === 1_000_000 ? "M" : divisor === 1000 ? "k" : "";
  return (tokens / divisor).toFixed(3).replace(/\.?0+$/, "") + suffix;
}

/** "Standard - 272k input" (CantripModelOption.contextLabel); the raw tier without model info. */
export function contextLabel(info: ModelOption | undefined, tier: string): string {
  if (!info) return tier;
  const name = tier === "default" ? "Standard" : tier === "long_context" ? "Long" : tier;
  const budget = tier === "default" ? info.defaultContextPromptTokens
    : tier === "long_context" ? info.longContextPromptTokens : undefined;
  return budget !== undefined ? `${name} - ${tokenLabel(budget)} input` : name;
}

/** The catalog entry for a selection ("" = the CLI's default model). */
export function modelInfo(settings: ModelSettingsSnapshot | null | undefined, selection: ModelSelection): ModelOption | undefined {
  if (!settings) return undefined;
  const id = selection.model === "" ? settings.fileDefaultModel : selection.model;
  return id === undefined ? undefined : settings.models.find((model) => model.id === id);
}

export function modelValidationError(settings: ModelSettingsSnapshot, selection: ModelSelection): string | null {
  const info = modelInfo(settings, selection);
  if (selection.model !== "" && !info) return "This model is no longer in the Mac's catalog.";
  if (selection.effort !== "" && !info?.reasoningEfforts?.includes(selection.effort)) {
    return "Choose a supported effort or Model default.";
  }
  if (selection.contextTier !== "" && !info?.contextTiers?.includes(selection.contextTier)) {
    return "Choose a supported context window or CLI default.";
  }
  return null;
}

/** A picker's values: the supported ones plus the current choice, without "" or repeats. */
export function pickerChoices(values: readonly string[] | undefined, selected: string): string[] {
  const seen = new Set<string>();
  return [...(values ?? []), selected].filter((value) => value !== "" && !seen.has(value) && Boolean(seen.add(value)));
}

/** Choosing a model resets effort and picks Standard context when the model offers it. */
export function selectModel(settings: ModelSettingsSnapshot, selection: ModelSelection, model: string): ModelSelection {
  const next = { ...selection, model, effort: "" };
  const info = modelInfo(settings, next);
  return { ...next, contextTier: info?.contextTiers?.includes("default") ? "default" : "" };
}

/** POST body (CantripModelSettingsChange): only revision and usesDefaults when inheriting. */
export function modelSettingsChange(revision: string, selection: ModelSelection | null): ModelSettingsUpdateRequest {
  if (!selection) return { revision, usesDefaults: true };
  return { revision, usesDefaults: false, model: selection.model, effort: selection.effort, contextTier: selection.contextTier };
}

/** The model settings sheet re-reads every second while the catalog refreshes, at most this many times. */
export const MODEL_REFRESH_POLLS = 30;

// MARK: Private Local (CantripPrivateLocalSettings.swift)

export const DEFAULT_PRIVATE_CONFIGURATION: PrivateLocalConfiguration = {
  baseURL: "http://127.0.0.1:11434", model: "", contextWindow: 8192, systemPrompt: "",
};

/** The "Server model" picker: the server's models plus the typed one, sorted. */
export function privateModelChoices(models: readonly string[], current: string): string[] {
  return [...new Set([...models, current])].sort();
}

/** An integer token count from the field, or null while it isn't one. */
export function parseContextTokens(text: string): number | null {
  const trimmed = text.trim().replace(/[,\s]/g, "");
  if (!/^\d+$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return Number.isSafeInteger(value) ? value : null;
}

// MARK: Copilot usage (CopilotUsageView.swift)

/** ISO-8601 with or without fractional seconds. */
export function copilotDate(value: string | undefined | null): Date | null {
  if (!value) return null;
  const time = Date.parse(value);
  return Number.isNaN(time) ? null : new Date(time);
}

export function isUsageStale(snapshot: CopilotUsageSnapshot, now = Date.now()): boolean {
  const checked = copilotDate(snapshot.checkedAt);
  if (!snapshot.account || snapshot.error !== undefined || !checked || now - checked.getTime() >= 300_000) return true;
  return snapshot.account.buckets.some((bucket) => {
    const observed = copilotDate(bucket.observedAt);
    if (observed && now - observed.getTime() > 600_000) return true;
    const reset = copilotDate(bucket.resetAt);
    return Boolean(reset && now >= reset.getTime());
  });
}

export function primaryBucket(snapshot: CopilotUsageSnapshot | null | undefined): CopilotQuotaBucket | undefined {
  const buckets = snapshot?.account?.buckets ?? [];
  return buckets.find((bucket) => bucket.id === "premium_interactions") ?? buckets[0];
}

export function bucketTitle(bucket: CopilotQuotaBucket): string {
  switch (bucket.id) {
    case "premium_interactions": return bucket.billingMode === "credits" ? "Included AI-credit budget" : "Premium allowance";
    case "chat": return "Chat allowance";
    case "completions": return "Completions allowance";
    default: return "Copilot allowance";
  }
}

export function bucketUnit(bucket: CopilotQuotaBucket): string | null {
  switch (bucket.billingMode) {
    case "credits": return "AI credits";
    case "requests": return "requests";
    default: return null;
  }
}

/** Copilot amounts round down so a budget never looks less used than it is. */
export function copilotAmount(amount: number, compact = false, locale?: string): string {
  if (amount > 0 && amount < 0.01) {
    return "<" + new Intl.NumberFormat(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(0.01);
  }
  if (compact && amount >= 1000) {
    return new Intl.NumberFormat(locale, {
      notation: "compact", minimumFractionDigits: 0, maximumFractionDigits: 1, roundingMode: "floor",
    }).format(amount);
  }
  return new Intl.NumberFormat(locale, { minimumFractionDigits: 0, maximumFractionDigits: 2, roundingMode: "floor" }).format(amount);
}

function decimals(value: number): number {
  const text = String(value);
  if (/e/i.test(text)) return -1;
  const point = text.indexOf(".");
  return point < 0 ? 0 : text.length - point - 1;
}

/** entitlement − remaining in decimal, so binary rounding can't lose a hundredth when formatting down. */
export function usedAmount(entitlement: number, remaining: number): number {
  const places = Math.max(decimals(entitlement), decimals(remaining));
  if (places < 0 || places > 12) return entitlement - remaining;
  const scale = 10 ** places;
  return (Math.round(entitlement * scale) - Math.round(remaining * scale)) / scale;
}

/** "35,577.6 / 1,000,000" (or compact "35.5K / 1M"); null when amounts are missing or inconsistent. */
export function amountRatio(bucket: CopilotQuotaBucket, compact = false, locale?: string): string | null {
  const { remaining, entitlement } = bucket;
  if (bucket.isUnlimited || bucketUnit(bucket) === null || remaining === undefined || entitlement === undefined
    || !Number.isFinite(remaining) || !Number.isFinite(entitlement) || remaining < 0 || entitlement < remaining) return null;
  return `${copilotAmount(usedAmount(entitlement, remaining), compact, locale)} / ${copilotAmount(entitlement, compact, locale)}`;
}

export function percentageSummary(bucket: CopilotQuotaBucket): string | null {
  const percent = bucket.remainingPercent;
  if (percent === undefined || !Number.isFinite(percent)) return null;
  return `${(100 - percent).toFixed(1)}% used / ${percent.toFixed(1)}% remaining`;
}

export function bucketSummary(bucket: CopilotQuotaBucket, locale?: string): string {
  if (bucket.isUnlimited) return `Unlimited ${bucketTitle(bucket).toLowerCase()}`;
  const ratio = amountRatio(bucket, false, locale);
  const unit = bucketUnit(bucket);
  if (ratio && unit) return `${ratio} ${unit} used`;
  if (bucket.billingMode === "credits") return "AI-credit amounts unavailable";
  return percentageSummary(bucket) ?? `${bucketTitle(bucket)}: used amount unavailable`;
}

export function billingText(bucket: CopilotQuotaBucket): string {
  return bucket.billingMode === "credits" ? "Token / AI-credit billing; these are not prompt counts."
    : bucket.billingMode === "requests" ? "Request-based billing" : "Billing units not reported";
}

export function overageAllowedText(bucket: CopilotQuotaBucket): string {
  return bucket.overageAllowed === undefined
    ? "Additional usage: not reported"
    : `Additional usage: ${bucket.overageAllowed ? "enabled" : "disabled"}`;
}

export function overageText(bucket: CopilotQuotaBucket, locale?: string): string | null {
  if (bucket.overage === undefined) return null;
  if (bucket.overage === 0) return "No additional usage reported consumed";
  const units = bucket.billingMode === "requests" ? "requests" : "billing units";
  return `Additional usage consumed: ${new Intl.NumberFormat(locale).format(bucket.overage)} ${units}`;
}

/** The toolbar's compact usage text (CopilotUsageModel.headerText). */
export function usageHeaderText(snapshot: CopilotUsageSnapshot | null, failed: boolean, now = Date.now(), locale?: string): string {
  const bucket = primaryBucket(snapshot);
  if (!snapshot || !bucket) return "--";
  if (failed || isUsageStale(snapshot, now)) return "Stale";
  if (bucket.isUnlimited) return "Unlimited";
  const ratio = amountRatio(bucket, true, locale);
  if (ratio) return ratio;
  if (bucket.billingMode === "credits") return "--";
  const percent = bucket.remainingPercent;
  if (percent === undefined || !Number.isFinite(percent)) return "--";
  return `${(100 - percent).toFixed(1)}%`;
}

/** 2 s while the Mac refreshes the quota, else 60 s. */
export function usagePollDelay(snapshot: CopilotUsageSnapshot | null): number {
  return snapshot?.isRefreshing ? 2000 : 60000;
}

// MARK: Memory (CantripMemoryView.swift)

export const MEMORY_CATEGORY_TITLES: Record<MemoryCategory, string> = {
  core: "Core memory", notes: "Saved notes", sessions: "Session history",
};

export function memoryName(entry: Pick<MemoryEntry, "id">): string {
  const parts = entry.id.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? entry.id;
}

export function memoryTitle(entry: Pick<MemoryEntry, "id">): string {
  switch (entry.id) {
    case "MEMORY.md": return "Environment & conventions";
    case "USER.md": return "About you";
    default: return memoryName(entry);
  }
}

export function memoryCatalogPath(query: string, after?: string | null): string {
  let path = `/api/v1/memory?q=${encodeURIComponent(query)}`;
  if (after != null) path += `&after=${encodeURIComponent(after)}`;
  return path;
}

export function memoryDocumentPath(id: string, offset: number, revision?: string | null): string {
  let path = `/api/v1/memory/document?id=${encodeURIComponent(id)}&offset=${offset}`;
  if (revision != null) path += `&revision=${encodeURIComponent(revision)}`;
  return path;
}

/** A page's cursor must be its last document and must move forward. */
export function validCatalogPage(value: MemoryCatalog, cursor: string | null): boolean {
  if (value.nextCursor === undefined || value.nextCursor === null) return true;
  return value.nextCursor === value.documents[value.documents.length - 1]?.id && value.nextCursor !== cursor;
}

/** Appends a "Load more files" page (skipping repeats), or replaces the list. */
export function mergeCatalog(previous: MemoryCatalog | null, value: MemoryCatalog, more: boolean): MemoryCatalog {
  const documents = more ? [...(previous?.documents ?? [])] : [];
  const existing = new Set(documents.map((entry) => entry.id));
  for (const entry of value.documents) if (!existing.has(entry.id)) documents.push(entry);
  return { enabled: value.enabled, exists: value.exists, documents, nextCursor: value.nextCursor };
}

export function memoryEntriesByCategory(catalog: MemoryCatalog): { category: MemoryCategory; title: string; entries: MemoryEntry[] }[] {
  return (["core", "notes", "sessions"] as const)
    .map((category) => ({ category, title: MEMORY_CATEGORY_TITLES[category], entries: catalog.documents.filter((entry) => entry.category === category) }))
    .filter((group) => group.entries.length > 0);
}

/** The page must be the one asked for, move forward within the file, and keep the file's revision. */
export function validMemoryPage(page: MemoryPage, id: string, offset: number, revision: string | null): boolean {
  return page.document.id === id && page.offset === offset
    && (page.nextOffset === undefined || (page.nextOffset > offset && page.nextOffset <= page.document.bytes))
    && (revision === null || revision === page.revision);
}

export type ReaderDirection = "reload" | "previous" | "next";

/** A ``` or ~~~ code block a memory page leaves open (CantripMemoryMarkdown.Fence). */
export interface CodeFence {
  marker: "`" | "~";
  count: number;
}

export interface ReaderState {
  page: MemoryPage | null;
  pageIndex: number;
  /** Start offset of every page reached so far (Previous walks back through them). */
  offsets: number[];
  /** The code block each page reached so far starts inside. */
  fences: (CodeFence | null)[];
  /** The shown page's entry in `fences`. */
  pageFence: CodeFence | null;
}

export const EMPTY_READER: ReaderState = { page: null, pageIndex: 0, offsets: [0], fences: [null], pageFence: null };

export interface ReaderRequest {
  offset: number;
  index: number;
  revision: string | null;
  fence?: CodeFence | null;
}

/** What to fetch for Reload / Previous / Next (CantripMemoryReaderModel.load), or null when there's nowhere to go. */
export function readerRequest(state: ReaderState, direction: ReaderDirection): ReaderRequest | null {
  switch (direction) {
    case "reload": return { offset: 0, index: 0, revision: null, fence: null };
    case "previous":
      if (state.pageIndex <= 0) return null;
      return {
        offset: state.offsets[state.pageIndex - 1], index: state.pageIndex - 1, revision: state.page?.revision ?? null,
        fence: state.fences[state.pageIndex - 1] ?? null,
      };
    case "next": {
      const page = state.page;
      const next = page?.nextOffset;
      if (!page || next === undefined) return null;
      return {
        offset: next, index: state.pageIndex + 1, revision: page.revision,
        fence: codeFenceAfter(page.text, state.fences[state.pageIndex] ?? null),
      };
    }
  }
}

export function readerApply(state: ReaderState, direction: ReaderDirection, request: { offset: number; index: number; fence?: CodeFence | null }, page: MemoryPage): ReaderState {
  const offsets = direction === "reload" ? [0] : [...state.offsets];
  const fences = direction === "reload" ? [null] : [...state.fences];
  if (request.index === offsets.length) offsets.push(request.offset);
  const fence = request.fence ?? null;
  if (request.index === fences.length) fences.push(fence);
  else fences[request.index] = fence;
  return { page: alignMemoryPage(page), pageIndex: request.index, offsets, fences, pageFence: fence };
}

/**
 * Ends a page that would split a line at its last line break, so each 16 KiB page renders as
 * Markdown on its own; the next page starts at the cut (the host accepts any byte offset).
 */
export function alignMemoryPage(page: MemoryPage): MemoryPage {
  if (page.nextOffset === undefined || page.text.endsWith("\n")) return page;
  const cut = page.text.lastIndexOf("\n");
  if (cut < 0) return page;
  const text = page.text.slice(0, cut + 1);
  return { ...page, text, nextOffset: page.offset + utf8(text).length };
}

/** The ``` or ~~~ code block still open after `text`. */
export function codeFenceAfter(text: string, open: CodeFence | null): CodeFence | null {
  let fence = open;
  for (const line of text.split(/\r\n|\r|\n/)) {
    const trimmed = line.replace(/^[ \t]+/, "");
    const marker = trimmed[0];
    if (marker !== "`" && marker !== "~") continue;
    let count = 0;
    while (trimmed[count] === marker) count++;
    if (count < 3) continue;
    if (fence) {
      if (marker === fence.marker && count >= fence.count && trimmed.slice(count).trim() === "") fence = null;
    } else {
      fence = { marker, count };
    }
  }
  return fence;
}

/** The Markdown to render for a page that may start inside a code block. */
export function renderableMemory(text: string, fence: CodeFence | null): string {
  return fence ? `${fence.marker.repeat(fence.count)}\n${text}` : text;
}

/** "1234 / 2200 characters" for MEMORY.md when the whole file is one page. */
export function memoryCharacterCount(page: MemoryPage): { text: string; over: boolean } | null {
  const cap = page.document.characterLimit;
  if (cap === undefined || page.offset !== 0 || page.nextOffset !== undefined) return null;
  const count = graphemeCount(page.text);
  return { text: `${count} / ${cap} characters`, over: count > cap };
}

// MARK: GitHub builds (GitHubBuildsView.swift)

export interface BuildEntry {
  repository: GitHubBuildRepository;
  job: GitHubBuildJob;
}

/** CantripBuildQueueReadiness, in queue order. */
export const QueueReadiness = { Ready: 0, RunnerBusy: 1, Blocked: 2, Unknown: 3 } as const;
export type QueueReadiness = (typeof QueueReadiness)[keyof typeof QueueReadiness];

export interface BuildQueueItem {
  entry: BuildEntry;
  position: number;
  isUpNext: boolean;
}

function isoDate(value: string | undefined): Date | null {
  return copilotDate(value);
}

export function repositoryCheckedDate(repository: GitHubBuildRepository): Date | null {
  return isoDate(repository.checkedAt);
}

export function repositoryIsStale(repository: GitHubBuildRepository, now = Date.now()): boolean {
  if (repository.warning !== undefined) return true;
  const checked = repositoryCheckedDate(repository);
  return checked ? now - checked.getTime() > 120_000 : true;
}

export function jobIsRunning(job: GitHubBuildJob): boolean {
  return job.assignment === "assigned" && job.status === "in_progress";
}

export function jobStatusTitle(job: GitHubBuildJob): string {
  if (job.assignment === "workflow") return "Workflow waiting";
  switch (job.status) {
    case "in_progress": return jobIsRunning(job) ? "Running" : "Awaiting runner";
    case "queued": return "Queued";
    case "waiting": return "Waiting";
    case "pending": return "Pending";
    case "requested": return "Requested";
    default: return capitalized(job.status.replace(/_/g, " "));
  }
}

function byCreated(a: { created: string; id: string }, b: { created: string; id: string }): number {
  if (a.created !== b.created) return a.created < b.created ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** Every job across repositories, oldest workflow first. */
export function buildEntries(snapshot: GitHubBuildSnapshot): BuildEntry[] {
  return snapshot.repositories
    .flatMap((repository) => repository.jobs.map((job) => ({ repository, job })))
    .sort((a, b) => byCreated({ created: a.job.createdAt, id: a.job.id }, { created: b.job.createdAt, id: b.job.id }));
}

export function snapshotIsComplete(snapshot: GitHubBuildSnapshot, now = Date.now()): boolean {
  return snapshot.error === undefined && snapshot.repositories.length > 0
    && snapshot.repositories.every((repository) => !repositoryIsStale(repository, now));
}

export function queueReadiness(entry: BuildEntry, now = Date.now()): QueueReadiness {
  if (repositoryIsStale(entry.repository, now)) return QueueReadiness.Unknown;
  if (!["assigned", "eligible"].includes(entry.job.assignment) || !["queued", "in_progress"].includes(entry.job.status)
    || entry.repository.runnerStatus !== "online") return QueueReadiness.Blocked;
  return entry.repository.busy || entry.repository.jobs.some(jobIsRunning) ? QueueReadiness.RunnerBusy : QueueReadiness.Ready;
}

export function queueReason(entry: BuildEntry, now = Date.now()): string {
  switch (queueReadiness(entry, now)) {
    case QueueReadiness.Ready: return `Runner available: ${entry.repository.runner}`;
    case QueueReadiness.RunnerBusy: return `Waiting for ${entry.repository.runner} to finish its current work`;
    case QueueReadiness.Unknown: return "Queue position is provisional; runner data is stale or unavailable";
    case QueueReadiness.Blocked:
      if (entry.job.assignment === "workflow") return "Waiting for workflow jobs; runner eligibility is not yet known";
      if (entry.repository.runnerStatus !== "online") {
        return `Runner ${entry.repository.runner} is ${entry.repository.runnerStatus}; cannot predict its start`;
      }
      return "Waiting on GitHub; approval, concurrency, or dependencies may need to clear";
  }
}

/** One estimated queue across all apps: available runners, busy runners, then other waits; oldest first. */
export function buildQueue(snapshot: GitHubBuildSnapshot, canEstimate = true, now = Date.now()): BuildQueueItem[] {
  const pending = buildEntries(snapshot)
    .filter((entry) => !jobIsRunning(entry.job) && entry.job.status !== "completed")
    .map((entry) => ({ entry, readiness: queueReadiness(entry, now) }))
    .sort((a, b) => a.readiness - b.readiness
      || byCreated({ created: a.entry.job.createdAt, id: a.entry.job.id }, { created: b.entry.job.createdAt, id: b.entry.job.id }));
  const nextID = canEstimate && snapshotIsComplete(snapshot, now)
    ? pending.find((item) => item.readiness === QueueReadiness.Ready || item.readiness === QueueReadiness.RunnerBusy)?.entry.job.id
    : undefined;
  return pending.map((item, index) => ({ entry: item.entry, position: index + 1, isUpNext: item.entry.job.id === nextID }));
}

/** Only https://github.com/<repository>/actions/runs/… links open. */
export function githubURL(entry: BuildEntry): string | null {
  let url: URL;
  try { url = new URL(entry.job.url); } catch { return null; }
  if (url.protocol !== "https:" || url.hostname !== "github.com" || url.username || url.password || url.port) return null;
  if (!decodeURIComponent(url.pathname).startsWith(`/${entry.repository.repository}/actions/runs/`)) return null;
  return url.href;
}

export function assignmentText(entry: BuildEntry): string {
  switch (entry.job.assignment) {
    case "assigned": return `Runner: ${entry.repository.runner}`;
    case "eligible": return `Eligible for ${entry.repository.runner}; not yet assigned`;
    default: return "Repository workflow; runner eligibility not yet known";
  }
}

export function runnerStatusText(repository: GitHubBuildRepository, now = Date.now()): string {
  return repositoryIsStale(repository, now)
    ? "Status unavailable / stale"
    : `${capitalized(repository.runnerStatus)} - ${repository.busy ? "Busy" : "Idle"}`;
}

/** 3 s while the Mac refreshes GitHub, else 10 s. */
export function buildsPollDelay(snapshot: GitHubBuildSnapshot | null): number {
  return snapshot?.isRefreshing ? 3000 : 10000;
}

// MARK: Maintenance (CantripMaintenanceView.swift)

export const MAINTENANCE_ACTION_INFO: Record<MaintenanceAction, { title: string; detail: string }> = {
  check: {
    title: "Check for Updates",
    detail: "Fetch the latest origin/main commits without changing source or restarting.",
  },
  update: {
    title: "Update & Rebuild",
    detail: "Fast-forward the Mac's clean main branch, then build and sign Cantrip. Local edits are never stashed or discarded. Restart separately to activate the new build.",
  },
  rebuild: {
    title: "Rebuild Current Source",
    detail: "Build and sign the source currently on the Mac, including local edits, without pulling updates. Restart separately to activate it.",
  },
  restart: {
    title: "Restart Cantrip",
    detail: "Briefly disconnect all remote clients and reopen Cantrip. The Mac will refuse if any tab, queue, or shell command is busy.",
  },
};

export function maintenanceJobRunning(job: MaintenanceJob | undefined | null): boolean {
  return Boolean(job && job.finishedAt === undefined);
}

export function canStartMaintenance(action: MaintenanceAction, state: {
  snapshot: MaintenanceSnapshot | null; isRequesting: boolean; pending: MaintenanceRequest | null; error: string | null;
}): boolean {
  const { snapshot } = state;
  if (state.isRequesting || state.pending || state.error !== null || !snapshot || !snapshot.available
    || maintenanceJobRunning(snapshot.job)) return false;
  if (action === "update" && (snapshot.localChanges === true || (snapshot.branch !== undefined && snapshot.branch !== "main"))) return false;
  if (action === "restart" && snapshot.installedBuild === undefined) return false;
  return action === "check" || snapshot.busySessions === 0;
}

/** 3 s while a job runs or a request awaits its receipt, else 15 s. */
export function maintenancePollDelay(snapshot: MaintenanceSnapshot | null, pending: MaintenanceRequest | null): number {
  return maintenanceJobRunning(snapshot?.job) || pending ? 3000 : 15000;
}

/** A definite rejection (4xx, nothing sent) clears the saved request; an uncertain one keeps its ID for a safe retry. */
export function clearsPendingMaintenance(error: unknown): boolean {
  if (error instanceof NotSentError) return true;
  const status = errorStatus(error);
  return status !== undefined && status >= 400 && status < 500;
}

/** `CantripRemoteError.notSent`. */
export class NotSentError extends Error {
  constructor(message: string) {
    super(`${message} The request was not sent. Check the connection and try again.`);
  }
}

export function isMaintenanceRequest(value: unknown): value is MaintenanceRequest {
  const request = value as Partial<MaintenanceRequest> | null;
  return typeof request === "object" && request !== null && typeof request.id === "string" && typeof request.revision === "string"
    && (request.action === "check" || request.action === "update" || request.action === "rebuild" || request.action === "restart");
}

export function busySessionsText(count: number): string {
  return `${count} busy Mac tab(s). Builds and restart require idle tabs.`;
}

/** The connected Mac's host for the maintenance header (CantripRemoteModel.endpointHost). */
export function endpointHost(route: string, server: string): string {
  const inner = /\(([^()]+)\)\s*$/.exec(route)?.[1];
  return inner || server || route || "Not configured";
}

// MARK: Mac access and View Mac (CantripMacAccess.swift)

export function permissionStateLabel(state: MacPermissionState | string): string {
  switch (state) {
    case "granted": return "Granted";
    case "notGranted": return "Not granted";
    case "restartRequired": return "Reopen Cantrip on the Mac";
    case "needsAttention": return "Needs attention";
    case "checkedWhenUsed": return "Checked when Cantrip reads credentials";
    case "localBiometricsAvailable": return "Available on the Mac only";
    case "localPasswordRequired": return "Authenticate on the Mac";
    default: return "Check on Mac";
  }
}

/** Typed text is limited to 4096 UTF-8 bytes per input command. */
export const DESKTOP_TEXT_LIMIT = 4096;
export const DESKTOP_KEY_BUTTONS = ["return", "tab", "escape", "delete", "left", "right", "up", "down"] as const;
const MAX_FRAME_BYTES = 8 * 1024 * 1024;

/** AAD for a frame: "cantrip-desktop|<leaseID>|<frameID>|<displayID>|<width>|<height>" (IDs as the Mac sent them). */
export function frameAdditionalData(leaseID: string, frameID: string, displayID: number, width: number, height: number): string {
  return `cantrip-desktop|${leaseID}|${frameID}|${displayID}|${width}|${height}`;
}

/** AAD for an input command: "cantrip-desktop|<leaseID>|input|<sequence>". */
export function inputAdditionalData(leaseID: string, sequence: number): string {
  return `cantrip-desktop|${leaseID}|input|${sequence}`;
}

export function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export function encodeBase64(bytes: Uint8Array): string {
  let result = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    result += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(result);
}

function utf8(text: string): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(text) as Uint8Array<ArrayBuffer>;
}

/** The lease's base64 AES-256 key (exactly 32 bytes) as a WebCrypto key. */
export async function importDesktopKey(base64: string): Promise<CryptoKey> {
  let raw: Uint8Array<ArrayBuffer>;
  try { raw = decodeBase64(base64); } catch { throw new InvalidResponseError(); }
  if (raw.length !== 32) throw new InvalidResponseError();
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

/** CryptoKit's AES.GCM "combined" form: nonce[12] ‖ ciphertext ‖ tag[16]. */
export async function sealCombined(key: CryptoKey, plaintext: Uint8Array<ArrayBuffer>, additionalData: string,
  nonce: Uint8Array<ArrayBuffer> = crypto.getRandomValues(new Uint8Array(12))): Promise<Uint8Array<ArrayBuffer>> {
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: utf8(additionalData) }, key, plaintext));
  const combined = new Uint8Array(nonce.length + sealed.length);
  combined.set(nonce);
  combined.set(sealed, nonce.length);
  return combined;
}

export async function openCombined(key: CryptoKey, combined: Uint8Array<ArrayBuffer>, additionalData: string): Promise<Uint8Array<ArrayBuffer>> {
  if (combined.length < 28) throw new InvalidResponseError();
  try {
    return new Uint8Array(await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: combined.slice(0, 12), additionalData: utf8(additionalData) }, key, combined.slice(12)));
  } catch {
    throw new InvalidResponseError();
  }
}

/** A frame's JPEG bytes (CantripDesktopFrame.decrypt), authenticated against this lease, frame and display. */
export async function decryptDesktopFrame(key: CryptoKey, leaseID: string, frame: DesktopFrame): Promise<Uint8Array<ArrayBuffer>> {
  const valid = (value: number) => Number.isInteger(value) && value >= 1 && value <= 8192;
  if (!valid(frame.width) || !valid(frame.height) || frame.encryptedJPEG.length > Math.ceil(MAX_FRAME_BYTES / 3) * 4) {
    throw new InvalidResponseError();
  }
  let encrypted: Uint8Array<ArrayBuffer>;
  try { encrypted = decodeBase64(frame.encryptedJPEG); } catch { throw new InvalidResponseError(); }
  if (encrypted.length > MAX_FRAME_BYTES) throw new InvalidResponseError();
  return openCombined(key, encrypted, frameAdditionalData(leaseID, frame.id, frame.display.id, frame.width, frame.height));
}

/** The command's JSON with absent fields omitted (Swift's JSONEncoder skips nil optionals). */
export function desktopCommandJSON(command: DesktopCommand): string {
  const value: Record<string, unknown> = { frameID: command.frameID, kind: command.kind };
  if (command.x !== undefined) value.x = command.x;
  if (command.y !== undefined) value.y = command.y;
  if (command.text !== undefined) value.text = command.text;
  if (command.key !== undefined) value.key = command.key;
  if (command.delta !== undefined) value.delta = command.delta;
  return JSON.stringify(value);
}

/** base64(combined AES-GCM of the command JSON), bound to this lease and sequence number. */
export async function encryptDesktopCommand(key: CryptoKey, leaseID: string, sequence: number, command: DesktopCommand,
  nonce?: Uint8Array<ArrayBuffer>): Promise<string> {
  return encodeBase64(await sealCombined(key, utf8(desktopCommandJSON(command)), inputAdditionalData(leaseID, sequence), nonce));
}

/** A pointer position as 0…1 of the shown frame. */
export function normalizedPoint(clientX: number, clientY: number, rect: { left: number; top: number; width: number; height: number }): { x: number; y: number } | null {
  if (!(rect.width > 0) || !(rect.height > 0)) return null;
  const clamp = (value: number) => Math.min(1, Math.max(0, value));
  return { x: clamp((clientX - rect.left) / rect.width), y: clamp((clientY - rect.top) / rect.height) };
}

/** The fallback picker's value: "" when off or set to a backend that is now the Mac's own. */
export function usageFallbackSelection(value: UsageFallbackSnapshot): string {
  return value.choices.some((choice) => choice.id === value.backend) ? value.backend : "";
}

/** The status line under the fallback picker (CantripUsageFallback.status). */
export function usageFallbackStatus(value: UsageFallbackSnapshot): string {
  return value.limited.length
    ? `At its usage limit: ${value.limited.map((entry) => `${entry.backend} until ${entry.untilLabel}`).join(", ")}.`
    : "New messages from every tab move there until the limit resets. Council seats and Private Local tabs don't switch.";
}

/** ClaudeLimitWindow.title. */
export function claudeWindowTitle(window: ClaudeLimitWindow): string {
  switch (window.id) {
    case "five_hour": return "5-hour session";
    case "seven_day": return "Weekly limit";
    case "seven_day_opus": return "Weekly Opus limit";
    case "seven_day_sonnet": return "Weekly Sonnet limit";
    default: return "Claude limit";
  }
}

export function claudeWindowExhausted(window: ClaudeLimitWindow): boolean {
  return window.lockedReason !== undefined || window.percentUsed >= 100;
}

/** "warning" at the API's warning or 80%, "critical" when it's full or the API says so. */
export function claudeWindowTone(window: ClaudeLimitWindow): "normal" | "warning" | "critical" {
  if (claudeWindowExhausted(window) || window.severity === "critical") return "critical";
  if (window.severity === "warning" || window.percentUsed >= 80) return "warning";
  return "normal";
}

/** ClaudeUsageState.isStale: older than ten minutes, or a window reset since it was read. */
export function isClaudeUsageStale(state: ClaudeUsageState, now: number): boolean {
  const checked = state.checkedAt ? Date.parse(state.checkedAt) : NaN;
  if (!state.account || Number.isNaN(checked) || now - checked >= 600_000) return true;
  return state.account.windows.some((window) => {
    const reset = window.resetsAt ? Date.parse(window.resetsAt) : NaN;
    return !Number.isNaN(reset) && now >= reset;
  });
}
