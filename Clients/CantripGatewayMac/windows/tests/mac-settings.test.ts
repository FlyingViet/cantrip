import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { SettingsField, SettingsManifest } from "../src/gateway/api/types";
import {
  actionRequest, changeRequest, choiceToken, coerceValue, fieldDOMID, fieldsByKey, isFieldVisible, isUnchanged, keepRequest,
  needsReload, normalizeManifest, numberText, pendingSecondsLeft, pendingText, portText, revertRequest, sameValue, secretStatus,
  settingsFailure, settingsTabs, settingsValues, toneClass, unplacedFieldErrors, valueText, visibleFields, visibleSections,
} from "../src/gateway/ui/settings/macSettingsLogic";

// Cases mirror SettingsManifest.swift (what the Mac sends a paired device, and how it checks a change).

const raw = JSON.parse(readFileSync(new URL("./fixtures/settings/manifest.json", import.meta.url), "utf8")) as unknown;
const manifest = normalizeManifest(raw)!;
const fields = fieldsByKey(manifest);
const field = (key: string): SettingsField => {
  const found = fields.get(key);
  if (!found) throw new Error(`No field ${key}`);
  return found;
};
const refused = (status: number, message: string, body?: unknown) => Object.assign(new Error(message), { status, body });

describe("reading the manifest", () => {
  it("keeps every page and drops what this client can't draw", () => {
    expect(manifest.pages.map((page) => page.id)).toEqual(["macs", "models", "tools", "home", "memory", "about"]);
    expect(fields.has("futureWidget")).toBe(false);
    expect(manifest.pending?.summary).toBe("Direct port 8766");
    expect(manifest.mac).toBe("Studio Mac");
  });

  it("refuses something that isn't a manifest", () => {
    expect(normalizeManifest(null)).toBeNull();
    expect(normalizeManifest({ pages: [] })).toBeNull();
    expect(normalizeManifest({ revision: "r", pages: "nope" })).toBeNull();
    expect(normalizeManifest({ revision: "r", pages: [{ id: "x", title: "X", sections: [{ id: "s", title: "S", fields: [{ key: "a", type: "toggle" }] }] }] })?.pages)
      .toEqual([]);
  });
});

describe("visibleWhen", () => {
  const values = settingsValues(manifest);

  it("follows a field on another page", () => {
    expect(isFieldVisible(field("watchInternetRouteEnabled"), values)).toBe(true);
    const homeOff = settingsValues(manifest, { cantripHomeEnabled: false });
    expect(isFieldVisible(field("watchInternetRouteEnabled"), homeOff)).toBe(false);
    expect(isFieldVisible(field("cantripHomeParallelRuns"), homeOff)).toBe(false);
  });

  it("shows fields without a rule and hides those whose field is missing", () => {
    expect(isFieldVisible(field("backend"), values)).toBe(true);
    expect(isFieldVisible({ ...field("backend"), visibleWhen: { key: "nowhere", values: [true] } }, values)).toBe(false);
  });

  it("compares JSON types: true isn't 1", () => {
    const rule = { ...field("backend"), visibleWhen: { key: "cantripHomeEnabled", values: [1] } };
    expect(isFieldVisible(rule, values)).toBe(false);
    expect(sameValue(15, 15.0)).toBe(true);
    expect(sameValue("15", 15)).toBe(false);
    expect(sameValue(undefined, undefined)).toBe(false);
  });

  it("drops a section whose fields are all hidden", () => {
    const memory = manifest.pages.find((page) => page.id === "memory")!;
    expect(visibleFields(memory.sections[0], values).map((item) => item.key)).toEqual(["memoryEnabled"]);
    const macs = manifest.pages.find((page) => page.id === "macs")!;
    expect(visibleSections(macs, settingsValues(manifest, { cantripHomeEnabled: false })).map((section) => section.id)).toEqual(["remote"]);
  });

  it("puts changes on their way on top of the Mac's values", () => {
    expect(settingsValues(manifest, { memoryEnabled: true }).get("memoryEnabled")).toBe(true);
    expect(values.has("localAPIKey")).toBe(false);
  });
});

describe("pages", () => {
  const own = [{ id: "macs", title: "Connection" }, { id: "tools", title: "Tools & sign-ins" }, { id: "voice", title: "Voice" }, { id: "location", title: "Location" }];

  it("puts the Mac's pages among the window's own in iPhone's order, Home & tabs after Tools", () => {
    const tabs = settingsTabs(own, [...manifest.pages, { id: "later", title: "Later", sections: [] }]);
    expect(tabs.map((tab) => tab.id)).toEqual(["macs", "models", "tools", "home", "memory", "voice", "location", "about", "later"]);
    expect(tabs.find((tab) => tab.id === "macs")).toMatchObject({ title: "Connection", own: true });
    expect(tabs.find((tab) => tab.id === "macs")?.page?.sections[0].id).toBe("remote");
    expect(tabs.find((tab) => tab.id === "home")).toMatchObject({ title: "Home & tabs", own: false });
    expect(tabs.find((tab) => tab.id === "voice")?.page).toBeUndefined();
  });

  it("keeps only the window's pages without a manifest", () => {
    expect(settingsTabs(own, []).map((tab) => tab.id)).toEqual(["macs", "tools", "voice", "location"]);
  });
});

describe("what a control sends", () => {
  it("keeps a choice's JSON type and honours disabled choices", () => {
    expect(coerceValue(field("copilotIdleReleaseMinutes"), choiceToken(15))).toEqual({ value: 15 });
    expect(coerceValue(field("copilotIdleReleaseMinutes"), "15")).toEqual({ value: 15 });
    expect(coerceValue(field("copilotIdleReleaseMinutes"), '"15"')).toEqual({ error: "Choose one of Free an idle Copilot tab's memory after's options." });
    expect(coerceValue(field("claudeEffort"), choiceToken(""))).toEqual({ value: "" });
    expect(coerceValue(field("claudeEffort"), choiceToken("high"))).toEqual({ value: "high" });
    expect(coerceValue(field("claudeEffort"), choiceToken("max"))).toHaveProperty("error");
    expect(choiceToken(0)).toBe("0");
    expect(choiceToken("Copilot")).toBe('"Copilot"');
  });

  it("checks integers against their range", () => {
    expect(coerceValue(field("cantripHomeParallelRuns"), " 4 ")).toEqual({ value: 4 });
    expect(coerceValue(field("cantripHomeParallelRuns"), 3)).toEqual({ value: 3 });
    expect(coerceValue(field("cantripHomeParallelRuns"), "2.5")).toEqual({ error: "Background jobs at once is a whole number." });
    expect(coerceValue(field("cantripHomeParallelRuns"), "9")).toEqual({ error: "Background jobs at once is 1–8." });
    expect(coerceValue(field("cantripHomeParallelRuns"), "")).toEqual({ error: "Background jobs at once is a whole number." });
  });

  it("reads an empty port box as 0 when 0 has a name", () => {
    expect(coerceValue(field("remoteLANPort"), "")).toEqual({ value: 0 });
    expect(coerceValue(field("remoteLANPort"), " 8766 ")).toEqual({ value: 8766 });
    expect(coerceValue(field("remoteLANPort"), "70000")).toEqual({ error: "Direct port is 1–65535, or empty for automatic." });
    expect(coerceValue(field("remoteControlPort"), "")).toEqual({ error: "HTTP port is a whole number." });
    expect(coerceValue(field("remoteControlPort"), "80")).toEqual({ error: "HTTP port is 1024–65535." });
    expect(coerceValue(field("remoteControlPort"), "0")).toEqual({ error: "HTTP port is 1024–65535." });
    expect(coerceValue(field("remoteControlPort"), "abc")).toEqual({ error: "HTTP port is a whole number." });
  });

  it("sends a secret as typed, or \"\" to clear it", () => {
    expect(coerceValue(field("localAPIKey"), "sk-1")).toEqual({ value: "sk-1" });
    expect(coerceValue(field("localAPIKey"), "")).toEqual({ value: "" });
    expect(coerceValue(field("localAPIKey"), "a\nb")).toEqual({ error: "API key is one line." });
    expect(coerceValue(field("localAPIKey"), "123456789")).toEqual({ error: "API key is too long." });
    expect(isUnchanged(field("localAPIKey"), "")).toBe(false);
    expect(isUnchanged({ ...field("localAPIKey"), isSet: false }, "")).toBe(true);
    expect(secretStatus(field("localAPIKey"))).toBe("Set");
    expect(secretStatus({ isSet: false })).toBe("Not set");
  });

  it("allows new lines only in multiline text, and trims paths", () => {
    expect(coerceValue(field("localSystemPrompt"), "Be brief.\nAlways.")).toEqual({ value: "Be brief.\nAlways." });
    expect(coerceValue(field("simulatorPoolPhone"), "iPhone\n17")).toEqual({ error: "iPhone model is one line." });
    expect(coerceValue({ ...field("claudePath"), readOnly: false }, "  /opt/bin/claude ")).toEqual({ value: "/opt/bin/claude" });
    expect(coerceValue({ ...field("simulatorPoolPhone"), maxLength: 3 }, "👩‍👩‍👧ab")).toEqual({ value: "👩‍👩‍👧ab" });
    expect(coerceValue({ ...field("simulatorPoolPhone"), maxLength: 3 }, "abcd")).toEqual({ error: "iPhone model is too long." });
  });

  it("checks toggles, sliders and read-only fields", () => {
    expect(coerceValue(field("allowActions"), true)).toEqual({ value: true });
    expect(coerceValue(field("allowActions"), "true")).toEqual({ error: "Act on my behalf is on or off." });
    expect(coerceValue(field("panelOpacity"), 0.9)).toEqual({ value: 0.9 });
    expect(coerceValue(field("panelOpacity"), 0.2)).toEqual({ error: "Panel opacity is out of range." });
    expect(coerceValue(field("remoteControlEnabled"), false)).toEqual({ error: "Change this in Cantrip's Settings on the Mac." });
    expect(coerceValue(field("remoteLANStatus"), "x")).toEqual({ error: "Local network can't be set." });
  });

  it("knows when nothing would change", () => {
    expect(isUnchanged(field("cantripHomeParallelRuns"), 2)).toBe(true);
    expect(isUnchanged(field("cantripHomeParallelRuns"), 3)).toBe(false);
    expect(isUnchanged(field("copilotIdleReleaseMinutes"), 30)).toBe(true);
  });
});

describe("request bodies", () => {
  it("sends changes with the revision loaded, keeping JSON types", () => {
    expect(JSON.stringify(changeRequest(manifest.revision, { copilotIdleReleaseMinutes: 15, allowActions: true, claudeEffort: "" })))
      .toBe('{"revision":"0a1b2c3d4e5f","changes":{"copilotIdleReleaseMinutes":15,"allowActions":true,"claudeEffort":""}}');
    const changes = { remoteLANPort: 0 };
    const body = changeRequest("r", changes);
    changes.remoteLANPort = 8766;
    expect(body.changes).toEqual({ remoteLANPort: 0 });
  });

  it("runs buttons and answers a pending change by its id", () => {
    expect(actionRequest("rotatePairingToken")).toEqual({ action: "rotatePairingToken" });
    expect(keepRequest(manifest.pending!)).toEqual({ keep: "6F1C2B0E-2E55-4C59-9A7B-8E0D5C1F0A11" });
    expect(revertRequest(manifest.pending!)).toEqual({ revert: "6F1C2B0E-2E55-4C59-9A7B-8E0D5C1F0A11" });
  });
});

describe("refusals", () => {
  it("reads 409 as stale and draws the Mac's current settings", () => {
    const current = { ...(raw as SettingsManifest), revision: "ffffffffffff", pending: undefined };
    const failure = settingsFailure(refused(409, "Settings changed on another device. They've been reloaded; try again.", {
      error: "Settings changed on another device. They've been reloaded; try again.", settings: current,
    }));
    expect(failure.kind).toBe("stale");
    if (failure.kind !== "stale") return;
    expect(failure.message).toBe("Settings changed on another device. They've been reloaded; try again.");
    expect(failure.manifest?.revision).toBe("ffffffffffff");
    expect(failure.manifest?.pending).toBeUndefined();
    expect(settingsFailure(refused(409, "Keep or undo the last connection change first.", { error: "x" })))
      .toEqual({ kind: "stale", message: "Keep or undo the last connection change first.", manifest: null });
  });

  it("reads 422 as reasons for each refused key", () => {
    const failure = settingsFailure(refused(422, "Some settings weren't saved.", {
      error: "Some settings weren't saved.", fields: { remoteLANPort: "The direct port can't be the HTTP port.", other: 3 },
    }));
    expect(failure).toEqual({ kind: "invalid", message: "Some settings weren't saved.", fields: { remoteLANPort: "The direct port can't be the HTTP port." } });
    expect(settingsFailure(refused(422, "There's no action nope."))).toEqual({ kind: "invalid", message: "There's no action nope.", fields: {} });
    expect(unplacedFieldErrors({ remoteLANPort: "a", gone: "b" }, new Set(["remoteLANPort"]))).toEqual(["b"]);
  });

  it("hides the manifest on an older Mac, and reports anything else", () => {
    expect(settingsFailure(refused(404, "Not found"))).toEqual({ kind: "unsupported" });
    expect(settingsFailure(refused(502, "Can't reach your Mac."))).toEqual({ kind: "failed", message: "Can't reach your Mac." });
    expect(settingsFailure("offline")).toEqual({ kind: "failed", message: "offline" });
  });
});

describe("refreshing and pending changes", () => {
  it("reloads only when the polled revision moved", () => {
    expect(needsReload("a", { supportsSettings: true, settingsRevision: "b" })).toBe(true);
    expect(needsReload("a", { supportsSettings: true, settingsRevision: "a" })).toBe(false);
    expect(needsReload("a", { supportsSettings: false, settingsRevision: "" })).toBe(false);
    expect(needsReload("a", null)).toBe(false);
    expect(needsReload(null, { supportsSettings: true, settingsRevision: "b" })).toBe(false);
  });

  it("counts down from when the pending change arrived", () => {
    const pending = manifest.pending!;
    expect(pendingSecondsLeft(pending, 1000, 1000)).toBe(52);
    expect(pendingSecondsLeft(pending, 1000, 3500)).toBe(50);
    expect(pendingSecondsLeft(pending, 1000, 1000 + 60_000)).toBe(0);
    expect(pendingText(pending, 50)).toBe("Keep Direct port 8766? Undoes in 50 s");
  });
});

describe("display", () => {
  it("formats sliders, ports, info lines and ids", () => {
    expect(numberText(field("panelOpacity"), 0.85)).toBe("85%");
    expect(numberText(field("storageSessionRetentionDays"), 14)).toBe("14 days");
    expect(portText(field("remoteLANPort"), 0)).toBe("");
    expect(portText(field("remoteControlPort"), 8765)).toBe("8765");
    expect(valueText(true)).toBe("On");
    expect(valueText(undefined)).toBe("");
    expect(toneClass("warning")).toBe("orange");
    expect(toneClass("error")).toBe("red");
    expect(toneClass(undefined)).toBe("muted");
    expect(fieldDOMID("a.b c", "help")).toBe("mac-setting-a-b-c-help");
  });
});
