import { readFileSync } from "node:fs";
import vm from "node:vm";
import { describe, expect, it, vi } from "vitest";
import { MOODS } from "../src/gateway/ui/pip/mascot";
import { personalMascotPose } from "../src/gateway/ui/pip/privateMascot";
import { deferred, revisionA, revisionB, settle, syntheticPack } from "./private-mascot-fixture";

const swift = readFileSync(new URL("../../../../Sources/Cantrip/RemoteControlServer.swift", import.meta.url), "utf8");
const template = swift.slice(swift.indexOf('static let webAppTemplate = """'));
const start = template.indexOf("    // Private artwork: one decoded pack");
const end = template.indexOf("    async function startRemoteUI()", start);
const script = template.slice(start, end).replace(/\\(u\{[0-9a-fA-F]+\}|\n|.)/g, (_, escape: string) => {
  if (escape.startsWith("u{")) return String.fromCodePoint(parseInt(escape.slice(2, -1), 16));
  const replacement = ({ "\\": "\\", '"': '"', "'": "'", n: "\n", t: "\t", r: "\r", 0: "\0", "\n": "" } as Record<string, string>)[escape];
  if (replacement === undefined) throw Error(`Unsupported Swift escape: ${escape}`);
  return replacement;
});

function browser() {
  const saved = new Map(), events = new Map<string, () => void>(), frames = new Map<number, unknown>();
  const context2d = new Proxy({}, { get: () => vi.fn() });
  const elements = new Map<string, any>();
  const element = (id: string) => {
    if (!elements.has(id)) {
      const classes = new Set();
      elements.set(id, {
        width: 80, height: 80, textContent: "", checked: true,
        classList: { contains: (name: string) => classes.has(name), toggle: (name: string, on: boolean) => on ? classes.add(name) : classes.delete(name) },
        getContext: () => context2d,
      });
    }
    return elements.get(id);
  };
  const close = vi.fn(), api = vi.fn().mockResolvedValue(syntheticPack());
  const reduced = { matches: false, addEventListener: vi.fn() };
  const doc = { hidden: false, documentElement: { dataset: { cantripConnected: "true" } }, addEventListener: (name: string, callback: () => void) => events.set(name, callback) };
  let frame = 0, intersection!: (entries: { isIntersecting: boolean }[]) => void;
  const context = vm.createContext({
    $, document: doc, token: "fixture-credential", selected: "home", api, Blob, atob, AbortController,
    localStorage: { getItem: (key: string) => saved.get(key) ?? null, setItem: (key: string, value: string) => saved.set(key, value) },
    window: { addEventListener: (name: string, callback: () => void) => events.set(name, callback) },
    matchMedia: (query: string) => query.includes("reduced") ? reduced : { matches: true, addEventListener() {} },
    devicePixelRatio: 1, performance: { now: () => 1000 },
    createImageBitmap: vi.fn().mockResolvedValue({ width: 1, height: 1, close }),
    requestAnimationFrame: (callback: unknown) => { frames.set(++frame, callback); return frame; },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    IntersectionObserver: class { constructor(callback: typeof intersection) { intersection = callback; } observe() {} },
  });
  function $(id: string) { return element(id); }
  vm.runInContext(script, context);
  const run = (code: string) => vm.runInContext(code, context);
  const observe = (revision: string | null, error?: string) => context.observePersonalMascot({ privateMascotRevision: revision, privateMascotError: error, home: { id: "home", isCantripHome: true } });
  return { context, run, observe, api, close, frames, events, doc, reduced, element, saved, intersect: (on: boolean) => intersection([{ isIntersecting: on }]) };
}

describe("embedded browser personal mascot", () => {
  it("uses the authenticated no-store transport once per revision; drops stale pairing and disabled responses", async () => {
    const b = browser(), pending = deferred<unknown>();
    b.api.mockReturnValueOnce(pending.promise);
    b.observe(revisionA); b.observe(revisionA);
    expect(b.api).toHaveBeenCalledTimes(1);
    expect(b.api.mock.calls[0][0]).toBe(`/api/v1/mascot?revision=${revisionA}`);
    expect(b.api.mock.calls[0][1].cache).toBe("no-store");
    b.context.resetPersonalMascot();
    expect(b.api.mock.calls[0][1].signal.aborted).toBe(true);
    b.observe(revisionB); b.context.setPersonalEnabled(false);
    pending.resolve(syntheticPack()); await settle();
    expect(b.run("personalState.pack")).toBeNull();
    b.context.setPersonalEnabled(true);
    b.api.mockResolvedValue(syntheticPack(revisionB));
    await settle();
    // The previous response mismatched the new revision and is surfaced, never displayed.
    expect(b.run("personalState.pack")).toBeNull();
    expect(b.run("personalState.error")).toContain("revision");
    b.context.resetPersonalMascot(); b.observe(revisionB); await settle();
    expect(b.run("Boolean(personalState.pack)")).toBe(true);
    b.observe(null, "Configured pack is unreadable");
    expect(b.run("personalState.pack")).toBeNull();
    expect(b.close).toHaveBeenCalledTimes(2);
    expect(b.element("personalMascotError").textContent).toContain("unreadable");
    b.observe(null); expect(b.element("personalMascotError").textContent).toBe("");
    expect(b.saved.size).toBe(0);
  });

  it("stops frames offscreen, hidden and with reduced motion; uses the same deterministic pose", async () => {
    const b = browser();
    b.observe(revisionA); await settle(); expect(b.frames.size).toBe(1);
    b.intersect(false); expect(b.frames.size).toBe(0);
    b.intersect(true); expect(b.frames.size).toBe(1);
    b.doc.hidden = true; b.events.get("visibilitychange")!(); expect(b.frames.size).toBe(0);
    b.doc.hidden = false; b.reduced.matches = true; b.context.updatePersonalAnimation(); expect(b.frames.size).toBe(0);
    for (const mood of MOODS) {
      expect(b.context.personalPose(mood, 4.72, true, 0.6)).toEqual(personalMascotPose(mood, 1, true, null));
    }
    b.run('selected="tab"'); b.context.renderPersonalMascot();
    expect(b.element("personalMascotHeader").classList.contains("hidden")).toBe(true);
    b.events.get("pagehide")!(); expect(b.run("personalState.pack")).toBeNull();
  });

  it("caps retries and waits for a new revision after a stale-pack response", async () => {
    const b = browser();
    b.api.mockRejectedValue(Error("Unavailable"));
    for (let attempt = 0; attempt < 5; attempt++) {
      b.run("personalState.retryAt=0"); b.observe(revisionA); await settle();
    }
    expect(b.api).toHaveBeenCalledTimes(3);
    b.api.mockRejectedValue(Object.assign(Error("Stale"), { status: 409 }));
    b.observe(revisionB); await settle();
    b.run("personalState.retryAt=0"); b.observe(revisionB); await settle();
    expect(b.api).toHaveBeenCalledTimes(4);
  });
});
