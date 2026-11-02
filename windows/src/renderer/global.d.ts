import type { CantripApi } from "../shared/types";
import type { CantripHomeApi } from "../shared/home";

declare global {
  interface Window {
    cantrip: CantripApi;
    /** Only in the Cantrip Home window (homePreload.ts). */
    cantripHome: CantripHomeApi;
  }
}

export {};
