import { describe, expect, it } from "vitest";
import {
  INVALID_RESPONSE, SKILLS_UNSUPPORTED, isUnsupported, normalizeSkills, skillSeenBy, skillToggleLabel, skillsDriftClear,
  skillsDriftStatus, skillsDriftSummary, skillsPollDelay, skillsRelative, skillsRelinkSummary, skillsRuleText, skillsWithEnabled,
} from "../src/gateway/ui/sheets/sheetLogic";

// Cases mirror Hermes/Tests/CantripSkillsTests.swift (invented skill names only).
const payload = {
  library: "~/Library/Application Support/Cantrip/skills",
  backends: ["Claude Code", "Copilot", "Codex", "Antigravity"],
  skills: [
    { name: "weather-lookup", description: "Looks up the weather.", enabled: true,
      backends: ["Claude Code", "Copilot", "Codex", "Antigravity"], problems: [] },
    { name: "notes-sync", description: "", enabled: false, backends: [],
      problems: ["Name clash: ~/.agents/skills/notes-sync is a folder Cantrip doesn't manage (left as is; rename one of them)"] },
  ],
  rules: [{ folder: "~/Coding", lines: 12, mirror: "~/Coding/CLAUDE.md" }],
  drift: [{ path: "~/Coding/app/CLAUDE.md", problem: "holds the rules but there's no AGENTS.md beside it" }],
  driftCheckedAt: "2026-11-01T13:40:00Z",
  checking: false,
};
const checked = Date.parse("2026-11-01T13:40:00Z");

describe("Skills & Rules payload", () => {
  it("reads the host payload", () => {
    const value = normalizeSkills(payload);
    expect(value.skills.map((skill) => skill.name)).toEqual(["weather-lookup", "notes-sync"]);
    expect(value.skills[1].problems).toHaveLength(1);
    expect(value.rules[0].mirror).toBe("~/Coding/CLAUDE.md");
    expect(value.driftCheckedAt).toBe("2026-11-01T13:40:00Z");
    expect(value.checking).toBe(false);
    expect(value.messages).toBeUndefined();
  });

  it("fills in missing optional fields", () => {
    const value = normalizeSkills({
      skills: [{ name: "weather-lookup", enabled: true }], rules: [{ folder: "~/Coding", lines: 1 }],
      driftCheckedAt: null, messages: ["Linked ~/.agents/skills/weather-lookup"],
    });
    expect(value.library).toBe("");
    expect(value.skills[0]).toEqual({ name: "weather-lookup", description: "", enabled: true, backends: [], problems: [] });
    expect(value.rules[0].mirror).toBeUndefined();
    expect(value.drift).toEqual([]);
    expect(value.driftCheckedAt).toBeNull();
    expect(value.checking).toBe(false);
    expect(value.messages).toEqual(["Linked ~/.agents/skills/weather-lookup"]);
    expect(() => normalizeSkills({ rules: [] })).toThrow(INVALID_RESPONSE);
    expect(() => normalizeSkills(null)).toThrow(INVALID_RESPONSE);
  });

  it("says an older Mac needs an update, once", () => {
    expect(isUnsupported(Object.assign(new Error("not found"), { status: 404 }))).toBe(true);
    expect(isUnsupported(Object.assign(new Error("No skill named weather-lookup."), { status: 400 }))).toBe(false);
    expect(SKILLS_UNSUPPORTED).toBe("This Mac's Cantrip doesn't share skills yet. Update Cantrip on the Mac.");
  });
});

describe("Skills & Rules text", () => {
  const value = normalizeSkills(payload);

  it("names who sees each skill and labels its switch", () => {
    expect(skillSeenBy(value.skills[0])).toBe("Seen by: Claude Code, Copilot, Codex, Antigravity");
    expect(skillSeenBy(value.skills[1])).toBe("No backend sees it");
    expect(skillToggleLabel(value.skills[0])).toBe("weather-lookup, on for every backend");
    expect(skillToggleLabel(value.skills[1])).toBe("notes-sync, off for every backend");
  });

  it("describes folder rules", () => {
    expect(skillsRuleText(value.rules[0])).toBe("~/Coding — 12 lines (mirrored to ~/Coding/CLAUDE.md)");
    expect(skillsRuleText({ folder: "~/Notes", lines: 1 })).toBe("~/Notes — 1 line");
    expect(skillsRuleText({ folder: "~/Notes", lines: 3, mirror: null })).toBe("~/Notes — 3 lines");
  });

  it("reports relinks and drift", () => {
    expect(skillsRelinkSummary([])).toBe("Relinked. Everything was already linked.");
    expect(skillsRelinkSummary(["Linked ~/.agents/skills/notes-sync"])).toBe("Relinked: Linked ~/.agents/skills/notes-sync");
    expect(skillsDriftSummary(value)).toBe("1 drift finding");
    expect(skillsDriftClear(value)).toBe(false);
    const clear = { ...value, drift: [] };
    expect(skillsDriftClear(clear)).toBe(true);
    expect(skillsDriftSummary(clear)).toBe("No drift found");
    expect(skillsDriftClear({ ...clear, checking: true })).toBe(false);
    expect(skillsDriftClear({ ...clear, driftCheckedAt: null })).toBe(false);
  });

  it("shows when drift was last checked", () => {
    expect(skillsDriftStatus(value, checked + 20_000, "en-US")).toBe("Last checked just now");
    expect(skillsDriftStatus(value, checked + 5 * 60_000, "en-US")).toBe("Last checked 5 minutes ago");
    expect(skillsDriftStatus(value, checked + 2 * 3_600_000, "en-US")).toBe("Last checked 2 hours ago");
    expect(skillsRelative(new Date(checked), checked + 86_400_000, "en-US")).toBe("yesterday");
    expect(skillsDriftStatus({ ...value, checking: true })).toBe("Checking…");
    expect(skillsDriftStatus({ ...value, driftCheckedAt: null })).toBe("Not checked yet");
    expect(skillsDriftStatus({ ...value, driftCheckedAt: undefined })).toBe("Not checked yet");
  });

  it("polls fast only while checking", () => {
    expect(skillsPollDelay({ checking: true })).toBe(2000);
    expect(skillsPollDelay({ checking: false })).toBe(10000);
    expect(skillsPollDelay(null)).toBe(10000);
  });

  it("shows a switched skill at once", () => {
    const next = skillsWithEnabled(value, "notes-sync", true);
    expect(next.skills.map((skill) => skill.enabled)).toEqual([true, true]);
    expect(value.skills[1].enabled).toBe(false);
  });
});
