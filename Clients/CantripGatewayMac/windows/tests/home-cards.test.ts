import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  HomeBackgroundSnapshot, HomeTask, HomeTaskRun, HomeTasksSnapshot, HomeTaskWorkspace, RemoteCardDocument,
} from "../src/gateway/api/types";
import {
  backgroundRunCards, cardDocuments, latestRunCards, MAX_CARDS, parseRecordCards, RECORD_CARDS_MAX_REFRESH_MS,
  RECORD_CARDS_MIN_REFRESH_MS, RECORD_CARDS_REFRESH_MS, RECORD_CARDS_RETRY_MS, RecordCardsPoller, recordCardKinds,
  recordCardsDelay, recordCardsLabel, recordCardsPath, runCards, wantsRecordCards, workspaceCardSpecs, workspaceCards,
  workspaceCardsView,
} from "../src/gateway/ui/home/homeCardLogic";
import { cardParts } from "../src/gateway/ui/transcript/cardLogic";

// Real host output (the Mac's tasks snapshot, Background list and a record's cards) from a QA Mac.
const fixture = <T>(name: string): T =>
  JSON.parse(readFileSync(new URL(`./fixtures/home/${name}.json`, import.meta.url), "utf8")) as T;
const tasks = fixture<HomeTasksSnapshot>("tasks");
const background = fixture<HomeBackgroundSnapshot>("background");
const task = (title: string): HomeTask => tasks.tasks.find((item) => item.title.startsWith(title))!;

const TASK_ID = "7498B1C2-F15C-4312-A403-D568DDD1433E";
const RECORD_ID = "A0AC3AA5-E310-49D3-8F71-24F46CE97542";
const card = (id: string, extra: Partial<RemoteCardDocument> = {}): RemoteCardDocument =>
  ({ version: 1, id, type: "custom", blocks: [{ type: "header", title: id }], ...extra });
const run = (cards: unknown, extra: Partial<HomeTaskRun> = {}): HomeTaskRun =>
  ({ id: "r", startedAt: 1, finishedAt: 2, status: "succeeded", summary: "Done.", cards: cards as RemoteCardDocument[], ...extra });
const workspace = (cards: unknown): Pick<HomeTaskWorkspace, "cards"> => ({ cards: cards as HomeTaskWorkspace["cards"] });

describe("reading Home cards leniently", () => {
  it("keeps only card objects, at most a handful", () => {
    const good = card("a");
    expect(cardDocuments([good, null, "card", 3, [], { id: "no blocks" }, { blocks: "nope" }])).toEqual([good]);
    expect(cardDocuments([{ fallbackText: "Plain text only" }])).toHaveLength(1);
    expect(cardDocuments(Array.from({ length: 20 }, (_, index) => card(String(index))))).toHaveLength(MAX_CARDS);
    for (const value of [undefined, null, "cards", 42, { 0: good }, true]) expect(cardDocuments(value)).toEqual([]);
  });

  it("reads a task run's cards, and none from a malformed run", () => {
    expect(runCards(run([card("a"), card("b")])).map((item) => item.id)).toEqual(["a", "b"]);
    expect(runCards(run(undefined))).toEqual([]);
    expect(runCards(run({ weather: card("a") }))).toEqual([]);
    expect(runCards(null)).toEqual([]);
    expect(runCards("run" as unknown as HomeTaskRun)).toEqual([]);
  });

  it("shows a Background run's cards only once it finished", () => {
    const finished = background.runs.find((item) => item.label === "Personal operations briefing")!;
    expect(backgroundRunCards(finished).map((item) => item.type)).toEqual(["weather", "custom"]);
    expect(backgroundRunCards({ ...finished, status: "running" })).toEqual([]);
    expect(backgroundRunCards({ ...finished, status: "failed" })).toHaveLength(2);
    expect(backgroundRunCards({ ...finished, cards: "broken" as unknown as RemoteCardDocument[] })).toEqual([]);
    expect(backgroundRunCards({ status: "succeeded" })).toEqual([]);
  });

  it("draws every card the QA Mac sent", () => {
    const all = [
      ...backgroundRunCards(background.runs[0]),
      ...task("Personal").runs.flatMap(runCards),
      ...workspaceCards(tasks, task("Bills").id),
      ...parseRecordCards(fixture("record-cards")).cards,
    ];
    expect(all).toHaveLength(7);
    for (const document of all) expect(cardParts(document).length, document.id).toBeGreaterThan(0);
  });
});

describe("a task's latest run cards", () => {
  it("is the newest run's, when it has some", () => {
    const latest = latestRunCards(task("Personal"));
    expect(latest?.run.summary).toContain("clear and cool in Seattle");
    expect(latest?.cards.map((item) => item.accessibilityLabel)).toEqual(["Weather for Seattle, WA", "Today"]);
  });

  it("ignores older runs' cards and malformed runs", () => {
    expect(latestRunCards({ runs: [run(undefined), run([card("old")])] })).toBeNull();
    expect(latestRunCards({ runs: [] })).toBeNull();
    expect(latestRunCards({ runs: undefined as unknown as HomeTaskRun[] })).toBeNull();
    expect(latestRunCards({ runs: [null as unknown as HomeTaskRun] })).toBeNull();
    expect(latestRunCards({ runs: [run([null, "x"])] })).toBeNull();
  });
});

describe("workspace cards", () => {
  it("finds a workspace's cards by task ID", () => {
    const bills = task("Bills");
    const cards = workspaceCards(tasks, bills.id);
    expect(cards.map((item) => item.accessibilityLabel)).toEqual(["Due in the next 7 days, 3 bills · in the next 7 days"]);
    expect(workspaceCards(tasks, bills.id.toLowerCase())).toEqual(cards);
    expect(workspaceCards(tasks, task("Bass").id)).toEqual([]);
  });

  it("ignores a missing or malformed workspaceCards", () => {
    const id = task("Bills").id;
    for (const value of [undefined, null, [], "cards", 7]) {
      expect(workspaceCards({ workspaceCards: value as HomeTasksSnapshot["workspaceCards"] }, id)).toEqual([]);
    }
    expect(workspaceCards({ workspaceCards: { [id]: "broken" as unknown as RemoteCardDocument[] } }, id)).toEqual([]);
    expect(workspaceCards(null, id)).toEqual([]);
    for (const key of ["__proto__", "constructor", "toString"]) expect(workspaceCards(tasks, key)).toEqual([]);
  });

  it("shows the workspace's cards, then its latest run's, and nothing while searching", () => {
    const bills = task("Bills");
    expect(workspaceCardsView(tasks, bills, false)).toEqual({ workspace: workspaceCards(tasks, bills.id), latest: null });
    expect(workspaceCardsView(tasks, bills, true)).toBeNull();
    expect(workspaceCardsView(tasks, task("Bass"), false)).toBeNull();

    const withRun = { ...bills, runs: [run([card("run")], { summary: "Paid two bills." })] };
    const view = workspaceCardsView(tasks, withRun, false);
    expect(view?.workspace).toHaveLength(1);
    expect(view?.latest?.run.summary).toBe("Paid two bills.");
    expect(view?.latest?.cards.map((item) => item.id)).toEqual(["run"]);
    expect(workspaceCardsView({}, withRun, false)?.workspace).toEqual([]);
    expect(workspaceCardsView(tasks, withRun, true)).toBeNull();
  });
});

describe("record cards", () => {
  it("asks for them only when the workspace has a weather or map card", () => {
    expect(wantsRecordCards(task("Bass").workspace)).toBe(true);
    expect(recordCardKinds(task("Bass").workspace)).toEqual({ weather: true, map: true });
    expect(wantsRecordCards(task("Bills").workspace)).toBe(false);
    expect(wantsRecordCards(workspace([{ kind: "map", placeField: "venue" }]))).toBe(true);
    expect(wantsRecordCards(workspace([{ kind: "weather", placeField: "city" }]))).toBe(true);
    for (const cards of [undefined, null, "weather", { kind: "weather" }, [null, "map", { kind: 3 }, { type: "weather" }]]) {
      expect(wantsRecordCards(workspace(cards))).toBe(false);
    }
    expect(wantsRecordCards(undefined)).toBe(false);
    expect(workspaceCardSpecs(workspace([null, { kind: "list" }, "map"]))).toEqual([{ kind: "list" }]);
  });

  it("names the region after what it shows", () => {
    expect(recordCardsLabel(task("Bass").workspace, "Winter Lights Weekend")).toBe("Forecast and map for Winter Lights Weekend");
    expect(recordCardsLabel(workspace([{ kind: "weather" }]), "Trip")).toBe("Forecast for Trip");
    expect(recordCardsLabel(workspace([{ kind: "map" }]), "  ")).toBe("Map");
  });

  it("builds the path from two UUIDs only", () => {
    expect(recordCardsPath(TASK_ID, RECORD_ID)).toBe(`/api/v1/home/tasks/${TASK_ID}/records/${RECORD_ID}/cards`);
    expect(recordCardsPath(TASK_ID.toLowerCase(), RECORD_ID)).toBe(`/api/v1/home/tasks/${TASK_ID.toLowerCase()}/records/${RECORD_ID}/cards`);
    const bad = [
      "", "..", "../sessions", `${TASK_ID}/records`, `${TASK_ID}?x=1`, `${TASK_ID}#x`, ` ${TASK_ID}`, `${TASK_ID}0`,
      "7498B1C2F15C4312A403D568DDD1433E", "7498B1C2-F15C-4312-A403-D568DDD1433G", "%2e%2e", "http://example.com/",
    ];
    for (const value of bad) {
      expect(recordCardsPath(value, RECORD_ID), value).toBeNull();
      expect(recordCardsPath(TASK_ID, value), value).toBeNull();
    }
    expect(recordCardsPath(undefined, RECORD_ID)).toBeNull();
    expect(recordCardsPath(TASK_ID, 42)).toBeNull();
  });

  it("refreshes after the Mac's refreshAfter, within bounds", () => {
    expect(recordCardsDelay(300)).toBe(300_000);
    expect(recordCardsDelay(90)).toBe(90_000);
    for (const value of [undefined, null, 0, -5, Number.NaN, Number.POSITIVE_INFINITY, "300"]) {
      expect(recordCardsDelay(value)).toBe(RECORD_CARDS_REFRESH_MS);
    }
    expect(recordCardsDelay(1)).toBe(RECORD_CARDS_MIN_REFRESH_MS);
    expect(recordCardsDelay(10_000_000)).toBe(RECORD_CARDS_MAX_REFRESH_MS);
  });

  it("parses the Mac's answer and rejects what isn't one", () => {
    const parsed = parseRecordCards(fixture("record-cards"));
    expect(parsed.refreshMs).toBe(300_000);
    expect(parsed.cards.map((item) => item.type)).toEqual(["weather", "places"]);
    expect(parsed.cards[1].blocks.map((block) => block.type)).toEqual(["map", "list"]);
    expect(parseRecordCards({ cards: [] })).toEqual({ cards: [], refreshMs: RECORD_CARDS_REFRESH_MS });
    expect(parseRecordCards({ cards: [card("a"), null, "b"], refreshAfter: "soon" })).toEqual({ cards: [card("a")], refreshMs: RECORD_CARDS_REFRESH_MS });
    for (const value of [null, "cards", [], { error: "task record not found" }, { cards: {} }]) {
      expect(() => parseRecordCards(value)).toThrow();
    }
  });
});

describe("the record cards refresh loop", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  function setup(answers: (() => Promise<unknown>)[]) {
    vi.useFakeTimers();
    const load = vi.fn(() => (answers.shift() ?? (() => Promise.resolve({ cards: [], refreshAfter: 300 })))());
    const shown: string[][] = [];
    const errors: unknown[] = [];
    const poller = new RecordCardsPoller({
      load,
      onCards: (cards) => shown.push(cards.map((item) => item.id)),
      onError: (error) => errors.push(error),
    });
    return { load, shown, errors, poller };
  }

  it("fetches at once and again every refreshAfter seconds", async () => {
    const { load, shown, poller } = setup([
      () => Promise.resolve({ cards: [card("first")], refreshAfter: 30 }),
      () => Promise.resolve({ cards: [card("second")], refreshAfter: 30 }),
    ]);
    poller.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(load).toHaveBeenCalledTimes(1);
    expect(shown).toEqual([["first"]]);
    expect(poller.scheduled).toBe(true);
    await vi.advanceTimersByTimeAsync(29_000);
    expect(load).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(load).toHaveBeenCalledTimes(2);
    expect(shown).toEqual([["first"], ["second"]]);
    poller.stop();
  });

  it("keeps the last cards after a failure and retries a minute later", async () => {
    const { load, shown, errors, poller } = setup([
      () => Promise.resolve({ cards: [card("first")], refreshAfter: 20 }),
      () => Promise.reject(new Error("The Mac didn't answer in time.")),
      () => Promise.resolve({ cards: [card("again")], refreshAfter: 20 }),
    ]);
    poller.start();
    await vi.advanceTimersByTimeAsync(20_000);
    expect(load).toHaveBeenCalledTimes(2);
    expect(errors).toHaveLength(1);
    expect(shown).toEqual([["first"]]);
    await vi.advanceTimersByTimeAsync(RECORD_CARDS_RETRY_MS - 1);
    expect(load).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(load).toHaveBeenCalledTimes(3);
    expect(shown).toEqual([["first"], ["again"]]);
    poller.stop();
  });

  it("treats a malformed answer as a failure", async () => {
    const { load, shown, errors, poller } = setup([() => Promise.resolve({ unexpected: true })]);
    poller.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(shown).toEqual([]);
    expect(errors).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(RECORD_CARDS_RETRY_MS);
    expect(load).toHaveBeenCalledTimes(2);
    poller.stop();
  });

  it("stops fetching when the detail closes", async () => {
    const { load, poller } = setup([]);
    poller.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(poller.scheduled).toBe(true);
    poller.stop();
    expect(poller.scheduled).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(RECORD_CARDS_MAX_REFRESH_MS * 2);
    expect(load).toHaveBeenCalledTimes(1);
    poller.start();
    expect(load).toHaveBeenCalledTimes(1);
  });

  it("drops an answer that arrives after closing, and schedules nothing", async () => {
    let answer: (value: unknown) => void = () => {};
    const { shown, errors, poller } = setup([() => new Promise((resolve) => { answer = resolve; })]);
    poller.start();
    poller.stop();
    answer({ cards: [card("late")], refreshAfter: 30 });
    await vi.advanceTimersByTimeAsync(RECORD_CARDS_MAX_REFRESH_MS);
    expect(shown).toEqual([]);
    expect(errors).toEqual([]);
    expect(poller.scheduled).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });
});
