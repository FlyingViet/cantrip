import { app, ipcMain } from "electron";
import { weatherDocument, type CardDocument } from "../shared/cards";
import { checkLocation } from "../shared/location";
import {
  buildCard, cleanPlace, displayName, forecastUrls, geocodeUrl, parseCoordinate, pickGeocode, unavailableCard, type WeatherCard,
} from "../shared/weather";

type FetchJSON = (url: string) => Promise<unknown>;

const FORECAST_LIFETIME_MS = 10 * 60 * 1000;
const GEOCODE_LIFETIME_MS = 24 * 60 * 60 * 1000;

/** Open-Meteo only, no cookies, 6 seconds at most. */
async function fetchOpenMeteo(url: string): Promise<unknown> {
  const host = new URL(url).hostname;
  if (host !== "api.open-meteo.com" && host !== "geocoding-api.open-meteo.com") throw new Error("Not Open-Meteo");
  const response = await fetch(url, { signal: AbortSignal.timeout(6_000), credentials: "omit", redirect: "error" });
  if (!response.ok) throw new Error(`Open-Meteo answered ${response.status}`);
  const text = await response.text();
  if (text.length > 512 * 1024) throw new Error("Open-Meteo answer too large");
  return JSON.parse(text);
}

/** Fahrenheit in the US (and Liberia and Myanmar), else Celsius. */
export function preferredUnit(country: string = app.getLocaleCountryCode()): "F" | "C" {
  return ["US", "LR", "MM"].includes(country.toUpperCase()) ? "F" : "C";
}

/**
 * The forecast for a reply's weather block: the place it names (geocoded by Open-Meteo), else this
 * PC's location while Settings → Location is on. Forecasts are reused for 10 minutes, places for a day;
 * Open-Meteo only ever sees coordinates rounded to about 1 km.
 */
export class WeatherService {
  private forecasts = new Map<string, { json: unknown; at: number }>();
  private places = new Map<string, { latitude: number; longitude: number; at: number }>();

  constructor(
    private readonly fetchJSON: FetchJSON = fetchOpenMeteo,
    private readonly now: () => Date = () => new Date(),
    private readonly unit: () => "F" | "C" = () => preferredUnit(),
  ) {}

  /** `request` comes from the renderer: `{ place?: string | null, location?: ClientLocation }`. */
  async card(request: unknown): Promise<WeatherCard> {
    const unit = this.unit();
    if (!request || typeof request !== "object" || Array.isArray(request)) {
      return unavailableCard("Weather", "Forecast unavailable.", unit);
    }
    const raw = (request as Record<string, unknown>).place;
    const place = typeof raw === "string" ? cleanPlace(raw) : null;
    const { location } = checkLocation((request as Record<string, unknown>).location);
    let coordinate: { latitude: number; longitude: number } | null;
    let title: string;
    let note: string | undefined;
    if (place) {
      title = displayName(place);
      coordinate = parseCoordinate(place) ?? (await this.geocode(place));
      if (!coordinate) return unavailableCard(title, `Couldn't find “${title}” to get its forecast.`, unit);
    } else if (location) {
      title = "Your location";
      note = "This PC's location";
      coordinate = { latitude: location.latitude, longitude: location.longitude };
    } else {
      return unavailableCard("Weather", "No place to forecast: name a place, or turn on Settings → Location.", unit);
    }
    const latitude = Math.round(coordinate.latitude * 100) / 100, longitude = Math.round(coordinate.longitude * 100) / 100;
    const key = `${latitude.toFixed(2)},${longitude.toFixed(2)},${unit}`;
    const now = this.now();
    try {
      let cached = this.forecasts.get(key);
      if (!cached || Math.abs(now.getTime() - cached.at) >= FORECAST_LIFETIME_MS) {
        const urls = forecastUrls(latitude, longitude, unit);
        const [current, daily] = await Promise.all([this.fetchJSON(urls.now), this.fetchJSON(urls.daily)]);
        cached = { json: { ...(current as object), daily: (daily as { daily?: unknown })?.daily }, at: now.getTime() };
        this.forecasts.set(key, cached);
        if (this.forecasts.size > 64) this.forecasts.delete(this.forecasts.keys().next().value as string);
      }
      const card = buildCard(cached.json, title, note, unit, now);
      return { ...card, updatedAt: new Date(cached.at).toISOString() };
    } catch {
      return unavailableCard(title, "Couldn't get the forecast from Open-Meteo. Ask again in a moment.", unit, note);
    }
  }

  /** The forecast as a card document (docs/cards.md), which the renderer draws block by block. */
  async document(request: unknown): Promise<CardDocument> {
    return weatherDocument(await this.card(request));
  }

  private async geocode(place: string): Promise<{ latitude: number; longitude: number } | null> {
    const key = place.toLowerCase();
    const hit = this.places.get(key);
    if (hit && this.now().getTime() - hit.at < GEOCODE_LIFETIME_MS) return hit;
    try {
      const found = pickGeocode(await this.fetchJSON(geocodeUrl(place)), place);
      if (found) this.places.set(key, { ...found, at: this.now().getTime() });
      return found;
    } catch {
      return null;
    }
  }
}

export function registerWeatherIPC(service = new WeatherService()): void {
  ipcMain.handle("weather:card", (_event, request: unknown) => service.document(request));
}
