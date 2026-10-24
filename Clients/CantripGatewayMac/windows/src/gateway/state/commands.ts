// The tab backend's slash commands and skills per session (GET /api/v1/sessions/<id>/commands),
// cached for the composer's suggestions (rules in ./slashCommands).
import { signal } from "@preact/signals";
import { api, pathComponent } from "../api/client";
import { CommandsCache } from "./slashCommands";

/** Bumped whenever a cached list or its loading state changes. */
export const commandsVersion = signal(0);

export const commandsCache = new CommandsCache(
  (sessionID) => api<unknown>(`/api/v1/sessions/${pathComponent(sessionID)}/commands`),
  { onChange: () => { commandsVersion.value++; } },
);
