// Settings › Location (off by default): this PC's location with each message, so weather and "near
// me" answers are for where you are. From the Windows Location service (Chromium's platform provider),
// only while the app is in use: one fix when a message is sent, reused for up to 15 minutes, rounded
// to about 1 km unless Precise is on. The Mac names the place; it travels only with that message.
import type { ClientLocation } from "../api/types";

export const SHARE_KEY = "cantrip.location.share";
export const PRECISE_KEY = "cantrip.location.precise";
export const MAX_AGE_MS = 15 * 60 * 1000;

export interface Fix {
  at: number;
  precise: boolean;
  latitude: number;
  longitude: number;
  accuracy: number;
}

export function readFlag(key: string, storage: Pick<Storage, "getItem"> | undefined = globalThis.localStorage): boolean {
  try { return JSON.parse(storage?.getItem(key) ?? "false") === true; } catch { return false; }
}

export function writeFlag(key: string, value: boolean, storage: Pick<Storage, "setItem"> | undefined = globalThis.localStorage): void {
  storage?.setItem(key, JSON.stringify(value));
}

/** The message's `location`: coarse fixes rounded to 0.01° and never claiming better than 1 km. */
export function toClientLocation(fix: Fix, now: number, timeZone: string, device: string): ClientLocation {
  const round = (value: number) => (fix.precise ? Math.round(value * 1e5) / 1e5 : Math.round(value * 100) / 100);
  return {
    latitude: round(fix.latitude), longitude: round(fix.longitude),
    accuracy: Math.round(fix.precise ? fix.accuracy : Math.max(1000, fix.accuracy)), precise: fix.precise,
    timeZone, age: Math.max(0, Math.round((now - fix.at) / 1000)), device,
  };
}

export type Reading = { fix: Fix } | { error: string };

/** One position from the system, or why there isn't one. */
export function readPosition(precise: boolean, geolocation: Geolocation | undefined = globalThis.navigator?.geolocation,
  now: () => number = Date.now): Promise<Reading> {
  return new Promise((resolve) => {
    if (!geolocation) { resolve({ error: "Location isn't available on this PC." }); return; }
    geolocation.getCurrentPosition(
      (position) => resolve({ fix: {
        at: Math.min(now(), position.timestamp || now()), precise,
        latitude: position.coords.latitude, longitude: position.coords.longitude, accuracy: position.coords.accuracy,
      } }),
      (error) => resolve({ error: error.code === 1
        ? "Location access is off for desktop apps. Turn it on in Windows Settings › Privacy & security › Location."
        : "This PC couldn't find its location." }),
      { enableHighAccuracy: precise, maximumAge: MAX_AGE_MS, timeout: precise ? 10000 : 6000 },
    );
  });
}

let cached: Fix | null = null;

export function forgetFix(): void { cached = null; }

/** The location for the message being sent; null while sharing is off or no fix arrives. */
export async function messageLocation(options: {
  storage?: Pick<Storage, "getItem">; geolocation?: Geolocation; now?: () => number; device?: string; timeZone?: string;
} = {}): Promise<ClientLocation | null> {
  const storage = options.storage ?? globalThis.localStorage;
  if (!readFlag(SHARE_KEY, storage)) return null;
  const precise = readFlag(PRECISE_KEY, storage);
  const now = options.now ?? Date.now;
  if (!cached || cached.precise !== precise || now() - cached.at > MAX_AGE_MS) {
    const reading = await readPosition(precise, options.geolocation ?? globalThis.navigator?.geolocation, now);
    if (!("fix" in reading)) { cached = null; return null; }
    cached = reading.fix;
  }
  return toClientLocation(cached, now(), options.timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone,
    options.device ?? (globalThis.navigator?.userAgent?.includes("Windows") ? "Windows PC" : "Mac"));
}
