import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({ app: { getLocaleCountryCode: () => "US" }, ipcMain: { handle: vi.fn() } }));

import { withLocationNote, withWeatherGuidance } from "../src/main/backends";
import { preferredUnit, WeatherService } from "../src/main/weather";
import {
  asksAboutWeather, buildCard, decodeWeatherBlock, displayName, extractWeatherBlock, parseCoordinate, pickGeocode,
  visibleWeatherText, WEATHER_GUIDANCE,
} from "../src/shared/weather";
import type { RunRequest } from "../src/shared/types";

const fixture = JSON.parse(readFileSync(new URL("./open-meteo-seattle.json", import.meta.url), "utf8"));
/** 2:15 PM PST, Sunday, November 1, 2026: the fixture's "current" time. */
const fixtureNow = new Date(1_793_571_300 * 1000);

function run(prompt: string, mode: "ai" | "shell" = "ai"): RunRequest {
  return {
    runId: "00000000-0000-4000-8000-000000000000", mode, prompt, backend: "copilot", workdir: "C:\\Users\\me",
    allowActions: false, model: "", effort: "", contextTier: "", attachments: [],
  };
}

describe("weather block", () => {
  it("is taught only to prompts about the weather, before the location note", () => {
    expect(asksAboutWeather("What's the weather today?")).toBe(true);
    expect(asksAboutWeather("Do I need an umbrella in Seattle?")).toBe(true);
    expect(asksAboutWeather("Refactor the forecast service")).toBe(true);
    expect(asksAboutWeather("Explain the project")).toBe(false);
    expect(withWeatherGuidance(run("Will it rain tomorrow?")).prompt).toBe(`Will it rain tomorrow?\n\n${WEATHER_GUIDANCE}`);
    expect(withWeatherGuidance(run("Get-Weather", "shell")).prompt).toBe("Get-Weather");
    const located = { ...run("Explain the project"), location: { latitude: 47.61, longitude: -122.33, accuracy: 1000, precise: false, timeZone: "UTC", age: 1 } };
    expect(withLocationNote(withWeatherGuidance(located)).prompt).not.toContain("```weather");
  });

  it("parses the place and hides the block, even while it streams", () => {
    const reply = 'Clear in Seattle.\n\n```weather\n{"place":"Seattle, WA"}\n```';
    expect(extractWeatherBlock(reply)).toEqual({ text: "Clear in Seattle.", place: "Seattle, WA", found: true });
    expect(extractWeatherBlock("Here.\n```cantrip-weather\n{}\n```").place).toBeNull();
    expect(extractWeatherBlock("No block here.")).toEqual({ text: "No block here.", place: undefined, found: false });
    expect(extractWeatherBlock("x\n```weather\n{oops\n```")).toEqual({ text: "x", place: undefined, found: true });
    expect(decodeWeatherBlock('{"near":"Austin, TX"}')).toBe("Austin, TX");
    expect(decodeWeatherBlock('"Tokyo"')).toBe("Tokyo");
    expect(decodeWeatherBlock(`{"place":"${"x".repeat(300)}"}`)?.length).toBe(120);
    expect(visibleWeatherText('Sunny.\n\n```weather\n{"pla', true)).toBe("Sunny.");
    expect(visibleWeatherText("Sunny.\n```wea", true)).toBe("Sunny.");
    expect(visibleWeatherText("Code:\n```", false)).toBe("Code:\n```");
    expect(visibleWeatherText("Code:\n```ts\nlet x = 1", true)).toContain("let x = 1");
  });

  it("geocodes with the state or country the place names", () => {
    const results = { results: [
      { latitude: 45.52, longitude: -122.68, admin1: "Oregon", country: "United States", country_code: "US" },
      { latitude: 43.66, longitude: -70.26, admin1: "Maine", country: "United States", country_code: "US" },
    ] };
    expect(pickGeocode(results, "Portland, ME")).toEqual({ latitude: 43.66, longitude: -70.26 });
    expect(pickGeocode(results, "Portland")).toEqual({ latitude: 45.52, longitude: -122.68 });
    expect(pickGeocode({ results: [] }, "Atlantis")).toBeNull();
    expect(parseCoordinate("47.6062, -122.3321")).toEqual({ latitude: 47.6062, longitude: -122.3321 });
    expect(parseCoordinate("Seattle, WA")).toBeNull();
    expect(displayName("Seattle, WA, United States (47.61, -122.33)")).toBe("Seattle, WA");
  });
});

describe("weather card", () => {
  it("builds the Mac's card shape from Open-Meteo", () => {
    const card = buildCard(fixture, "Seattle, WA", undefined, "F", fixtureNow, "en-US");
    expect(card.status).toBe("ok");
    expect(card.current).toMatchObject({ temperature: 48, feelsLike: 45, condition: "Clear", symbol: "sun.max.fill", precipitationChance: 0 });
    expect(card.today).toEqual({ high: 48, low: 38, precipitationChance: 1 });
    expect(card.hourly?.map((hour) => hour.label.replace(/\u202f/g, " ")).slice(0, 3)).toEqual(["Now", "3 PM", "4 PM"]);
    expect(card.hourly).toHaveLength(13);
    expect(card.daily?.map((day) => day.label).slice(0, 2)).toEqual(["Today", "Mon"]);
    expect(card.daily?.[0]).toMatchObject({ date: "2026-11-01", condition: "Fog", symbol: "cloud.fog.fill" });
    expect(card.daily).toHaveLength(10);
    expect(() => buildCard({ error: true }, "x", undefined, "F", fixtureNow)).toThrow();
  });

  it("fetches through Open-Meteo once per 10 minutes and says when it can't", async () => {
    const urls: string[] = [];
    let now = fixtureNow;
    const service = new WeatherService(async (url) => {
      urls.push(url);
      if (url.includes("geocoding-api")) {
        return url.includes("Atlantis") ? { results: [] } : { results: [{ latitude: 47.6062, longitude: -122.3321, admin1: "Washington", country_code: "US" }] };
      }
      return fixture;
    }, () => now, () => "F");
    const card = await service.card({ place: "Seattle, WA" });
    expect(card).toMatchObject({ status: "ok", place: "Seattle, WA" });
    expect(urls[1]).toContain("latitude=47.61&longitude=-122.33");
    now = new Date(fixtureNow.getTime() + 5 * 60_000);
    await service.card({ place: "seattle, wa" });
    expect(urls).toHaveLength(2);
    now = new Date(fixtureNow.getTime() + 11 * 60_000);
    await service.card({ place: "Seattle, WA" });
    expect(urls).toHaveLength(3);

    expect(await service.card({ place: "Atlantis" })).toMatchObject({ status: "unavailable", message: "Couldn't find “Atlantis” to get its forecast." });
    expect(await service.card({ place: null })).toMatchObject({ status: "unavailable", place: "Weather" });
    const here = await service.card({ place: null, location: { latitude: 47.67, longitude: -122.38, accuracy: 1000, precise: false, timeZone: "America/Los_Angeles", age: 10 } });
    expect(here).toMatchObject({ status: "ok", place: "Your location", placeNote: "This PC's location" });
    expect(await service.card("nonsense")).toMatchObject({ status: "unavailable" });

    const down = new WeatherService(async () => { throw new Error("offline"); }, () => fixtureNow, () => "F");
    const failed = await down.card({ place: "47.61, -122.33" });
    expect(failed).toEqual({
      place: "47.61, -122.33", status: "unavailable", unit: "F", message: "Couldn't get the forecast from Open-Meteo. Ask again in a moment.",
      attribution: "Weather data by Open-Meteo.com", attributionURL: "https://open-meteo.com/", placeNote: undefined,
    });
  });

  it("uses Fahrenheit in the US", () => {
    expect(preferredUnit("US")).toBe("F");
    expect(preferredUnit("de")).toBe("C");
  });
});
