// A shared ticking clock for ages and elapsed times (one timer for the whole window).
import { signal } from "@preact/signals";

/** Milliseconds; updates every second while anything reads it. */
export const now = signal(Date.now());
setInterval(() => { now.value = Date.now(); }, 1000);
