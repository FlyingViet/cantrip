import type { CantripApi } from "../shared/types";

declare global {
  interface Window {
    cantrip: CantripApi;
  }
}

export {};
