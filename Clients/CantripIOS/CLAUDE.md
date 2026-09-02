# CLAUDE.md — Hermes (iOS client)

Native SwiftUI iOS client for a self-hosted **Hermes agent** (`~/.hermes`) — voice
+ chat, as an alternative to talking to Hermes through Telegram/Discord. See
`README.md` for end-to-end setup (gateway + app).

## Build / run
- `xcodegen generate` then `xcodebuild -scheme Hermes -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO`.
- The `.xcodeproj` is generated (git-ignored); regenerate after editing `project.yml`.
- iOS 26+, universal (`TARGETED_DEVICE_FAMILY "1,2"`). Set your own bundle id +
  signing team in `project.yml` before building to a device.

## How it connects
- Talks to the Hermes gateway's **OpenAI-compatible API server** adapter
  (`gateway/platforms/api_server.py`), NOT the raw inference shim. The api_server
  is the full agent (skills, memory, sessions).
- Endpoint: **`POST /v1/responses`** (stateful via `previous_response_id`), streamed
  as SSE. We send only the new turn; the gateway chains history server-side.
- Headers: `Authorization: Bearer <API_SERVER_KEY>`, `X-Hermes-Session-Key`
  (stable per-install id → scopes long-term memory). The base URL is user-set in
  Settings — nothing hardcoded.
- Execution uses named gateway model routes. `copilot-coding` is the default;
  `local-private` remains unavailable until explicitly advertised by
  `/v1/models`. Never silently fall back from the private lane to Copilot.
- Copilot and local lanes keep separate local transcripts,
  `previous_response_id` chains, and long-term-memory session keys.
- Non-loopback HTTP is rejected. Use HTTPS over a private network or
  authenticated tunnel; loopback HTTP is only for simulator development.
- SSE events drive the UI: `response.output_text.delta` → streamed text;
  `function_call` / `function_call_output` → inline tool/skill activity (the
  "see Hermes working" rows); `response.completed`/`failed` → end.
- Optional `GET /v1/commands` powers the `/` autocomplete + Skills list (see README).

## Voice
- Fully on-device: `SFSpeechRecognizer` (STT) + `AVSpeechSynthesizer` (TTS) in
  `VoiceController`. Push-to-talk (mic) + a full-screen voice mode (listen →
  send → speak → listen). No audio leaves the device. Defaults to the best
  installed voice; download a Premium voice for near-Siri quality.

## Gateway-side prerequisite
The api_server adapter must be enabled + reachable. It refuses non-localhost
binding without `API_SERVER_KEY`. To use it away from home, expose it over an
HTTPS tunnel. Full steps (incl. a copy-paste setup prompt) are in `README.md`.

## Conventions
- Keep SwiftUI `body` lean (extract subviews) — the type-checker chokes on long chains.
- The API key lives in the Keychain (`hermes.apiKey`), never in the repo.
- The gateway URL defaults to empty so each user points at their own server.
