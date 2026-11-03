import { describe, expect, it } from "vitest";
import { isEditableTarget, settingsBackKey, type BackKey } from "../src/gateway/ui/settings/macSettingsLogic";

// A Mac settings section opened as its own page goes back with Alt+Left, Escape and Backspace,
// the way Windows apps do (no swipe); boxes keep the keys they type with.

const key = (name: string, extra: Partial<BackKey> = {}): BackKey => ({
  key: name, altKey: false, ctrlKey: false, metaKey: false, shiftKey: false, defaultPrevented: false, editable: false, ...extra,
});

describe("settingsBackKey", () => {
  it("goes back with Alt+Left anywhere, even in a box", () => {
    expect(settingsBackKey(key("ArrowLeft", { altKey: true }))).toBe("back");
    expect(settingsBackKey(key("ArrowLeft", { altKey: true, editable: true }))).toBe("back");
    expect(settingsBackKey(key("ArrowLeft"))).toBeNull();
    expect(settingsBackKey(key("ArrowLeft", { altKey: true, shiftKey: true }))).toBeNull();
    expect(settingsBackKey(key("ArrowLeft", { altKey: true, ctrlKey: true }))).toBeNull();
  });

  it("goes back with Escape, or first ends the edit in a box", () => {
    expect(settingsBackKey(key("Escape"))).toBe("back");
    expect(settingsBackKey(key("Escape", { editable: true }))).toBe("endEdit");
    // A box that changed puts back its saved value instead.
    expect(settingsBackKey(key("Escape", { editable: true, defaultPrevented: true }))).toBeNull();
    expect(settingsBackKey(key("Escape", { ctrlKey: true }))).toBeNull();
  });

  it("goes back with Backspace only outside boxes", () => {
    expect(settingsBackKey(key("Backspace"))).toBe("back");
    expect(settingsBackKey(key("Backspace", { editable: true }))).toBeNull();
    expect(settingsBackKey(key("Backspace", { altKey: true }))).toBeNull();
    expect(settingsBackKey(key("Backspace", { ctrlKey: true }))).toBeNull();
  });

  it("leaves other keys alone", () => {
    for (const name of ["Enter", " ", "Tab", "ArrowRight", "a"]) expect(settingsBackKey(key(name))).toBeNull();
    expect(settingsBackKey(key("Escape", { metaKey: true }))).toBeNull();
  });
});

describe("isEditableTarget", () => {
  it("counts boxes you type in", () => {
    for (const type of ["", "text", "search", "url", "email", "password", "number", "tel"]) {
      expect(isEditableTarget({ tagName: "INPUT", type })).toBe(true);
    }
    expect(isEditableTarget({ tagName: "TEXTAREA" })).toBe(true);
    expect(isEditableTarget({ tagName: "DIV", isContentEditable: true })).toBe(true);
  });

  it("not buttons, switches, menus or read-only boxes", () => {
    for (const type of ["checkbox", "radio", "range", "button"]) expect(isEditableTarget({ tagName: "INPUT", type })).toBe(false);
    expect(isEditableTarget({ tagName: "SELECT" })).toBe(false);
    expect(isEditableTarget({ tagName: "BUTTON" })).toBe(false);
    expect(isEditableTarget({ tagName: "INPUT", type: "text", readOnly: true })).toBe(false);
    expect(isEditableTarget(null)).toBe(false);
  });
});
