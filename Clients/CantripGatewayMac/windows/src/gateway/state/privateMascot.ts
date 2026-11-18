import { effect, signal } from "@preact/signals";
import { api } from "../api/client";
import { bridge } from "../bridge";
import { personalMascotEnabled } from "../ui/pip/prefs";
import { PrivateMascotLoader, type PersonalMascotState } from "../ui/pip/privateMascot";

export const personalMascot = signal<PersonalMascotState>({ revision: null, pack: null, loading: false, error: null });
export const privateMascotLoader = new PrivateMascotLoader(
  (revision, signal) => api(`/api/v1/mascot?revision=${revision}`, { signal, cache: "no-store" }),
  (state) => { personalMascot.value = state; },
);
const connectionKey = (status: typeof bridge.status) => status.connectionID ?? status.server;
privateMascotLoader.setConnection(connectionKey(bridge.status) || "gateway");
bridge.onStatus((status) => privateMascotLoader.setConnection(connectionKey(status)));
effect(() => privateMascotLoader.setEnabled(personalMascotEnabled.value));
window.addEventListener("pagehide", () => privateMascotLoader.reset());
