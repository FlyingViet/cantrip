# Hermes — iOS client (AgentGateway)

<img src="Sources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png" width="128" alt="Cantrip: a pearl-violet C casting a golden spark" />

The app icon shares Cantrip's **C and golden spark** mark. Its opaque 1024px
source comes from `Resources/CantripIcon.png` in the Cantrip repository;
regenerate it there with `make artwork`, then copy it to
`Sources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`. Do not add rounded
corners or transparent padding to the iOS asset; the system applies the mask.

A native SwiftUI app for talking to your own [**Hermes Agent**](https://github.com/) — by **voice** and **chat** — instead of being stuck in Telegram or Discord.

- 💬 **Durable streaming chat** — tasks continue on the Mac if iOS suspends or
  closes; reopen the app to recover the current status and final response
- 🎙️ **Voice mode** — local Parakeet EOU transcription plus a full-screen,
  hands-free *listen → think → speak* loop
- ⚡ **`/` autocomplete** + a **Skills browser** (tap a skill to run it)
- 🔘 **Action Button / Shortcuts / Siri** — "Talk to Hermes" jumps straight into voice mode
- 💾 **Persistent history** — reopen to your prior conversation
- 🔑 **Your gateway, your key** — points at *your* Hermes server, nothing hardcoded
- 📡 **Cantrip Remote** — choose Cantrip from the agent picker and use the same
  chat, dictation, hands-free voice, and TTS interface

> The app is a thin, secure client. All the intelligence (skills, memory, tools) lives in **your** Hermes gateway. You bring the gateway + an API key; the app does the rest.

---

## How it works

```
  iPhone (AgentGateway)  ──HTTPS + bearer key──►  private network / tunnel
                                                        │
                                                        ▼
                                       Hermes gateway api_server  (:8642)
                                         POST /v1/runs       (durable task)
                                         GET  /v1/runs/:id   (recovery)
                                         GET  /events        (live SSE)
                                         GET  /v1/commands    (optional)
                                                        │
                                                        ▼
                                            Your Hermes agent
                                       (skills · memory · tools · model)
```

The app speaks the gateway's **OpenAI-compatible API server** (`gateway/platforms/api_server.py`), which is the *full agent* — not the raw inference shim.

## Cantrip Remote

Tap the agent badge under the conversation title (the `</>` badge when Copilot is selected)
and choose **Cantrip Remote**. It attaches to Cantrip's existing session IDs
rather than launching another agent. Cantrip then uses the same transcript,
composer, microphone, hands-free voice mode, and spoken replies as Hermes.
Remote-only controls above the transcript provide session selection, new
sessions and conversations, queued/redirected/injected prompts, stop, and
resume.

Tap the large **tab dropdown** above the transcript to switch sessions instead
of scrolling through small pills. The menu marks the selected tab with a
checkmark and includes tab names, locks, and queued counts. A blinking brain
beside the tab name replaces the "Working" suffix in both the dropdown and
its tab list, disappearing when work stops. With Reduce Motion enabled the
brain stays still; VoiceOver continues to announce "Working".
Locked tabs remain selectable. The **Auto** delivery dropdown sits beside the
tab dropdown; choose a manual mode there for a one-message override.
Use **+** to create another session.

Touch and hold anywhere on the tab dropdown to **Rename Tab**, **Lock Tab** /
**Unlock Tab**, or **Close Session** (delete the tab). A regular tap opens only
the tab list. The shared chat's **...** menu also keeps these actions.
Names and locks
are saved on the host Mac and sync with local
Cantrip, other Macs' Remote views, and browser clients. A lock icon marks
protected tabs; unlock before closing a session or using New Conversation.
Sending, stopping/resuming work, and queue removal remain available.
These controls require the host's `supportsTabMetadata` capability; update
and reopen Cantrip first.

For the Hermes **Copilot** and **Private Local** conversations, use the
top-left menu's **Rename Tab** and **Lock Tab** actions. Each lane keeps its
own name and lock across app restarts and lane switches; a lock blocks the
destructive New Conversation action. Names are up to 80 characters, and
leaving a name blank restores its automatic label. Locks are accidental-close
protection, not encryption or a password.

When prompts are waiting, a **Queued messages** card above the composer shows
the count and next prompt. Tap it to read the full queue in execution order;
it refreshes with the session and clears as prompts start. This includes
prompts queued on the Mac or another device. Queue contents require the
matching Cantrip host update and relaunch; older hosts show the count and an
explicit update notice instead.

Use a queued prompt's **trash button**, or swipe left and tap **Remove**, to
remove it from the Mac's queue without stopping the current task. Removal
requires an updated, relaunched Cantrip host. Controls are disabled while
disconnected or a request is pending; the queue changes only after the Mac
confirms removal. If the prompt has already started, it is not cancelled.

Tap the conversation or session controls to dismiss the keyboard, or drag the
conversation to dismiss it interactively. Chat stays at the latest message
while following a reply, but scrolling up lets you read earlier messages
without being pulled back down. Tap **Latest** to resume following.

Long prompts use compact plain-text previews in all chat lanes and the Cantrip
queue. Tap **Read full prompt** to read bounded pages or **Copy all** for the
original text. This limits layout work, not the text sent to the agent.
Replies continue streaming normally; prompts remain one complete message.
For host-side responsiveness improvements, also update and reopen Cantrip on
the Mac (memory preparation and transcript encoding now run off the UI thread).

Open the shared **Settings** screen and enter Cantrip's pairing token. Without
a saved URL, AgentGateway discovers Cantrip on the same local network with Bonjour and connects
directly using forward-secret TLS with the pairing token as a pre-shared key.
Save Cantrip's Tailscale Serve HTTPS URL to prefer Tailscale both at home and
away. The URL is stored in app preferences and the token is stored in Keychain.
Automatic routing tries Tailscale first and never probes or switches to LAN
while Tailscale works. If Tailscale fails, reads can fall back to LAN; independent
read-only probes restore Tailscale after two consecutive authenticated successes,
at least three seconds apart, without blocking LAN refreshes. Tailscale reads
have a three-second total deadline; failed Tailscale routes back off for 15 seconds.
LAN connection attempts and reads have a two-second deadline; failed LAN routes
back off for 30 seconds. Discovery changes do not clear the backoff. When all
routes are cooling down, reads retry one route instead of locking out recovery.
Late failures cannot displace a newer successful route. Longer mutation and
image-upload deadlines are unchanged.

Enable **Tailscale only (skip local network)** in Remote settings to bypass
LAN discovery; this requires a saved Tailscale URL and Tailscale connectivity
when using a tailnet address. Automatic mode remains the default, and LAN-only
use still works without a saved URL. Sends and other mutations are never
automatically replayed after a connection failure: check the session before
sending again, since the host may already have accepted the request.

A green dot beside the session picker means the app has recently
completed an authenticated request; gray means the connection is unconfigured,
unavailable, unauthenticated, paused in the background, or stale. Each successful
list/detail request renews connectivity; the ten-second stale window allows a
bounded failover plus the polling interval without flickering disconnected.

**Auto** is the default for Cantrip typed and voice messages. A bounded,
tool-free inference on the Mac distinguishes useful context, changes of
direction, and follow-up tasks. Clear changes can redirect; context injects
when supported; uncertainty, unsupported routing backends, and inference
failures stay queued. The host reports the delivery decision below the session
controls. The small delivery menu retains one-message Queue/Redirect/Inject
overrides, then resets to Auto.

Update and reopen the Mac host before using Auto. AgentGateway checks
`supportsAutoDelivery` before sending; older hosts show an update notice
without sending or discarding the draft. Manual modes remain compatible.
The router uses Copilot Mini, Claude Haiku, or the configured local model;
the local lane never falls back to a cloud provider. This changes Cantrip
Remote only, not the Hermes gateway's own execution lanes.

In a Cantrip session, tap **Attach images** to choose photos/screenshots from
Photos, select image files, or paste a copied image. Preview and remove images
before sending, with or without a typed message. Up to four images can be sent
at once; each is oriented, resized to at most 2048 pixels per side, and
JPEG-compressed to at most 1 MB without the original photo's location metadata.
Image drafts are scoped to their session and are kept in memory if sending
fails. They are not automatically retried: after a lost connection, check the
session before resending to avoid duplicates.

Attachments require the updated **macOS Cantrip host** with a Claude, Copilot,
or Codex backend; older hosts and unsupported backends are blocked explicitly.
The Mac stores the uploaded files under
`~/.cache/Cantrip/remote-attachments/` so queued and recovered runs can open
them, using the same image-file tools as local Cantrip attachments. This does
not capture or consume any context staged by the person at the Mac. Image
attachments currently apply to **Cantrip Remote**, not the Hermes gateway's
Copilot/Private Local lanes or shell/slash commands.

---

## Prerequisites

- A running **Hermes agent** (`~/.hermes`) on a machine you control (Mac, Linux box, etc.).
- **Xcode 16+** on a Mac to build the app, and an **Apple ID** to run it on your device (a free account works for personal use).
- An HTTPS path to the gateway, using a private network such as Tailscale/WireGuard
  or an authenticated HTTPS tunnel.

---

## Part 1 — Set up the gateway (server)

### 1. Generate an API key

```sh
openssl rand -hex 32          # copy the output — this is your API_SERVER_KEY
```

### 2. Enable the API server

The api_server turns on automatically once a key is set. Add these to **`~/.hermes/.env`** (the key gate is `gateway/config.py` — `API_SERVER_KEY` set *or* `API_SERVER_ENABLED=true`):

```sh
API_SERVER_KEY=<paste the key from step 1>
API_SERVER_HOST=0.0.0.0      # 0.0.0.0 so your phone can reach it; 127.0.0.1 = localhost-only
API_SERVER_PORT=8642
```

> 🔒 The adapter **refuses to bind to a non-localhost address without a key** — so `0.0.0.0` is safe: every `/v1/*` request requires the Bearer key (constant-time checked). Only `/health` is open.

### 3. Configure the Copilot execution lane

The app requests named model routes so a future private-local conversation can
never silently fall back to Copilot. Keep Copilot as the default for now:

```yaml
# ~/.hermes/config.yaml
model:
  default: copilot-shim
  provider: ollama

gateway:
  api_server:
    extra:
      model_routes:
        copilot-coding:
          model: copilot-shim
          provider: ollama
          base_url: http://127.0.0.1:11437/v1
```

The **Private Local** lane remains disabled in the app until the gateway
advertises a separate `local-private` route.

### 4. Restart the gateway

However you run Hermes — e.g. if it's a launchd service:

```sh
launchctl kickstart -k "gui/$(id -u)/ai.hermes.gateway"
```

…or just `hermes gateway run --replace`. Channels (Telegram/Discord/etc.) reconnect in a few seconds.

### 5. Verify locally

```sh
KEY=<your key>
curl -s http://127.0.0.1:8642/health
curl -s -X POST http://127.0.0.1:8642/v1/runs \
  -H "Authorization: Bearer $KEY" \
  -H "Idempotency-Key: setup-check-1" \
  -H "Content-Type: application/json" \
  -d '{"model":"copilot-coding","input":"say hi"}'
```

You should get `{"status":"ok",…}` and then a JSON reply. A request **without** the key must return **401**.

### 6. Expose only the gateway over HTTPS

Prefer a private Tailscale/WireGuard network. An authenticated Cloudflare
Tunnel or another HTTPS reverse proxy also works:

```sh
cloudflared tunnel route dns <tunnel-name> agent.yourdomain.com
# map agent.yourdomain.com → http://localhost:8642 in your tunnel config, then run the tunnel
```

The bearer key still gates every request. If the endpoint is publicly
addressable, put an identity-aware access layer in front of it as defense in
depth. Never expose the local-model or Copilot-shim ports directly.

### 7. (Optional) Enable `/` suggestions + the Skills browser

The app's command autocomplete and **Skills** list need a small extra endpoint. Add `GET /v1/commands` to `gateway/platforms/api_server.py` — register the route alongside the others and add this handler:

```python
async def _handle_commands(self, request):
    auth_err = self._check_auth(request)
    if auth_err:
        return auth_err
    from hermes_cli.commands import telegram_menu_commands, telegram_bot_commands
    menu, hidden = telegram_menu_commands(max_commands=200)
    core = {n.lstrip("/").lower() for n, _ in telegram_bot_commands()}
    cmds = [{
        "command": "/" + n.lstrip("/"),
        "description": d,
        "kind": "command" if n.lstrip("/").lower() in core else "skill",
    } for n, d in menu]
    return web.json_response({"object": "hermes.api_server.commands",
                              "commands": cmds, "hidden_count": hidden})
```

```python
# in the route-registration block:
self._app.router.add_get("/v1/commands", self._handle_commands)
```

Restart the gateway. (Without this, chat + voice still work — you just won't see the suggestions/skills list.)

---

## Part 2 — Build & run the app

```sh
brew install xcodegen          # one-time
git clone <this repo> && cd Hermes
xcodegen generate              # creates Hermes.xcodeproj from project.yml
open Hermes.xcodeproj
```

In Xcode: select the **Hermes** target → **Signing & Capabilities** → set your **Team** and a unique **Bundle Identifier** (e.g. `com.yourname.hermes`) → pick your iPhone → **Run** (⌘R). Trust the developer profile on the phone if prompted (Settings → General → VPN & Device Management).

### Configure

On first launch, open **Settings (⚙️)** and enter:

| Field | Value |
|---|---|
| **Gateway URL** | Your private or tunneled `https://` gateway URL |
| **API key** | the `API_SERVER_KEY` from Part 1 |

Tap **Test authenticated connection**. The app verifies the key against
`/v1/models` and confirms that `copilot-coding` is advertised. A public
`/health` response alone is not considered a successful test.

## Execution lanes

- **Copilot** is the default and uses the `copilot-coding` gateway route.
- **Private Local** uses the future `local-private` route and is unavailable
  until the gateway advertises it.
- **Cantrip Remote** controls a selected live Cantrip session using the same
  chat and voice UI.
- Each destination has independent conversation history. Hermes lanes also use
  distinct long-term-memory session keys.
- Every assistant reply is labeled with its active destination.
- Switching lanes never carries the other lane's run or conversation history.

## Durable tasks

Every message creates a server-owned `/v1/runs` task. AgentGateway persists the
run ID before observing its event stream. Closing, suspending, or force-quitting
the app only disconnects the viewer; it does not call the gateway's stop
endpoint. When iOS leaves the foreground, the app drops its potentially stale
event connection while the task keeps running on the Mac.

When the app becomes active again it starts a fresh poll for the saved run ID
and replaces any partial text with the gateway's authoritative final output. If
iOS loses the initial `202` response, the app safely retries with the same
`Idempotency-Key`, and the gateway returns the original run instead of executing
the request twice. Results remain recoverable for 24 hours. Only tapping
**Stop** or using voice barge-in explicitly interrupts a run.

Voice Mode preserves its hands-free reply intent across that suspension. Return
to the app and the recovered response is still spoken before listening resumes;
only closing Voice Mode tears down its microphone and TTS state.

Tool approvals are also recoverable: a run waiting for approval stores the
redacted command and available choices in its pollable status.

## Local speech recognition

**Parakeet EOU 120M** is the default speech-input engine. It downloads its
Core ML assets from FluidAudio's Hugging Face repository on first use, then
transcribes microphone audio entirely on the device. Settings shows download
and compilation progress.

Choose **Apple Speech** in Settings for the no-download fallback. The fallback
sets `requiresOnDeviceRecognition`, so microphone audio is never intentionally
sent to Apple's servers. Parakeet and Qwen release their loaded models before
the other engine starts, limiting peak memory on iPhone.

> Get the key back any time: `grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-` (or copy it to your clipboard with `… | pbcopy` on macOS and paste via Universal Clipboard).

---

## Voice quality

The default iOS voices sound robotic. For near-Siri quality, download a **Premium** voice once: **iOS Settings → Accessibility → Spoken Content → Voices → English → (pick one)**. The app auto-uses the best installed voice, or choose it in **Settings → Reply voice**. *(Apple reserves the actual Siri voice from third-party apps; Premium is the closest usable option.)*

## Action Button / Shortcuts / Siri

Once installed, **"Talk to Hermes"** appears in the Shortcuts app and is assignable to the **Action Button** (Settings → Action Button → Shortcut). It also responds to *"Hey Siri, Talk to Hermes."* One trigger opens voice mode and starts listening.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Test connection fails / 401** | Wrong key or URL. Re-copy `API_SERVER_KEY`; confirm the URL has no trailing slash. |
| **Task never updates** | Reopen the app and confirm `GET /v1/runs/{id}` is reachable. The run continues on the Mac even when its SSE viewer disconnects. |
| **Skills list empty** | You haven't added the `/v1/commands` endpoint (Part 1, step 7), or the gateway is unreachable. |
| **Can't reach it on the phone** | Confirm the HTTPS proxy/private-network endpoint reaches the gateway and that `/v1/models` accepts the API key. |
| **Copilot route missing** | Add `gateway.api_server.extra.model_routes.copilot-coding` to `~/.hermes/config.yaml`, then restart the gateway. |
| **Parakeet cannot start** | Open Settings → Speech Recognition and retry model preparation, or select the fully on-device Apple Speech fallback. |

---

## "Set it up for me" — prompt for your LLM / agent

Paste this into Claude Code, your Hermes agent, or any tool-using LLM **running on the machine where Hermes lives**:

```
You are setting up the "AgentGateway" iOS app's backend on this machine, which
runs a Hermes agent at ~/.hermes. Do the following and report each result:

1. Generate a strong API key: `openssl rand -hex 32`. Save it; I'll need it for
   the app. Do NOT print it more than once.
2. Back up ~/.hermes/.env, then append (only if these keys aren't already set):
       API_SERVER_KEY=<the key>
       API_SERVER_HOST=0.0.0.0
       API_SERVER_PORT=8642
3. Back up ~/.hermes/config.yaml, keep the global default on copilot-shim, and
   add gateway.api_server.extra.model_routes.copilot-coding pointing to
   model copilot-shim at http://127.0.0.1:11437/v1.
4. Restart the Hermes gateway so the api_server picks up the new config (use the
   launchd service `ai.hermes.gateway` if present, else `hermes gateway run --replace`).
   Wait until port 8642 is LISTENING.
5. Verify: `curl -s http://127.0.0.1:8642/health` returns ok, an authenticated
   POST to /v1/runs returns a run_id, replaying the same Idempotency-Key returns
   that same run_id, and a request WITHOUT the key returns HTTP 401. Confirm
   `/v1/models` advertises `copilot-coding` and all Hermes channels reconnected.
6. (Optional, for the app's "/" suggestions + Skills list) Add a `GET /v1/commands`
   route + handler to gateway/platforms/api_server.py that returns
   telegram_menu_commands() as {command, description, kind} (kind="command" for
   names in telegram_bot_commands(), else "skill"). py_compile it, restart, verify.
7. Expose only the gateway through a private network or authenticated HTTPS
   reverse proxy. Do not expose the model server or Copilot shim.

Then tell me the HTTPS gateway URL to enter in the app, and remind me the API
key is in ~/.hermes/.env as API_SERVER_KEY.
Treat the key like a password — it grants full agent (tool/shell) access.
```

---

## Security

- Every `/v1/*` endpoint requires the Bearer key (constant-time compared); only `/health` is open.
- The key grants **full agent access** (it can run tools/shell) — treat it like a password. It lives in `~/.hermes/.env` on the server and the iOS **Keychain** on the phone, never in this repo.
- Non-loopback plain HTTP is rejected by the app because it exposes both prompts
  and the bearer key. Loopback HTTP remains available for simulator development.
- Named execution routes prevent a missing private model from silently falling
  back to the Copilot default.
- Durable run creation requires authentication and an app-generated
  `Idempotency-Key`; replay never starts a second side-effecting task.
