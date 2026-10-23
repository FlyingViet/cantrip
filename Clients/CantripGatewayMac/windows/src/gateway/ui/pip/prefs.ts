// Pip's outfit and name, saved per device under the same keys as the Mac and iPhone apps' @AppStorage.
import { computed, signal } from "@preact/signals";
import {
  DEFAULT_MASCOT_NAME, DEFAULT_OUTFIT, MASCOT_NAME_KEY, MASCOT_OUTFIT_KEY, displayName, isOutfitID, type OutfitID,
} from "./mascot";

function read(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value);
  } catch {
    // Storage can be unavailable or full; the choice still applies for this session.
  }
}

const parseOutfit = (raw: string | null): OutfitID => (isOutfitID(raw) ? raw : DEFAULT_OUTFIT);

/** The saved outfit; unknown stored values fall back to Starry Plush. */
export const mascotOutfit = signal<OutfitID>(parseOutfit(read(MASCOT_OUTFIT_KEY)));

/** The stored name as saved: empty means the default, Pip. Show `mascotDisplayName` instead. */
export const mascotName = signal<string>(read(MASCOT_NAME_KEY) ?? "");

/** `CantripMascotName.display(storedName)`. */
export const mascotDisplayName = computed(() => displayName(mascotName.value));

export function setMascotOutfit(outfit: OutfitID): void {
  mascotOutfit.value = outfit;
  write(MASCOT_OUTFIT_KEY, outfit);
}

/** Saves a sanitized name (the default is stored as empty, like Swift) and returns what to show. */
export function setMascotName(name: string): string {
  const display = displayName(name);
  const stored = display === DEFAULT_MASCOT_NAME ? "" : display;
  mascotName.value = stored;
  write(MASCOT_NAME_KEY, stored);
  return display;
}

/** Back to Pip. */
export function resetMascotName(): void {
  setMascotName("");
}

// Other windows of the app share localStorage; follow their changes.
if (typeof window !== "undefined") {
  window.addEventListener("storage", (event) => {
    if (event.key === MASCOT_OUTFIT_KEY) mascotOutfit.value = parseOutfit(event.newValue);
    else if (event.key === MASCOT_NAME_KEY) mascotName.value = event.newValue ?? "";
    else if (event.key === null) {
      mascotOutfit.value = parseOutfit(read(MASCOT_OUTFIT_KEY));
      mascotName.value = read(MASCOT_NAME_KEY) ?? "";
    }
  });
}
