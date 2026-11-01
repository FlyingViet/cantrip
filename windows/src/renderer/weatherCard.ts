// The weather card under a reply: plain DOM, the same layout as Cantrip's other clients.
import type { WeatherCard } from "../shared/weather";

// Lucide outlines (ISC), the icons Cantrip Gateway for Windows uses; constants, never reply data.
const ICONS: Record<string, string> = {"sun.max.fill":"<circle cx='12' cy='12' r='4'/><path d='M12 2v2'/><path d='M12 20v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='m17.66 17.66 1.41 1.41'/><path d='M2 12h2'/><path d='M20 12h2'/><path d='m6.34 17.66-1.41 1.41'/><path d='m19.07 4.93-1.41 1.41'/>","moon.stars.fill":"<path d='M18 5h4'/><path d='M20 3v4'/><path d='M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401'/>","cloud.sun.fill":"<path d='M12 2v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='M20 12h2'/><path d='m19.07 4.93-1.41 1.41'/><path d='M15.947 12.65a4 4 0 0 0-5.925-4.128'/><path d='M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6Z'/>","cloud.moon.fill":"<path d='M13 16a3 3 0 0 1 0 6H7a5 5 0 1 1 4.9-6z'/><path d='M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36'/>","cloud.fill":"<path d='M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z'/>","cloud.fog.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 17H7'/><path d='M17 21H9'/>","cloud.drizzle.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 19v1'/><path d='M8 14v1'/><path d='M16 19v1'/><path d='M16 14v1'/><path d='M12 21v1'/><path d='M12 16v1'/>","cloud.rain.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 14v6'/><path d='M8 14v6'/><path d='M12 16v6'/>","cloud.heavyrain.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='m9.2 22 3-7'/><path d='m9 13-3 7'/><path d='m17 13-3 7'/>","cloud.sleet.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 15h.01'/><path d='M8 19h.01'/><path d='M12 17h.01'/><path d='M12 21h.01'/><path d='M16 15h.01'/><path d='M16 19h.01'/>","cloud.snow.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M8 15h.01'/><path d='M8 19h.01'/><path d='M12 17h.01'/><path d='M12 21h.01'/><path d='M16 15h.01'/><path d='M16 19h.01'/>","cloud.sun.rain.fill":"<path d='M12 2v2'/><path d='m4.93 4.93 1.41 1.41'/><path d='M20 12h2'/><path d='m19.07 4.93-1.41 1.41'/><path d='M15.947 12.65a4 4 0 0 0-5.925-4.128'/><path d='M3 20a5 5 0 1 1 8.9-4H13a3 3 0 0 1 2 5.24'/><path d='M11 20v2'/><path d='M7 19v2'/>","cloud.moon.rain.fill":"<path d='M11 20v2'/><path d='M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36'/><path d='M3 20a5 5 0 1 1 8.9-4H13a3 3 0 0 1 2 5.24'/><path d='M7 19v2'/>","cloud.bolt.rain.fill":"<path d='M6 16.326A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 .5 8.973'/><path d='m13 12-3 5h4l-3 5'/>","cloud.hail.fill":"<path d='M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242'/><path d='M16 14v2'/><path d='M8 14v2'/><path d='M16 20h.01'/><path d='M8 20h.01'/><path d='M12 16v2'/><path d='M12 22h.01'/>"};

function el(tag: string, className?: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/** Sun gold, moon pale, rain and snow blue, clouds and fog grey. */
export function weatherTint(symbol: string): "sun" | "moon" | "wet" | "cloud" {
  if (symbol === "sun.max.fill") return "sun";
  if (symbol === "moon.stars.fill") return "moon";
  return /rain|drizzle|snow|sleet|hail|bolt/.test(symbol) ? "wet" : "cloud";
}

function glyph(symbol: string | undefined, className = "weather-glyph"): HTMLElement {
  const key = symbol && ICONS[symbol] ? symbol : "cloud.fill";
  const node = el("span", `${className} ${weatherTint(key)}`);
  node.setAttribute("aria-hidden", "true");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  for (const [name, value] of [["viewBox", "0 0 24 24"], ["fill", "none"], ["stroke", "currentColor"], ["stroke-width", "2"],
    ["stroke-linecap", "round"], ["stroke-linejoin", "round"]]) svg.setAttribute(name, value);
  svg.innerHTML = ICONS[key];
  node.append(svg);
  return node;
}

const chance = (value: number | undefined) => (typeof value === "number" && value >= 10 ? `${value}%` : "");
const spokenChance = (value: number | undefined) =>
  typeof value === "number" && value >= 10 ? `, ${value} percent chance of precipitation` : "";

export function renderWeatherLoading(container: HTMLElement): void {
  container.replaceChildren(el("div", "weather-card weather-loading", "Getting the forecast from Open-Meteo…"));
  container.classList.remove("hidden");
}

export function renderWeatherCard(container: HTMLElement, card: WeatherCard, openExternal: (url: string) => void): void {
  const unitName = card.unit === "C" ? "degrees Celsius" : "degrees Fahrenheit";
  const current = card.status === "ok" ? card.current : undefined;
  const wrap = el("section", "weather-card");
  wrap.setAttribute("aria-label", `Weather for ${card.place || "this place"}`);

  const head = el("div", "weather-head"), info = el("div", "weather-info");
  info.append(el("div", "weather-place", card.place || "Weather"));
  if (card.placeNote) info.append(el("div", "weather-note", card.placeNote));
  head.append(info);
  if (current) {
    info.append(el("div", "weather-cond", current.condition));
    const details: string[] = [];
    if (card.today) {
      details.push(`H ${card.today.high}°  L ${card.today.low}°`);
      if (typeof card.today.precipitationChance === "number") details.push(`${card.today.precipitationChance}% precip.`);
    }
    if (typeof current.feelsLike === "number" && Math.abs(current.feelsLike - current.temperature) >= 3) {
      details.push(`Feels like ${current.feelsLike}°`);
    }
    if (details.length) info.append(el("div", "weather-detail", details.join(" · ")));
    const now = el("div", "weather-now");
    now.setAttribute("role", "img");
    now.setAttribute("aria-label", `Now ${current.temperature} ${unitName}, ${current.condition}`);
    now.append(glyph(current.symbol, "weather-glyph weather-now-icon"), el("span", "weather-now-temp", `${current.temperature}°`));
    head.append(now);
  } else {
    info.append(el("div", "weather-unavailable", "Forecast unavailable"), el("div", "weather-reason", card.message || "Ask again in a moment."));
  }
  wrap.append(head);

  if (current) {
    const hours = el("div", "weather-hours");
    hours.setAttribute("role", "list");
    hours.setAttribute("aria-label", "Hourly forecast");
    for (const hour of (card.hourly ?? []).slice(0, 13)) {
      const item = el("div", "weather-hour");
      item.setAttribute("role", "listitem");
      item.setAttribute("aria-label", `${hour.label}, ${hour.temperature} ${unitName}, ${hour.condition}${spokenChance(hour.precipitationChance)}`);
      item.append(el("span", "", hour.label), glyph(hour.symbol), el("span", "weather-chance", chance(hour.precipitationChance)),
        el("span", "weather-hour-temp", `${hour.temperature}°`));
      hours.append(item);
    }
    const daily = (card.daily ?? []).slice(0, 10);
    const lowest = Math.min(...daily.map((day) => day.low)), span = Math.max(1, Math.max(...daily.map((day) => day.high)) - lowest);
    const days = el("div", "weather-days");
    days.setAttribute("role", "list");
    days.setAttribute("aria-label", `${daily.length}-day forecast`);
    for (const day of daily) {
      const row = el("div", "weather-day");
      row.setAttribute("role", "listitem");
      row.setAttribute("aria-label", `${day.label}, ${day.condition}, high ${day.high}, low ${day.low} ${unitName}${spokenChance(day.precipitationChance)}`);
      const bar = el("span", "weather-bar"), fill = el("span");
      bar.setAttribute("aria-hidden", "true");
      fill.style.left = `${((day.low - lowest) / span) * 100}%`;
      fill.style.width = `${Math.max(4, ((day.high - day.low) / span) * 100)}%`;
      bar.append(fill);
      row.append(el("span", "weather-day-label", day.label), glyph(day.symbol), el("span", "weather-chance", chance(day.precipitationChance)),
        el("span", "weather-low", `${day.low}°`), bar, el("span", "weather-high", `${day.high}°`));
      days.append(row);
    }
    wrap.append(hours, days);
  }

  const foot = el("div", "weather-foot");
  const updated = current && card.updatedAt ? new Date(card.updatedAt) : null;
  if (updated && !Number.isNaN(updated.getTime())) {
    foot.append(el("span", "", `Updated ${updated.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`));
  }
  const attribution = el("button", "weather-attr", card.attribution || "Weather data by Open-Meteo.com") as HTMLButtonElement;
  attribution.type = "button";
  attribution.addEventListener("click", () => openExternal("https://open-meteo.com/"));
  foot.append(attribution);
  wrap.append(foot);

  container.replaceChildren(wrap);
  container.classList.remove("hidden");
}
