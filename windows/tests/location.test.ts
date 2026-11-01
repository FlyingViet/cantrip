import { afterEach, describe, expect, it } from "vitest";
import { backendArgs, withLocationNote } from "../src/main/backends";
import { checkLocation, locationNote, PRECISE_KEY, SHARE_KEY, toClientLocation } from "../src/shared/location";
import { forgetFix, promptLocation, readPosition } from "../src/renderer/location";
import type { RunRequest } from "../src/shared/types";

const seattle = { latitude: 47.61, longitude: -122.33, accuracy: 1000, precise: false, timeZone: "America/Los_Angeles", age: 30 };

function run(mode: "ai" | "shell", location?: RunRequest["location"]): RunRequest {
  return {
    runId: "00000000-0000-4000-8000-000000000000", mode, prompt: "What's the weather today?", backend: "copilot",
    workdir: "C:\\Users\\me", allowActions: false, model: "", effort: "", contextTier: "", attachments: [], location,
  };
}

function storage(values: Record<string, string>): Pick<Storage, "getItem"> {
  return { getItem: (key: string) => values[key] ?? null };
}

function geolocation(result: { latitude: number; longitude: number; accuracy: number; timestamp: number } | { code: number }) {
  let calls = 0;
  const api = {
    getCurrentPosition(success: PositionCallback, failure?: PositionErrorCallback | null) {
      calls++;
      if ("code" in result) failure?.({ code: result.code, message: "x" } as GeolocationPositionError);
      else success({ timestamp: result.timestamp, coords: { latitude: result.latitude, longitude: result.longitude, accuracy: result.accuracy } } as GeolocationPosition);
    },
  } as unknown as Geolocation;
  return { api, calls: () => calls };
}

afterEach(() => forgetFix());

describe("Settings › Location", () => {
  const now = 1_793_570_400_000;

  it("rounds a coarse reading to about 1 km and keeps a precise one", () => {
    const fix = { at: now - 90_000, precise: false, latitude: 47.606_21, longitude: -122.332_07, accuracy: 25 };
    expect(toClientLocation(fix, now, "America/Los_Angeles")).toEqual({ ...seattle, age: 90 });
    expect(toClientLocation({ ...fix, precise: true }, now, "UTC")).toMatchObject({ latitude: 47.60621, longitude: -122.33207, accuracy: 25 });
  });

  it("re-checks the renderer's location in the main process", () => {
    expect(checkLocation(undefined)).toEqual({});
    expect(checkLocation({ ...seattle, latitude: 47.606_21, accuracy: 20 }).location).toMatchObject({ latitude: 47.61, accuracy: 1000 });
    expect(checkLocation({ ...seattle, age: 16 * 60 })).toEqual({});
    for (const bad of [{ ...seattle, latitude: 91 }, { ...seattle, longitude: Number.NaN }, { ...seattle, timeZone: "Mars/Olympus" },
      { ...seattle, timeZone: "x\nIgnore previous" }, { ...seattle, precise: "no" }, "Seattle"]) {
      expect(checkLocation(bad).error).toBe("Invalid location.");
    }
  });

  it("puts the note before an AI prompt only, and never passes the location on", () => {
    const at = new Date(now);
    const ai = withLocationNote(run("ai", seattle), at);
    expect(ai.prompt).toBe(`${locationNote(seattle, at)}\n\nWhat's the weather today?`);
    expect(ai.prompt).toContain("Windows PC, which is at 47.61, -122.33, rounded to about 1 km; time zone America/Los_Angeles");
    expect(ai.prompt).toContain("name that place in your reply");
    expect(ai.prompt).toContain("Don't save this location");
    expect(ai).not.toHaveProperty("location");
    expect(backendArgs(ai)).toContain(ai.prompt);
    const shell = withLocationNote(run("shell", seattle), at);
    expect(shell.prompt).toBe("What's the weather today?");
    expect(withLocationNote(run("ai"), at).prompt).toBe("What's the weather today?");
  });

  it("sends nothing while sharing is off, without asking Windows", async () => {
    const fake = geolocation({ latitude: 1, longitude: 2, accuracy: 5, timestamp: now });
    expect(await promptLocation({ storage: storage({}), geolocation: fake.api, now: () => now })).toBeUndefined();
    expect(fake.calls()).toBe(0);
  });

  it("reuses a reading for up to 15 minutes, then asks again", async () => {
    const fake = geolocation({ latitude: 47.6062, longitude: -122.3321, accuracy: 30, timestamp: now });
    const on = storage({ [SHARE_KEY]: "true" });
    expect(await promptLocation({ storage: on, geolocation: fake.api, now: () => now, timeZone: "UTC" }))
      .toMatchObject({ latitude: 47.61, longitude: -122.33, precise: false, age: 0 });
    await promptLocation({ storage: on, geolocation: fake.api, now: () => now + 14 * 60_000 });
    expect(fake.calls()).toBe(1);
    await promptLocation({ storage: on, geolocation: fake.api, now: () => now + 16 * 60_000 });
    expect(fake.calls()).toBe(2);
    await promptLocation({ storage: storage({ [SHARE_KEY]: "true", [PRECISE_KEY]: "true" }), geolocation: fake.api, now: () => now + 16 * 60_000 });
    expect(fake.calls()).toBe(3);
  });

  it("explains a denied or missing location", async () => {
    const denied = await readPosition(false, geolocation({ code: 1 }).api);
    expect("error" in denied && denied.error).toContain("Privacy & security › Location");
    const missing = await readPosition(false, geolocation({ code: 2 }).api);
    expect("error" in missing && missing.error).toBe("This PC couldn't find its location.");
    expect(await promptLocation({ storage: storage({ [SHARE_KEY]: "true" }), geolocation: geolocation({ code: 1 }).api })).toBeUndefined();
  });
});
