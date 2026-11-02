import { describe, expect, it } from "vitest";
import type { BackendCommand, BackendCommandsResponse } from "../src/gateway/api/types";
import {
  chooseCommand, commandHint, commandLabel, commandTitle, COMMANDS_MAX_AGE_MS, COMMANDS_RETRY_MS, CommandsCache, countAnnouncement, defaultHighlight,
  firstChoosable, matchCommands, MAX_SUGGESTIONS, moveHighlight, slashToken, validCommandsResponse,
} from "../src/gateway/state/slashCommands";

// The contract's generic fixture (no real skill names).
const FIXTURE: BackendCommandsResponse = {
  backend: "Copilot", workdir: "/tmp/project", revision: "r1", status: null, commands: [
    { name: "plan", description: "Create an implementation plan before coding", kind: "builtin", source: "Copilot", inputHint: "prompt", requiresInput: false, aliases: [], insert: "/plan ", availability: "runs", note: null, action: null },
    { name: "usage", description: "Display session usage metrics and statistics", kind: "builtin", source: "Copilot", inputHint: null, requiresInput: false, aliases: [], insert: "/usage ", availability: "runs", note: null, action: null },
    { name: "model", description: "Select the AI model for this session", kind: "builtin", source: "Copilot", inputHint: "model", requiresInput: false, aliases: [], insert: "/model ", availability: "cantrip", note: "Opens this tab's model settings.", action: "modelSettings" },
    { name: "allow-all", description: "Enable all permissions", kind: "builtin", source: "Copilot", inputHint: "[on|off|show]", requiresInput: false, aliases: ["yolo"], insert: "/allow-all ", availability: "unavailable", note: "Cantrip's approval settings decide what Copilot may do in this tab.", action: null },
    { name: "fixture-skill", description: "Fixture project skill for tests", kind: "skill", source: "Project", inputHint: "instructions for the skill", requiresInput: false, aliases: [], insert: "/fixture-skill ", availability: "runs", note: null, action: null },
    { name: "review-helper", description: "Review the current diff", kind: "custom", source: "Personal", inputHint: null, requiresInput: false, aliases: [], insert: "/review-helper ", availability: "runs", note: null, action: null },
  ],
};
const COMMANDS = FIXTURE.commands;
const byName = (name: string): BackendCommand => COMMANDS.find((command) => command.name === name)!;

function command(name: string, extra: Partial<BackendCommand> = {}): BackendCommand {
  return { name, description: "", kind: "builtin", source: "Copilot", inputHint: null, requiresInput: false, aliases: [], insert: `/${name} `, availability: "runs", note: null, action: null, ...extra };
}

/** Names and scores for composer text, plus the default highlight; null when no list shows. */
function suggest(text: string) {
  const token = slashToken(text);
  if (token === null) return null;
  const matches = matchCommands(COMMANDS, token);
  return {
    rows: matches.map((match) => [match.command.name, match.score]),
    highlight: defaultHighlight(matches, token),
  };
}

describe("slashToken", () => {
  it("returns the lowercased token after a leading slash", () => {
    expect(slashToken("/")).toBe("");
    expect(slashToken("/PL")).toBe("pl");
    expect(slashToken("/fixture-skill")).toBe("fixture-skill");
  });

  it("closes for paths, spaces, newlines, leading whitespace and non-slash text", () => {
    expect(slashToken("/tmp/x")).toBeNull();
    expect(slashToken("/Users/someone")).toBeNull();
    expect(slashToken("/plan x")).toBeNull();
    expect(slashToken("/plan ")).toBeNull();
    expect(slashToken(" /plan")).toBeNull();
    expect(slashToken("\t/plan")).toBeNull();
    expect(slashToken("/plan\n")).toBeNull();
    expect(slashToken("/plan\nmore")).toBeNull();
    expect(slashToken("plan")).toBeNull();
    expect(slashToken("$imagegen")).toBeNull();
    expect(slashToken("")).toBeNull();
  });
});

describe("matchCommands with the contract fixture", () => {
  it('"/" lists everything with unavailable last and nothing highlighted', () => {
    expect(suggest("/")).toEqual({
      rows: [["plan", 1], ["usage", 1], ["model", 1], ["fixture-skill", 1], ["review-helper", 1], ["allow-all", 1]],
      highlight: null,
    });
  });

  it('"/u" highlights usage, then fixture-skill by containment', () => {
    expect(suggest("/u")).toEqual({ rows: [["usage", 1], ["fixture-skill", 3]], highlight: 0 });
  });

  it('"/pl" highlights plan only', () => {
    expect(suggest("/pl")).toEqual({ rows: [["plan", 1]], highlight: 0 });
  });

  it('"/re" highlights review-helper, then fixture-skill ("fixture" contains "re")', () => {
    expect(suggest("/re")).toEqual({ rows: [["review-helper", 1], ["fixture-skill", 3]], highlight: 0 });
  });

  it('"/yo" finds allow-all by alias but never highlights an unavailable row', () => {
    expect(suggest("/yo")).toEqual({ rows: [["allow-all", 2]], highlight: null });
  });

  it("shows no list for a path, a typed argument or a leading space", () => {
    expect(suggest("/tmp/x")).toBeNull();
    expect(suggest("/plan x")).toBeNull();
    expect(suggest(" /plan")).toBeNull();
  });

  it("is case-insensitive and scores an exact name 0", () => {
    expect(suggest("/PLAN")).toEqual({ rows: [["plan", 0]], highlight: 0 });
    expect(suggest("/Usage")?.rows[0]).toEqual(["usage", 0]);
  });

  it("matches names without separators, and description words only from two characters", () => {
    expect(suggest("/fixtureskill")?.rows).toEqual([["fixture-skill", 3]]);
    expect(suggest("/wall")?.rows).toEqual([["allow-all", 3]]);
    // "metrics" in usage's description; no highlight for a description-only match.
    expect(suggest("/metr")).toEqual({ rows: [["usage", 4]], highlight: null });
    expect(suggest("/c")?.rows).toEqual([]);
    expect(suggest("/co")?.rows).toEqual([["plan", 4]]);
    expect(suggest("/di")?.rows).toEqual([["usage", 4], ["review-helper", 4]]);
  });

  it("orders by score then host order, and keeps unavailable rows last", () => {
    const commands = [
      command("zeta-plan"), command("plan-b", { availability: "unavailable" }), command("plan"), command("planner"),
    ];
    expect(matchCommands(commands, "plan").map((match) => [match.command.name, match.score])).toEqual([
      ["plan", 0], ["planner", 1], ["zeta-plan", 3], ["plan-b", 1],
    ]);
  });

  it("shows at most 50 rows", () => {
    const many = Array.from({ length: 80 }, (_, index) => command(`cmd${index}`));
    expect(matchCommands(many, "")).toHaveLength(MAX_SUGGESTIONS);
    expect(matchCommands(many, "cmd").at(-1)?.command.name).toBe("cmd49");
  });

  it("doesn't match every command for a token of separators only", () => {
    expect(matchCommands(COMMANDS, "-").map((match) => match.command.name)).toEqual(["fixture-skill", "review-helper", "allow-all"]);
  });

  it("highlights only scores up to 2 for a typed token", () => {
    const matches = matchCommands(COMMANDS, "view");
    expect(matches.map((match) => match.score)).toEqual([3]);
    expect(defaultHighlight(matches, "view")).toBeNull();
    expect(defaultHighlight(matchCommands(COMMANDS, "usage"), "usage")).toBe(0);
  });
});

describe("moving the highlight", () => {
  const matches = matchCommands(COMMANDS, "");

  it("wraps and skips unavailable rows", () => {
    expect(matches.at(-1)?.command.name).toBe("allow-all");
    expect(moveHighlight(matches, null, 1)).toBe(0);
    expect(moveHighlight(matches, null, -1)).toBe(4);
    expect(moveHighlight(matches, 4, 1)).toBe(0);
    expect(moveHighlight(matches, 0, -1)).toBe(4);
    expect(moveHighlight(matches, 1, 1)).toBe(2);
  });

  it("finds nothing when every row is unavailable", () => {
    const only = matchCommands(COMMANDS, "yo");
    expect(moveHighlight(only, null, 1)).toBeNull();
    expect(firstChoosable(only)).toBeNull();
    expect(firstChoosable(matches)).toBe(0);
  });
});

describe("chooseCommand", () => {
  it("never chooses an unavailable row", () => {
    expect(chooseCommand(byName("allow-all"), "return", true)).toBeNull();
    expect(chooseCommand(byName("allow-all"), "tab", true)).toBeNull();
  });

  it("Return sends a command that takes nothing, trimmed", () => {
    expect(chooseCommand(byName("usage"), "return", true)).toEqual({ text: "/usage", send: true, openModelSettings: false });
    expect(chooseCommand(byName("review-helper"), "return", false)).toEqual({ text: "/review-helper", send: true, openModelSettings: false });
  });

  it("Return inserts a command with an input hint or required input and keeps the space", () => {
    expect(chooseCommand(byName("plan"), "return", true)).toEqual({ text: "/plan ", send: false, openModelSettings: false });
    expect(chooseCommand(byName("fixture-skill"), "return", true)).toEqual({ text: "/fixture-skill ", send: false, openModelSettings: false });
    expect(chooseCommand(command("ask", { requiresInput: true }), "return", true)).toEqual({ text: "/ask ", send: false, openModelSettings: false });
    expect(chooseCommand(command("blank-hint", { inputHint: "  " }), "return", true)?.send).toBe(true);
  });

  it("Tab only inserts, even for a command that would run", () => {
    expect(chooseCommand(byName("usage"), "tab", true)).toEqual({ text: "/usage ", send: false, openModelSettings: false });
    expect(chooseCommand(byName("plan"), "tab", true)).toEqual({ text: "/plan ", send: false, openModelSettings: false });
  });

  it('inserts exactly the host\'s text, such as a Codex "$skill "', () => {
    const skill = command("imagegen", { kind: "skill", source: "System", insert: "$imagegen ", inputHint: "prompt" });
    expect(chooseCommand(skill, "tab", false)).toEqual({ text: "$imagegen ", send: false, openModelSettings: false });
    expect(chooseCommand(skill, "return", false)).toEqual({ text: "$imagegen ", send: false, openModelSettings: false });
    expect(slashToken("$imagegen ")).toBeNull();
  });

  it("opens model settings for the modelSettings action when the session supports it, else inserts", () => {
    expect(chooseCommand(byName("model"), "return", true)).toEqual({ text: "", send: false, openModelSettings: true });
    expect(chooseCommand(byName("model"), "tab", true)).toEqual({ text: "", send: false, openModelSettings: true });
    expect(chooseCommand(byName("model"), "return", false)).toEqual({ text: "/model ", send: false, openModelSettings: false });
    expect(chooseCommand(command("other", { availability: "cantrip", action: "somethingNew" }), "return", true))
      .toEqual({ text: "/other", send: true, openModelSettings: false });
  });
});

describe("accessibility text", () => {
  it("labels rows /name, description, source and note", () => {
    expect(commandLabel(byName("plan"))).toBe("/plan, Create an implementation plan before coding, Copilot");
    expect(commandLabel(byName("allow-all"))).toBe("/allow-all, Enable all permissions, Copilot, Cantrip's approval settings decide what Copilot may do in this tab.");
  });

  it("titles rows with the first word of their insert text, also in the label", () => {
    expect(commandTitle(byName("plan"))).toBe("/plan");
    const skill = command("imagegen", { kind: "skill", source: "System", description: "Generate an image", insert: "$imagegen " });
    expect(commandTitle(skill)).toBe("$imagegen");
    expect(commandLabel(skill)).toBe("$imagegen, Generate an image, System");
    // Matching still uses the name.
    expect(matchCommands([skill], "image").map((match) => match.score)).toEqual([1]);
    expect(commandTitle(command("fallback", { insert: " " }))).toBe("/fallback");
  });

  it("hints whether a row runs or inserts", () => {
    expect(commandHint(byName("usage"), true)).toBe("Runs the command");
    expect(commandHint(byName("plan"), true)).toBe("Inserts the command");
    expect(commandHint(byName("model"), true)).toBe("Opens model settings");
    expect(commandHint(byName("model"), false)).toBe("Inserts the command");
    expect(commandHint(byName("allow-all"), true)).toBeNull();
  });

  it("announces the count", () => {
    expect(countAnnouncement(1)).toBe("1 command");
    expect(countAnnouncement(12)).toBe("12 commands");
  });
});

// MARK: Cache

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function harness() {
  let now = 1_000_000;
  const calls: { id: string; request: ReturnType<typeof deferred<unknown>> }[] = [];
  let changes = 0;
  const cache = new CommandsCache((id) => {
    const request = deferred<unknown>();
    calls.push({ id, request });
    return request.promise;
  }, { now: () => now, onChange: () => { changes++; } });
  return {
    cache, calls,
    advance(ms: number) { now += ms; },
    get changes() { return changes; },
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const SESSION = { id: "A", workdir: "/tmp/project", modelSettingsRevision: "m1", supportsBackendCommands: true };

describe("CommandsCache", () => {
  it("never fetches for a session without supportsBackendCommands (older hosts)", () => {
    const { cache, calls } = harness();
    expect(cache.refresh({ id: "A", workdir: "/x", modelSettingsRevision: "m" })).toBe(false);
    expect(cache.refresh({ ...SESSION, supportsBackendCommands: false })).toBe(false);
    expect(calls).toHaveLength(0);
    expect(cache.get("A")).toBeNull();
  });

  it("loads once, shows loading, then caches for 30 s", async () => {
    const test = harness();
    expect(test.cache.refresh(SESSION)).toBe(true);
    expect(test.cache.get("A")).toEqual({ response: null, loading: true });
    expect(test.cache.refresh(SESSION)).toBe(false);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    expect(test.cache.get("A")).toEqual({ response: FIXTURE, loading: false });
    test.advance(COMMANDS_MAX_AGE_MS - 1);
    expect(test.cache.refresh(SESSION)).toBe(false);
    test.advance(1);
    expect(test.cache.refresh(SESSION)).toBe(true);
    // The cached list keeps showing while it refreshes.
    expect(test.cache.get("A")).toEqual({ response: FIXTURE, loading: true });
    expect(test.calls).toHaveLength(2);
  });

  it("keeps the same object when the revision didn't change", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    test.advance(COMMANDS_MAX_AGE_MS);
    test.cache.refresh(SESSION);
    test.calls[1].request.resolve({ ...FIXTURE });
    await settle();
    expect(test.cache.get("A")?.response).toBe(FIXTURE);
  });

  it("refetches at once and drops the old list when the workdir or model settings change", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    expect(test.cache.refresh({ ...SESSION, modelSettingsRevision: "m2" })).toBe(true);
    expect(test.cache.get("A")).toEqual({ response: null, loading: true });
    const codex = { ...FIXTURE, backend: "Codex", revision: "r2", commands: [command("imagegen", { insert: "$imagegen " })] };
    test.calls[1].request.resolve(codex);
    await settle();
    expect(test.cache.get("A")?.response).toBe(codex);
    expect(test.cache.refresh({ ...SESSION, modelSettingsRevision: "m2", workdir: "/tmp/other" })).toBe(true);
    expect(test.calls).toHaveLength(3);
  });

  it("drops a stale answer that arrives after a newer request", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.cache.refresh({ ...SESSION, workdir: "/tmp/other" });
    const newer = { ...FIXTURE, workdir: "/tmp/other", revision: "r2" };
    test.calls[1].request.resolve(newer);
    await settle();
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    expect(test.cache.get("A")).toEqual({ response: newer, loading: false });
  });

  it("keeps lists per session id", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.cache.refresh({ ...SESSION, id: "B" });
    const other = { ...FIXTURE, backend: "Claude Code", revision: "rb", commands: [command("review")] };
    test.calls[1].request.resolve(other);
    await settle();
    expect(test.cache.get("A")).toEqual({ response: null, loading: true });
    expect(test.cache.get("B")?.response).toBe(other);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    expect(test.cache.get("A")?.response).toBe(FIXTURE);
    expect(test.cache.get("B")?.response).toBe(other);
    expect(test.calls.map((call) => call.id)).toEqual(["A", "B"]);
  });

  it("shows nothing after a failed first fetch and retries on a later entry", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.calls[0].request.reject(new Error("offline"));
    await settle();
    expect(test.cache.get("A")).toEqual({ response: null, loading: false });
    expect(test.cache.refresh(SESSION)).toBe(false);
    test.advance(COMMANDS_RETRY_MS);
    expect(test.cache.refresh(SESSION)).toBe(true);
  });

  it("keeps the cached list when a refetch fails", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    test.advance(COMMANDS_MAX_AGE_MS);
    test.cache.refresh(SESSION);
    test.calls[1].request.reject(new Error("timed out"));
    await settle();
    expect(test.cache.get("A")).toEqual({ response: FIXTURE, loading: false });
  });

  it("treats a malformed answer as a failure and drops malformed rows", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    test.calls[0].request.resolve({ error: "nope" });
    await settle();
    expect(test.cache.get("A")).toEqual({ response: null, loading: false });
    expect(validCommandsResponse({ ...FIXTURE, commands: [COMMANDS[0], { description: "no name" }, null] })?.commands).toEqual([COMMANDS[0]]);
    expect(validCommandsResponse(null)).toBeNull();
  });

  it("reports every change", async () => {
    const test = harness();
    test.cache.refresh(SESSION);
    expect(test.changes).toBe(1);
    test.calls[0].request.resolve(FIXTURE);
    await settle();
    expect(test.changes).toBe(2);
  });
});
