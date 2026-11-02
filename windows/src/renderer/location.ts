// Settings › Location: reads this PC's location from the Windows Location service (Chromium's
// platform provider) only when a prompt is sent, and reuses one reading for up to 15 minutes.
import { MAX_AGE_MS, PRECISE_KEY, SHARE_KEY, toClientLocation, type ClientLocation, type Fix } from "../shared/location";

export function readFlag(key: string, storage: Pick<Storage, "getItem"> | undefined = globalThis.localStorage): boolean {
  return storage?.getItem(key) === "true";
}

export type Reading = { fix: Fix } | { error: string };

/** One reading from the system, or why there isn't one. */
export function readPosition(
  precise: boolean,
  geolocation: Geolocation | undefined = globalThis.navigator?.geolocation,
  now: () => number = Date.now,
): Promise<Reading> {
  return new Promise((resolve) => {
    if (!geolocation) {
      resolve({ error: "Location isn't available on this PC." });
      return;
    }
    geolocation.getCurrentPosition(
      (position) => resolve({
        fix: {
          at: Math.min(now(), position.timestamp || now()),
          precise,
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          accuracy: position.coords.accuracy,
        },
      }),
      (error) => resolve({
        error: error.code === 1
          ? "Location access is off for desktop apps. Turn it on in Windows Settings › Privacy & security › Location."
          : "This PC couldn't find its location.",
      }),
      { enableHighAccuracy: precise, maximumAge: MAX_AGE_MS, timeout: precise ? 10_000 : 6_000 },
    );
  });
}

let cached: Fix | null = null;

export function forgetFix(): void {
  cached = null;
}

/** The location for the prompt being sent; undefined while sharing is off or no reading arrives. */
export async function promptLocation(options: {
  storage?: Pick<Storage, "getItem">;
  geolocation?: Geolocation;
  now?: () => number;
  timeZone?: string;
} = {}): Promise<ClientLocation | undefined> {
  const storage = options.storage ?? globalThis.localStorage;
  if (!readFlag(SHARE_KEY, storage)) return undefined;
  const precise = readFlag(PRECISE_KEY, storage);
  const now = options.now ?? Date.now;
  if (!cached || cached.precise !== precise || now() - cached.at > MAX_AGE_MS) {
    const reading = await readPosition(precise, options.geolocation ?? globalThis.navigator?.geolocation, now);
    if (!("fix" in reading)) {
      cached = null;
      return undefined;
    }
    cached = reading.fix;
  }
  return toClientLocation(cached, now(), options.timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone);
}
