// Settings › Location (off by default): this PC's location with each AI prompt, so weather and
// "near me" answers are for where you are. The renderer reads the Windows Location service
// (Chromium's platform provider) only when a prompt is sent, reuses one reading for up to
// 15 minutes, and rounds it to about 1 km unless Precise is on. The main process re-validates it
// and adds a note to that prompt only; nothing about it is stored.

export const SHARE_KEY = "location.share";
export const PRECISE_KEY = "location.precise";
export const MAX_AGE_MS = 15 * 60 * 1000;

export interface ClientLocation {
  latitude: number;
  longitude: number;
  accuracy: number;
  precise: boolean;
  timeZone: string;
  /** Seconds since the reading. */
  age: number;
}

export interface Fix {
  at: number;
  precise: boolean;
  latitude: number;
  longitude: number;
  accuracy: number;
}

const round = (value: number, precise: boolean) =>
  precise ? Math.round(value * 1e5) / 1e5 : Math.round(value * 100) / 100;

export function toClientLocation(fix: Fix, now: number, timeZone: string): ClientLocation {
  return {
    latitude: round(fix.latitude, fix.precise),
    longitude: round(fix.longitude, fix.precise),
    accuracy: Math.round(fix.precise ? fix.accuracy : Math.max(1000, fix.accuracy)),
    precise: fix.precise,
    timeZone,
    age: Math.max(0, Math.round((now - fix.at) / 1000)),
  };
}

/**
 * The run's location as the main process accepts it: undefined when absent, a re-rounded copy
 * when valid (a coarse one never gets finer than 0.01°), or an error.
 */
export function checkLocation(value: unknown): { location?: ClientLocation; error?: string } {
  if (value === undefined || value === null) return {};
  const invalid = { error: "Invalid location." };
  if (typeof value !== "object") return invalid;
  const item = value as Record<string, unknown>;
  const { latitude, longitude, accuracy, precise, timeZone, age } = item;
  if (typeof latitude !== "number" || !Number.isFinite(latitude) || Math.abs(latitude) > 90) return invalid;
  if (typeof longitude !== "number" || !Number.isFinite(longitude) || Math.abs(longitude) > 180) return invalid;
  if (typeof accuracy !== "number" || !Number.isFinite(accuracy) || accuracy < 0 || accuracy > 1_000_000) return invalid;
  if (typeof precise !== "boolean") return invalid;
  if (typeof timeZone !== "string" || !/^[A-Za-z0-9_+\-/]{1,64}$/.test(timeZone) || !isTimeZone(timeZone)) return invalid;
  if (typeof age !== "number" || !Number.isFinite(age) || age < 0) return invalid;
  if (age * 1000 > MAX_AGE_MS) return {};
  return {
    location: {
      latitude: round(latitude, precise),
      longitude: round(longitude, precise),
      accuracy: Math.round(precise ? accuracy : Math.max(1000, accuracy)),
      precise,
      timeZone,
      age: Math.round(age),
    },
  };
}

function isTimeZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}

/** The note that goes before the prompt, telling the backend where this PC is. */
export function locationNote(location: ClientLocation, now: Date = new Date()): string {
  const coordinates = `${location.latitude.toFixed(location.precise ? 5 : 2)}, ${location.longitude.toFixed(location.precise ? 5 : 2)}`;
  const accuracy = location.precise ? `, within about ${location.accuracy} m` : ", rounded to about 1 km";
  const localTime = new Intl.DateTimeFormat("en-US", {
    timeZone: location.timeZone, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  }).format(now);
  return `(Context: I'm on my Windows PC, which is at ${coordinates}${accuracy}; time zone ${location.timeZone}, `
    + `local time ${localTime}. For anything that depends on where I am (weather, "near me", local time, places), `
    + "use this location, work out the place it's in, and name that place in your reply. Don't save this location "
    + "in memory, notes, tasks or files. If my request doesn't depend on location, ignore this and don't mention it.)";
}
