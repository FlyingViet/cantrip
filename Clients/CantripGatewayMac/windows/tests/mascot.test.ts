import { describe, expect, it } from "vitest";
import {
  DEFAULT_OUTFIT, MASCOT_NAME_KEY, MASCOT_NAME_MAX_LENGTH, MASCOT_OUTFIT_KEY, MOODS, OUTFITS, currentActivity, displayName,
  isBusy, isLookup, isOutfitID, moodAccessibilityStatus, moodTitle, openness, outfitFor, resolveMood,
  type MascotActivity, type TranscriptMessage,
} from "../src/gateway/ui/pip/mascot";

// Mirrors Hermes/Tests/CantripMascotTests.swift.
describe("Pip mood", () => {
  const mood = ({ connected = true, working = false, listening = false, speaking = false, input = false } = {}) =>
    resolveMood({ isConnected: connected, isWorking: working, isListening: listening, isSpeaking: speaking, needsInput: input });

  it("prioritizes disconnected, then what needs the user", () => {
    expect(mood()).toBe("idle");
    expect(mood({ working: true })).toBe("thinking");
    expect(mood({ working: true, speaking: true })).toBe("speaking");
    expect(mood({ working: true, listening: true, speaking: true })).toBe("listening");
    expect(mood({ working: true, listening: true, input: true })).toBe("curious");
    expect(mood({ connected: false, working: true, input: true })).toBe("sleeping");
  });

  it("shows what a live run is doing, not a stale problem", () => {
    for (const activity of ["thinking", "searching", "working", "writing"] as MascotActivity[]) {
      const busy = resolveMood({
        isConnected: true, isWorking: true, activity, isListening: false, isSpeaking: false, needsInput: false, hasProblem: true,
      });
      expect(busy).toBe(activity);
      expect(isBusy(busy)).toBe(true);
    }
    expect(resolveMood({
      isConnected: true, isWorking: false, activity: "writing", isListening: false, isSpeaking: false, needsInput: false, hasProblem: true,
    })).toBe("concerned");
    expect(isBusy("concerned")).toBe(false);
  });

  it("announces only the states the composer does not", () => {
    expect(moodAccessibilityStatus("thinking")).toBeNull();
    expect(moodAccessibilityStatus("writing")).toBeNull();
    expect(moodAccessibilityStatus("curious")).toBe("Waiting for your answer");
    expect(moodAccessibilityStatus("concerned")).toBe("Something went wrong");
    expect(moodAccessibilityStatus("idle")).toBeNull();
    expect(moodAccessibilityStatus("listening")).toBe("Listening");
    expect(moodAccessibilityStatus("speaking")).toBe("Speaking");
  });

  it("gives every mood a distinct title", () => {
    expect(MOODS).toHaveLength(10);
    expect(new Set(MOODS.map(moodTitle)).size).toBe(MOODS.length);
    expect(moodTitle("idle")).toBe("Resting");
    expect(moodTitle("sleeping")).toBe("Asleep");
  });
});

describe("Pip activity", () => {
  const reply = ({ text = "", tools = [] as [string, string][], role = "assistant" } = {}): TranscriptMessage[] => [
    { role: "user", text: "Go", activities: [] },
    { role, text, activities: tools.map(([name, state]) => ({ title: name, toolName: name, state })) },
  ];

  it("follows the live run", () => {
    expect(currentActivity("Preparing context...", reply())).toBe("thinking");
    expect(currentActivity(null, reply())).toBe("thinking");
    expect(currentActivity(undefined, reply())).toBe("thinking");
    expect(currentActivity("Search", reply({ tools: [["grep", "running"]] }))).toBe("searching");
    expect(currentActivity("Fetch", reply({ tools: [["web_fetch", "running"]] }))).toBe("searching");
    expect(currentActivity("Read", reply({ tools: [["github-mcp-server-get_file_contents", "running"]] }))).toBe("searching");
    expect(currentActivity("Build", reply({ tools: [["grep", "succeeded"], ["bash", "running"]] }))).toBe("working");
    expect(currentActivity("Edit", reply({ text: "Fixing it.", tools: [["edit", "running"]] }))).toBe("working");
    expect(currentActivity(null, reply({ text: "Here's what changed", tools: [["bash", "succeeded"]] }))).toBe("writing");
    expect(currentActivity("Thinking…", reply({ text: "First pass done." }))).toBe("thinking");
    expect(currentActivity(null, reply({ text: "Hi", role: "user" }))).toBe("thinking");
  });

  it("treats whitespace status as quiet and skips handoff result cards", () => {
    expect(currentActivity("  \n", reply({ text: "Streaming" }))).toBe("writing");
    const transcript = [...reply({ text: "Streaming" }), { role: "handoff", text: "Done in tab", activities: [] }];
    expect(currentActivity(null, transcript)).toBe("writing");
    expect(currentActivity(null, [])).toBe("thinking");
  });

  it("counts live subagents as working", () => {
    const withAgents = (status: string): TranscriptMessage[] => [{ role: "assistant", text: "", activities: [], subagents: [{ status }] }];
    expect(currentActivity("Waiting", withAgents("running"))).toBe("working");
    expect(currentActivity("Waiting", withAgents("queued"))).toBe("working");
    expect(currentActivity("Waiting", withAgents("completed"))).toBe("thinking");
  });

  it("knows lookup tools", () => {
    expect(isLookup("WebSearch")).toBe(true);
    expect(isLookup("view")).toBe(true);
    expect(isLookup("create")).toBe(false);
    expect(isLookup("read_bash")).toBe(false);
  });
});

describe("Pip blink", () => {
  it("is brief, and the still pose has open eyes", () => {
    expect(openness(1)).toBe(1);
    expect(openness(4.3 - 1.1 + 0.08)).toBeLessThan(0.1);
    let closed = 0;
    let total = 0;
    for (let index = 0; index < 4300; index++) {
      total++;
      if (openness(index * 0.01) < 1) closed++;
    }
    expect(closed / total).toBeLessThan(0.06);
  });
});

describe("Pip outfits and name", () => {
  it("keeps stable stored values and defaults to Starry Plush", () => {
    expect(OUTFITS.map((outfit) => outfit.id)).toEqual(["starryPlush", "dinoHoodie", "pandaKitty"]);
    expect(MASCOT_OUTFIT_KEY).toBe("cantrip.mascot.outfit");
    expect(MASCOT_NAME_KEY).toBe("cantrip.mascot.name");
    expect(isOutfitID("unknownOutfit")).toBe(false);
    expect(outfitFor("unknownOutfit").id).toBe(DEFAULT_OUTFIT);
    expect(DEFAULT_OUTFIT).toBe("starryPlush");
    expect(outfitFor("dinoHoodie").title).toBe("Dino Hoodie");
    expect(outfitFor("pandaKitty").title).toBe("Panda Kitty");
    expect(OUTFITS.filter((outfit) => outfit.isCat).map((outfit) => outfit.id)).toEqual(["pandaKitty"]);
  });

  it("defaults to Pip and sanitizes the name", () => {
    expect(displayName("")).toBe("Pip");
    expect(displayName(null)).toBe("Pip");
    expect(displayName("   \n ")).toBe("Pip");
    expect(displayName("  Mochi \n")).toBe("Mochi");
    expect(displayName("Sir\nPip")).toBe("Sir Pip");
    expect(displayName("a".repeat(40))).toHaveLength(MASCOT_NAME_MAX_LENGTH);
    expect(displayName("👩‍👩‍👧".repeat(25))).toBe("👩‍👩‍👧".repeat(20));
  });
});
