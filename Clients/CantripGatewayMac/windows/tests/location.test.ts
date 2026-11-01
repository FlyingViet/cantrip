import { afterEach, describe, expect, it } from "vitest";
import { forgetFix, messageLocation, PRECISE_KEY, readPosition, SHARE_KEY, toClientLocation } from "../src/gateway/state/location";

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

  it("rounds a coarse fix to about 1 km and keeps a precise one", () => {
    const fix = { at: now - 90_000, precise: false, latitude: 47.606_21, longitude: -122.332_07, accuracy: 25 };
    expect(toClientLocation(fix, now, "America/Los_Angeles", "Windows PC")).toEqual({
      latitude: 47.61, longitude: -122.33, accuracy: 1000, precise: false, timeZone: "America/Los_Angeles", age: 90, device: "Windows PC",
    });
    expect(toClientLocation({ ...fix, precise: true }, now, "UTC", "Windows PC")).toMatchObject({ latitude: 47.60621, longitude: -122.33207, accuracy: 25 });
  });

  it("sends nothing while sharing is off, without asking the system", async () => {
    const fake = geolocation({ latitude: 1, longitude: 2, accuracy: 5, timestamp: now });
    expect(await messageLocation({ storage: storage({}), geolocation: fake.api, now: () => now })).toBeNull();
    expect(fake.calls()).toBe(0);
  });

  it("reuses a fix for up to 15 minutes, then asks again", async () => {
    const fake = geolocation({ latitude: 47.6062, longitude: -122.3321, accuracy: 30, timestamp: now });
    const on = storage({ [SHARE_KEY]: "true" });
    const first = await messageLocation({ storage: on, geolocation: fake.api, now: () => now, timeZone: "UTC", device: "Windows PC" });
    expect(first).toMatchObject({ latitude: 47.61, longitude: -122.33, precise: false, age: 0, device: "Windows PC" });
    await messageLocation({ storage: on, geolocation: fake.api, now: () => now + 14 * 60_000 });
    expect(fake.calls()).toBe(1);
    await messageLocation({ storage: on, geolocation: fake.api, now: () => now + 16 * 60_000 });
    expect(fake.calls()).toBe(2);
    await messageLocation({ storage: storage({ [SHARE_KEY]: "true", [PRECISE_KEY]: "true" }), geolocation: fake.api, now: () => now + 16 * 60_000 });
    expect(fake.calls()).toBe(3);
  });

  it("explains a denied or missing location", async () => {
    const denied = await readPosition(false, geolocation({ code: 1 }).api);
    expect("error" in denied && denied.error).toContain("Privacy & security › Location");
    const missing = await readPosition(false, geolocation({ code: 2 }).api);
    expect("error" in missing && missing.error).toBe("This PC couldn't find its location.");
    expect(await messageLocation({ storage: storage({ [SHARE_KEY]: "true" }), geolocation: geolocation({ code: 1 }).api })).toBeNull();
  });
});
