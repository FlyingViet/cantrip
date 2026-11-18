import { afterEach, describe, expect, it, vi } from "vitest";
import { decodePrivateMascot, personalMascotPose, PrivateMascotLoader, type PrivateMascotPack } from "../src/gateway/ui/pip/privateMascot";
import { MOODS } from "../src/gateway/ui/pip/mascot";
import { deferred, revisionA, revisionB, settle, syntheticPack, syntheticPNG } from "./private-mascot-fixture";

afterEach(() => vi.unstubAllGlobals());

function pack(revision = revisionA): PrivateMascotPack {
  return { revision, sparkX: 0.2, sparkY: 0.7, portrait: {} as CanvasImageSource, blink: {} as CanvasImageSource, dispose: vi.fn() };
}

describe("private mascot lifetime", () => {
  it("fetches once per revision and drops stale fetches on same-revision server changes", async () => {
    const old = deferred<unknown>();
    const currentPack = pack();
    const request = vi.fn().mockReturnValueOnce(old.promise).mockResolvedValueOnce(syntheticPack());
    const decode = vi.fn().mockResolvedValue(currentPack);
    const loader = new PrivateMascotLoader(request, vi.fn(), decode);
    loader.setConnection("paired-a"); loader.observe(revisionA); loader.observe(revisionA);
    expect(request).toHaveBeenCalledTimes(1);
    loader.setConnection("paired-b");
    expect(request.mock.calls[0][1].aborted).toBe(true);
    loader.observe(revisionA); await settle();
    old.resolve(syntheticPack()); await settle();
    expect(loader.state.pack).toBe(currentPack);
    expect(decode).toHaveBeenCalledTimes(1);
    loader.observe(revisionA);
    expect(request).toHaveBeenCalledTimes(2);
    loader.observe(null);
    expect(loader.state.pack).toBeNull();
    expect(currentPack.dispose).toHaveBeenCalledOnce();
  });

  it("releases a decode that finishes after disable, revision removal or server switch", async () => {
    for (const invalidate of [
      (loader: PrivateMascotLoader) => loader.setEnabled(false),
      (loader: PrivateMascotLoader) => loader.observe(undefined),
      (loader: PrivateMascotLoader) => loader.setConnection("paired-b"),
      (loader: PrivateMascotLoader) => loader.reset(),
    ]) {
      const pending = deferred<PrivateMascotPack>(), image = pack();
      const loader = new PrivateMascotLoader(vi.fn().mockResolvedValue(syntheticPack()), vi.fn(), () => pending.promise);
      loader.setConnection("paired-a"); loader.observe(revisionA); await settle();
      invalidate(loader); pending.resolve(image); await settle();
      expect(loader.state.pack).toBeNull();
      expect(image.dispose).toHaveBeenCalledOnce();
    }
  });

  it("bounds retries, waits on stale revisions and surfaces host errors without breaking listing", async () => {
    let now = 0;
    const request = vi.fn().mockRejectedValue(Error("Pack unavailable"));
    const loader = new PrivateMascotLoader(request, vi.fn(), vi.fn(), () => now);
    loader.setConnection("paired-a");
    loader.observe(revisionA); await settle();
    loader.observe(revisionA); expect(request).toHaveBeenCalledTimes(1);
    now = 2000; loader.observe(revisionA); await settle();
    now = 9999; loader.observe(revisionA); expect(request).toHaveBeenCalledTimes(2);
    now = 10000; loader.observe(revisionA); await settle();
    now = 999999; loader.observe(revisionA); expect(request).toHaveBeenCalledTimes(3);
    request.mockRejectedValue(Object.assign(Error("Stale revision"), { status: 409 }));
    loader.observe(revisionB); await settle();
    now += 999999; loader.observe(revisionB); expect(request).toHaveBeenCalledTimes(4);
    loader.observe(null, "Configured pack is unreadable");
    expect(loader.state.error).toContain("Configured pack is unreadable");
    loader.observe(null);
    expect(loader.state.error).toBeNull();
    loader.setEnabled(false); loader.observe(revisionA);
    expect(request).toHaveBeenCalledTimes(4);
    const recovered = pack();
    request.mockResolvedValue(syntheticPack());
    const decode = vi.fn().mockResolvedValue(recovered);
    const fresh = new PrivateMascotLoader(request, vi.fn(), decode);
    fresh.setConnection("paired-a"); fresh.setEnabled(false); fresh.observe(revisionA);
    fresh.setEnabled(true); await settle();
    expect(fresh.state.pack).toBe(recovered);
  });
});

describe("private PNG validation and animation", () => {
  it("validates metadata and bounded square PNGs before decoding; releases partial failures", async () => {
    const close = vi.fn();
    const decode = vi.fn().mockResolvedValue({ width: 1, height: 1, close });
    vi.stubGlobal("createImageBitmap", decode);
    for (const invalid of [
      { ...syntheticPack(), revision: revisionB }, { ...syntheticPack(), sparkX: NaN },
      { ...syntheticPack(), blink: "https://invalid.test/image.png" },
      { ...syntheticPack(), portrait: syntheticPNG(2, 1) },
      { ...syntheticPack(), blink: syntheticPNG(2) },
      { ...syntheticPack(), portrait: "A".repeat(2666672) },
    ]) await expect(decodePrivateMascot(invalid, revisionA)).rejects.toThrow();
    expect(decode).not.toHaveBeenCalled();
    const valid = await decodePrivateMascot(syntheticPack(), revisionA);
    expect(decode).toHaveBeenCalledTimes(2);
    valid.dispose(); expect(close).toHaveBeenCalledTimes(2);
    decode.mockClear().mockResolvedValueOnce({ width: 1, height: 1, close }).mockRejectedValueOnce(Error("decode"));
    await expect(decodePrivateMascot(syntheticPack(), revisionA)).rejects.toThrow("decode");
    expect(close).toHaveBeenCalledTimes(3);
  });

  it("keeps reduced motion deterministic, blinks briefly and bounds the celebration", () => {
    for (const mood of MOODS) expect(personalMascotPose(mood, 4.72, true, 0.6)).toEqual(personalMascotPose(mood, 100, true, null));
    expect(personalMascotPose("idle", 4.64, false, null).closed).toBe(false);
    expect(personalMascotPose("idle", 4.7, false, null).closed).toBe(true);
    expect(personalMascotPose("sleeping", 1, true, null).closed).toBe(true);
    expect(personalMascotPose("idle", 1, false, 0.6).hop).toBeLessThan(0);
    expect(personalMascotPose("idle", 1, false, 1.2).hop).toBe(0);
  });

  it("choosing a built-in disables personal mode and persists only the preference", async () => {
    const saved = new Map<string, string>();
    vi.stubGlobal("localStorage", { getItem: (key: string) => saved.get(key) ?? null, setItem: (key: string, value: string) => saved.set(key, value) });
    const prefs = await import("../src/gateway/ui/pip/prefs");
    expect(prefs.personalMascotEnabled.value).toBe(true);
    prefs.setMascotOutfit("dinoHoodie");
    expect(prefs.personalMascotEnabled.value).toBe(false);
    expect(saved.get("cantrip.mascot.personal.enabled")).toBe("false");
    prefs.setPersonalMascotEnabled(true);
    expect([...saved.keys()].sort()).toEqual(["cantrip.mascot.outfit", "cantrip.mascot.personal.enabled"]);
  });
});
