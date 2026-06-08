# CLAUDE.md — Hermes (iOS client)

Native SwiftUI iOS client for the **Hermes agent** (`~/.hermes`) — voice + chat,
as an alternative to talking to Hermes through Telegram/Discord. Sibling of
`../Plexa` / `../netlib`; reuses their bones (Keychain, `Env` ObservableObject,
`App` routing shape).

## Build / run
- `xcodegen generate` then `xcodebuild -scheme Hermes -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO`.
- The `.xcodeproj` is generated (git-ignored); regenerate after editing `project.yml`.
- iOS 26+, universal (`TARGETED_DEVICE_FAMILY "1,2"`), bundle `com.itzhoang.hermes`.

## How it connects
- Talks to the Hermes gateway's **OpenAI-compatible API server** adapter
  (`gateway/platforms/api_server.py`), NOT the raw `claude -p` shim. The api_server
  is the full agent (skills, memory, sessions).
- Endpoint: **`POST /v1/responses`** (stateful via `previous_response_id`), streamed
  as SSE. We send only the new turn; the gateway chains history server-side.
- Headers: `Authorization: Bearer <API_SERVER_KEY>`, `X-Hermes-Session-Key`
  (stable per-install id → scopes long-term memory). Configurable base URL — LAN
  (`http://192.168.0.94:8642`) at home or the Cloudflare tunnel hostname anywhere.
- SSE events drive the UI: `response.output_text.delta` → streamed text;
  `function_call` / `function_call_output` → inline tool/skill activity (the
  "see Hermes working" rows); `response.completed`/`failed` → end.

## Voice
- Fully on-device: `SFSpeechRecognizer` (STT) + `AVSpeechSynthesizer` (TTS) in
  `VoiceController`. Push-to-talk (mic button) + a hands-free loop toggle
  (listen → silence → send → speak reply → listen again). No audio leaves the device.

## Gateway-side prerequisite
The api_server adapter must be enabled + reachable. It refuses non-localhost
binding without `API_SERVER_KEY`. To use away from home it needs a Cloudflare
tunnel (like the shim's `hermes.example-home.com`). See the vault note
`01_Projects/hermes-ios/` for the enablement steps.

## Conventions
- Match Plexa/NetLib style. Keep `body` lean (extract subviews) — the SwiftUI
  type-checker chokes on long chains.
- API key in the Keychain (`hermes.apiKey`), never in the repo.
