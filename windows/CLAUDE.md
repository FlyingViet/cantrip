# Cantrip Windows

## Purpose

Native-feeling Windows counterpart to FlyingViet/cantrip: a keyboard-first AI
launcher summoned with Alt+Space.

## Stack

- Electron 41
- TypeScript 7
- Vite 8
- Vitest 4
- Plain DOM/CSS renderer (no UI framework)

## Commands

- `npm install` — install dependencies
- `npm run dev` — build and launch the app
- `npm test` — run unit tests
- `npm run typecheck` — type-check main, preload, shared, and renderer code
- `npm run build` — production build
- `npm run package:win` — create a Windows NSIS installer

## Architecture

- `src/main/` owns all OS access, process spawning, global shortcuts, and IPC.
- `src/preload/` exposes a narrow context-isolated API.
- `src/renderer/` is an unprivileged launcher UI.
- `src/shared/` contains pure types, matching, math, and unit conversion logic.

## Conventions

- Keep `contextIsolation` enabled and `nodeIntegration` disabled.
- Never expose arbitrary Electron or Node APIs to the renderer.
- Validate all IPC input in the main process.
- Keep privileged behavior explicit: shell commands require `!`; agent actions
  require the user-controlled action toggle.
- Add or update unit tests for pure launcher behavior.
