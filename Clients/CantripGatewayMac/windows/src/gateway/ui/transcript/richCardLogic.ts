import type { RemotePlacePin } from "../../api/types";

export function isSafePublicUrl(raw: string | undefined): boolean {
  if (!raw) return false;
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    if (parsed.username || parsed.password) return false;
    const host = parsed.hostname.toLowerCase();
    if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return false;
    if (host.endsWith(".ts.net")) return false;
    if (/^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(host)) {
      return false;
    }
    return true;
  } catch {
    return false;
  }
}

export function placeDirectionsUrl(place: RemotePlacePin): string {
  if (place.appleMapsURL && isSafePublicUrl(place.appleMapsURL)) return place.appleMapsURL;
  const q = encodeURIComponent(place.name);
  return `https://maps.apple.com/?q=${q}&ll=${place.latitude.toFixed(6)},${place.longitude.toFixed(6)}`;
}

export function lonToTileX(lon: number, z: number): number {
  return ((lon + 180) / 360) * Math.pow(2, z);
}

export function latToTileY(lat: number, z: number): number {
  const rad = (lat * Math.PI) / 180;
  return ((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * Math.pow(2, z);
}

export function initialZoomForDelta(delta: number): number {
  const d = Math.max(delta || 0.04, 0.01);
  if (d <= 0.015) return 15;
  if (d <= 0.035) return 14;
  if (d <= 0.08) return 13;
  if (d <= 0.18) return 12;
  return 11;
}
