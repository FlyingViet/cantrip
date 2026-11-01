// Weather cards: a reply about the weather ends with a fenced `weather` block naming the place,
// and Cantrip shows an Open-Meteo forecast for it (never numbers the model wrote). The same card
// as Cantrip on the Mac; here the main process fetches it, since there's no Mac.

export const MAX_PLACE_LENGTH = 120;
export const HOUR_COUNT = 12;
export const DAY_COUNT = 10;
export const ATTRIBUTION = "Weather data by Open-Meteo.com";
export const ATTRIBUTION_URL = "https://open-meteo.com/";

export interface WeatherHour {
  time: string;
  label: string;
  temperature: number;
  condition: string;
  symbol: string;
  precipitationChance?: number;
}

export interface WeatherDay {
  date: string;
  label: string;
  high: number;
  low: number;
  condition: string;
  symbol: string;
  precipitationChance?: number;
}

/** The Mac's `WeatherCard.snapshot` shape. */
export interface WeatherCard {
  place: string;
  placeNote?: string;
  status: "ok" | "unavailable";
  message?: string;
  unit: "F" | "C";
  attribution: string;
  attributionURL: string;
  timeZone?: string;
  updatedAt?: string;
  current?: { temperature: number; feelsLike?: number; condition: string; symbol: string; code: number; isDay: boolean; precipitationChance?: number };
  today?: { high: number; low: number; precipitationChance?: number };
  hourly?: WeatherHour[];
  daily?: WeatherDay[];
}

/** Prompts that get the weather block guidance: only these, so other prompts stay unchanged. */
export function asksAboutWeather(prompt: string): boolean {
  return /\b(weather|forecast|temperature|rain(y|ing)?|snow(y|ing)?|umbrella|sunny|cloudy|humid(ity)?|windy|storms?|thunder(storms?)?|degrees outside)\b/i.test(prompt);
}

export const WEATHER_GUIDANCE =
  "(Cantrip: if this asks about the weather, end your reply with a fenced `weather` JSON block naming the place, " +
  "for example\n```weather\n{\"place\":\"Seattle, WA\"}\n```\nso Cantrip shows an Open-Meteo forecast card " +
  "(now, the next 12 hours and 10 days) under your text. Use the place I asked about; otherwise where I am. Keep your " +
  "text short, don't state temperatures or chances of rain unless a tool gave them to you, and don't link to weather " +
  "websites.)";

/** The weather block's place: a string, null for "where I am" (`{}`), undefined for no valid block. */
export function decodeWeatherBlock(raw: string): string | null | undefined {
  let value: unknown;
  try {
    value = JSON.parse(raw.trim());
  } catch {
    return undefined;
  }
  if (typeof value === "string") return cleanPlace(value);
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const object = value as Record<string, unknown>;
  const place = ["place", "near", "location"].map((key) => object[key]).find((item) => typeof item === "string");
  return typeof place === "string" ? cleanPlace(place) : null;
}

export function cleanPlace(place: string): string | null {
  // eslint-disable-next-line no-control-regex
  const clean = place.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, MAX_PLACE_LENGTH).trim();
  return clean || null;
}

const BLOCK = /```[ \t]*(?:cantrip-)?weather[ \t]*\r?\n([\s\S]*?)```/gi;

/** The reply without weather blocks, and the last block's place (undefined: no valid block). */
export function extractWeatherBlock(text: string): { text: string; place: string | null | undefined; found: boolean } {
  let place: string | null | undefined;
  let found = false;
  const stripped = text.replace(BLOCK, (_match, payload: string) => {
    found = true;
    const decoded = decodeWeatherBlock(payload);
    if (decoded !== undefined) place = decoded;
    return "";
  });
  return { text: found ? stripped.trim() : text, place, found };
}

/** What the transcript shows: no weather block, and while streaming not even one still being written. */
export function visibleWeatherText(text: string, streaming: boolean): string {
  const { text: stripped } = extractWeatherBlock(text);
  if (!streaming) return stripped;
  const open = /(^|\n)[ \t]*```[ \t]*(?:cantrip-)?weather[ \t]*\r?\n?[^`]*$/i.exec(stripped);
  const cut = open ? stripped.slice(0, open.index) : stripped;
  // A fence whose tag could still become "weather" (```, ```wea, ```cantrip-w).
  const lines = cut.split("\n");
  const last = lines[lines.length - 1].trim().toLowerCase();
  if (last.startsWith("```")) {
    const tag = last.replace(/^`+/, "").trim();
    if ("weather".startsWith(tag) || "cantrip-weather".startsWith(tag)) lines.pop();
  }
  return lines.join("\n").trimEnd();
}

export function conditionText(code: number): string {
  const names: Record<number, string> = {
    0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Cloudy", 45: "Fog", 48: "Freezing fog", 51: "Light drizzle",
    53: "Drizzle", 55: "Heavy drizzle", 56: "Light freezing drizzle", 57: "Freezing drizzle", 61: "Light rain", 63: "Rain",
    65: "Heavy rain", 66: "Light freezing rain", 67: "Freezing rain", 71: "Light snow", 73: "Snow", 75: "Heavy snow",
    77: "Snow grains", 80: "Light showers", 81: "Showers", 82: "Heavy showers", 85: "Snow showers", 86: "Heavy snow showers",
    95: "Thunderstorms", 96: "Thunderstorms with hail", 99: "Thunderstorms with heavy hail",
  };
  return names[code] ?? "Unknown";
}

/** The Mac's SF Symbol names, so every client maps the same icons. */
export function conditionSymbol(code: number, isDay: boolean): string {
  if (code === 0) return isDay ? "sun.max.fill" : "moon.stars.fill";
  if (code === 1 || code === 2) return isDay ? "cloud.sun.fill" : "cloud.moon.fill";
  if (code === 3) return "cloud.fill";
  if (code === 45 || code === 48) return "cloud.fog.fill";
  if ([51, 53, 55].includes(code)) return "cloud.drizzle.fill";
  if ([56, 57, 66, 67].includes(code)) return "cloud.sleet.fill";
  if (code === 61 || code === 63) return "cloud.rain.fill";
  if (code === 65 || code === 82) return "cloud.heavyrain.fill";
  if ([71, 73, 75, 77, 85, 86].includes(code)) return "cloud.snow.fill";
  if (code === 80 || code === 81) return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill";
  if (code === 95) return "cloud.bolt.rain.fill";
  if (code === 96 || code === 99) return "cloud.hail.fill";
  return "cloud.fill";
}

export function unavailableCard(place: string, message: string, unit: "F" | "C", placeNote?: string): WeatherCard {
  return { place, placeNote, status: "unavailable", message, unit, attribution: ATTRIBUTION, attributionURL: ATTRIBUTION_URL };
}

/** "Seattle, WA" for "Seattle, WA, United States (47.61, -122.33)". */
export function displayName(raw: string): string {
  const parts = raw.replace(/\s*\([^)]*\)/g, "").split(",").map((part) => part.trim()).filter(Boolean);
  if (parts.length > 1 && ["united states", "united states of america", "usa", "us"].includes(parts[parts.length - 1].toLowerCase())) parts.pop();
  return (parts.join(", ") || raw).slice(0, 80);
}

/** "47.61, -122.33" as a place. */
export function parseCoordinate(text: string): { latitude: number; longitude: number } | null {
  const parts = text.replace(/[()]/g, "").split(",").map((part) => part.trim());
  if (parts.length !== 2 || parts.some((part) => !/^-?\d+(\.\d+)?$/.test(part))) return null;
  const [latitude, longitude] = parts.map(Number);
  return Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180 ? { latitude, longitude } : null;
}

export function forecastUrl(latitude: number, longitude: number, unit: "F" | "C"): string {
  const query = new URLSearchParams({
    latitude: latitude.toFixed(2), longitude: longitude.toFixed(2),
    current: "temperature_2m,apparent_temperature,weather_code,is_day",
    hourly: "temperature_2m,weather_code,precipitation_probability,is_day",
    daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
    temperature_unit: unit === "C" ? "celsius" : "fahrenheit", timezone: "auto",
    forecast_days: String(DAY_COUNT), forecast_hours: String(HOUR_COUNT + 2), timeformat: "unixtime",
  });
  return `https://api.open-meteo.com/v1/forecast?${query}`;
}

export function geocodeUrl(place: string): string {
  const name = place.split(",")[0].trim();
  return `https://geocoding-api.open-meteo.com/v1/search?${new URLSearchParams({ name, count: "10", language: "en", format: "json" })}`;
}

const US_STATES: Record<string, string> = {
  al: "alabama", ak: "alaska", az: "arizona", ar: "arkansas", ca: "california", co: "colorado", ct: "connecticut",
  de: "delaware", dc: "district of columbia", fl: "florida", ga: "georgia", hi: "hawaii", id: "idaho", il: "illinois",
  in: "indiana", ia: "iowa", ks: "kansas", ky: "kentucky", la: "louisiana", me: "maine", md: "maryland",
  ma: "massachusetts", mi: "michigan", mn: "minnesota", ms: "mississippi", mo: "missouri", mt: "montana",
  ne: "nebraska", nv: "nevada", nh: "new hampshire", nj: "new jersey", nm: "new mexico", ny: "new york",
  nc: "north carolina", nd: "north dakota", oh: "ohio", ok: "oklahoma", or: "oregon", pa: "pennsylvania",
  ri: "rhode island", sc: "south carolina", sd: "south dakota", tn: "tennessee", tx: "texas", ut: "utah", vt: "vermont",
  va: "virginia", wa: "washington", wv: "west virginia", wi: "wisconsin", wy: "wyoming",
};

interface GeocodeResult { latitude: number; longitude: number; admin1?: string; country?: string; country_code?: string }

/** The geocoder's best match for "Portland, ME": the first result whose state or country fits. */
export function pickGeocode(json: unknown, place: string): { latitude: number; longitude: number } | null {
  const results = ((json as { results?: unknown })?.results ?? []) as GeocodeResult[];
  const valid = Array.isArray(results)
    ? results.filter((item) => Number.isFinite(item?.latitude) && Number.isFinite(item?.longitude)) : [];
  if (!valid.length) return null;
  const qualifiers = place.replace(/\s*\([^)]*\)/g, "").split(",").slice(1).map((part) => part.trim().toLowerCase()).filter(Boolean);
  const fits = (item: GeocodeResult) => qualifiers.every((qualifier) => {
    const names = [item.admin1, item.country, item.country_code].map((value) => value?.toLowerCase());
    return names.includes(qualifier) || names.includes(US_STATES[qualifier])
      || (["usa", "us", "united states", "united states of america"].includes(qualifier) && item.country_code === "US");
  });
  const best = valid.find(fits) ?? valid[0];
  return { latitude: best.latitude, longitude: best.longitude };
}

type Series = (number | null)[];

/** An Open-Meteo `/v1/forecast` answer (`timeformat=unixtime`) as a card for `now`. */
export function buildCard(json: unknown, place: string, placeNote: string | undefined, unit: "F" | "C", now: Date, locale?: string): WeatherCard {
  const root = json as Record<string, any>;
  const current = root?.current, hourly = root?.hourly, daily = root?.daily;
  const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : null);
  if (!current || !hourly || !daily || num(current.temperature_2m) === null || num(current.weather_code) === null) {
    throw new Error("Malformed forecast");
  }
  const timeZone = typeof root.timezone === "string" ? root.timezone : "UTC";
  const dayKey = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  const hourLabel = new Intl.DateTimeFormat(locale, { timeZone, hour: "numeric" });
  const dayLabel = new Intl.DateTimeFormat(locale, { timeZone, weekday: "short" });
  const at = (series: Series | undefined, index: number) => num(series?.[index]);
  const times: Series = hourly.time ?? [];
  const nowSeconds = now.getTime() / 1000;
  const currentTime = num(current.time) ?? nowSeconds;
  let currentChance: number | undefined;
  const hours: WeatherHour[] = [];
  times.forEach((time, index) => {
    const temperature = at(hourly.temperature_2m, index), code = at(hourly.weather_code, index);
    if (time === null || temperature === null || code === null) return;
    const chance = at(hourly.precipitation_probability, index);
    if (time <= currentTime) currentChance = chance === null ? undefined : Math.round(chance);
    if (time <= nowSeconds || hours.length >= HOUR_COUNT) return;
    const date = new Date(time * 1000);
    hours.push({
      time: date.toISOString(), label: hourLabel.format(date), temperature: Math.round(temperature),
      condition: conditionText(code), symbol: conditionSymbol(code, at(hourly.is_day, index) !== 0),
      ...(chance === null ? {} : { precipitationChance: Math.round(chance) }),
    });
  });
  const today = dayKey.format(now);
  const days: WeatherDay[] = [];
  ((daily.time ?? []) as Series).forEach((time, index) => {
    const high = at(daily.temperature_2m_max, index), low = at(daily.temperature_2m_min, index), code = at(daily.weather_code, index);
    if (time === null || high === null || low === null || code === null) return;
    const date = new Date(time * 1000), key = dayKey.format(date);
    if (key < today || days.length >= DAY_COUNT) return;
    const chance = at(daily.precipitation_probability_max, index);
    days.push({
      date: key, label: days.length === 0 ? "Today" : dayLabel.format(date), high: Math.round(high), low: Math.round(low),
      condition: conditionText(code), symbol: conditionSymbol(code, true),
      ...(chance === null ? {} : { precipitationChance: Math.round(chance) }),
    });
  });
  if (!days.length) throw new Error("Malformed forecast");
  const code = current.weather_code as number, isDay = num(current.is_day) !== 0;
  const feelsLike = num(current.apparent_temperature);
  const nowItem = {
    temperature: Math.round(current.temperature_2m), condition: conditionText(code), symbol: conditionSymbol(code, isDay),
    code, isDay, ...(feelsLike === null ? {} : { feelsLike: Math.round(feelsLike) }),
    ...(currentChance === undefined ? {} : { precipitationChance: currentChance }),
  };
  return {
    place, ...(placeNote ? { placeNote } : {}), status: "ok", unit, attribution: ATTRIBUTION, attributionURL: ATTRIBUTION_URL,
    timeZone, updatedAt: now.toISOString(), current: nowItem,
    today: { high: days[0].high, low: days[0].low, ...(days[0].precipitationChance === undefined ? {} : { precipitationChance: days[0].precipitationChance }) },
    hourly: [{ time: now.toISOString(), label: "Now", temperature: nowItem.temperature, condition: nowItem.condition, symbol: nowItem.symbol,
      ...(currentChance === undefined ? {} : { precipitationChance: currentChance }) }, ...hours],
    daily: days,
  };
}
