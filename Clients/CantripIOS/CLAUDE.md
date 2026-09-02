# CLAUDE.md — Hermes (iOS client)

Native SwiftUI iOS client for a self-hosted **Hermes agent** (`~/.hermes`) — voice
+ chat, as an alternative to talking to Hermes through Telegram/Discord. See
`README.md` for end-to-end setup (gateway + app).

## Build / run
- `xcodegen generate`, then build or test with
  `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all`
  so SwiftPM can use its scoped bare-repository cache.
- The `.xcodeproj` is generated (git-ignored); regenerate after editing `project.yml`.
- iOS 26+, universal (`TARGETED_DEVICE_FAMILY "1,2"`). Set your own bundle id +
  signing team in `project.yml` before building to a device.

## How it connects
- Talks to the Hermes gateway's **OpenAI-compatible API server** adapter
  (`gateway/platforms/api_server.py`), NOT the raw inference shim. The api_server
  is the full agent (skills, memory, sessions).
- Chat uses **`POST /v1/runs`** with a persisted `Idempotency-Key`, then
  `GET /v1/runs/{id}/events` for live SSE and `GET /v1/runs/{id}` for
  authoritative recovery. Closing iOS never calls `/stop`; only explicit user
  cancellation interrupts server work.
- The app persists a pending request before POST and an active run immediately
  after `202`. A lost response can safely replay the same idempotency key.
- Headers: `Authorization: Bearer <API_SERVER_KEY>`, `X-Hermes-Session-Key`
  (stable per-install id → scopes long-term memory). The base URL is user-set in
  Settings — nothing hardcoded.
- Execution uses named gateway model routes. `copilot-coding` is the default;
  `local-private` remains unavailable until explicitly advertised by
  `/v1/models`. Never silently fall back from the private lane to Copilot.
- Copilot and local lanes keep separate local transcripts, durable runs,
  conversation IDs, and long-term-memory session keys.
- Non-loopback HTTP is rejected. Use HTTPS over a private network or
  authenticated tunnel; loopback HTTP is only for simulator development.
- Run events drive the UI: `message.delta`, `tool.started`/`tool.completed`,
  `approval.request`, and `run.completed`/`run.failed`.
- Optional `GET /v1/commands` powers the `/` autocomplete + Skills list (see README).

## Voice
- Fully on-device: FluidAudio Parakeet EOU 120M (320 ms model) is the default
  STT engine; `SFSpeechRecognizer` with `requiresOnDeviceRecognition` is the
  fallback. TTS remains Qwen or `AVSpeechSynthesizer`.
- The AVAudioEngine tap deep-copies buffers into one bounded serial consumer.
  A generation token prevents EOU/timer/cancellation races from submitting an
  utterance twice. Parakeet and Qwen release memory before switching engines.

## Gateway-side prerequisite
The api_server adapter must be enabled + reachable. It refuses non-localhost
binding without `API_SERVER_KEY`. To use it away from home, expose it over an
HTTPS tunnel. Full steps (incl. a copy-paste setup prompt) are in `README.md`.

## Conventions
- Keep SwiftUI `body` lean (extract subviews) — the type-checker chokes on long chains.
- The API key lives in the Keychain (`hermes.apiKey`), never in the repo.
- The gateway URL defaults to empty so each user points at their own server.
