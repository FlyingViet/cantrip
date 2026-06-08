# Hermes — iOS client (AgentGateway)

A native SwiftUI app for talking to your own [**Hermes Agent**](https://github.com/) — by **voice** and **chat** — instead of being stuck in Telegram or Discord.

- 💬 **Streaming chat** with inline tool/skill activity (Claude-Code style)
- 🎙️ **Voice mode** — full-screen, hands-free *listen → think → speak* loop, on-device speech (nothing leaves your phone)
- ⚡ **`/` autocomplete** + a **Skills browser** (tap a skill to run it)
- 🔘 **Action Button / Shortcuts / Siri** — "Talk to Hermes" jumps straight into voice mode
- 💾 **Persistent history** — reopen to your prior conversation
- 🔑 **Your gateway, your key** — points at *your* Hermes server, nothing hardcoded

> The app is a thin, secure client. All the intelligence (skills, memory, tools) lives in **your** Hermes gateway. You bring the gateway + an API key; the app does the rest.

---

## How it works

```
  iPhone (AgentGateway)  ──HTTPS, Bearer key──►  Cloudflare tunnel / LAN
                                                        │
                                                        ▼
                                       Hermes gateway api_server  (:8642)
                                         POST /v1/responses  (SSE stream)
                                         GET  /v1/commands    (optional)
                                                        │
                                                        ▼
                                            Your Hermes agent
                                       (skills · memory · tools · model)
```

The app speaks the gateway's **OpenAI-compatible API server** (`gateway/platforms/api_server.py`), which is the *full agent* — not the raw inference shim.

---

## Prerequisites

- A running **Hermes agent** (`~/.hermes`) on a machine you control (Mac, Linux box, etc.).
- **Xcode 16+** on a Mac to build the app, and an **Apple ID** to run it on your device (a free account works for personal use).
- *(Optional)* a domain + **Cloudflare Tunnel** (or any HTTPS reverse proxy) if you want to use it away from home.

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

### 3. Restart the gateway

However you run Hermes — e.g. if it's a launchd service:

```sh
launchctl kickstart -k "gui/$(id -u)/ai.hermes.gateway"
```

…or just `hermes gateway run --replace`. Channels (Telegram/Discord/etc.) reconnect in a few seconds.

### 4. Verify

```sh
KEY=<your key>
curl -s http://<gateway-host>:8642/health
curl -s -X POST http://<gateway-host>:8642/v1/responses \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"hermes-agent","input":"say hi","stream":false}'
```

You should get `{"status":"ok",…}` and then a JSON reply. A request **without** the key must return **401**.

### 5. (Optional) Use it anywhere — Cloudflare Tunnel

For access off your LAN, expose `localhost:8642` over HTTPS, e.g. with `cloudflared`:

```sh
cloudflared tunnel route dns <tunnel-name> agent.yourdomain.com
# map agent.yourdomain.com → http://localhost:8642 in your tunnel config, then run the tunnel
```

The Bearer key still gates every request end-to-end. For belt-and-suspenders, put **Cloudflare Access** in front of the hostname too.

### 6. (Optional) Enable `/` suggestions + the Skills browser

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
| **Gateway URL** | `https://agent.yourdomain.com` (tunnel) or `http://<lan-ip>:8642` (home) |
| **API key** | the `API_SERVER_KEY` from Part 1 |

Tap **Test connection** → it should go green. Then talk or type.

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
| **Reply comes back empty** | Make sure the gateway returns `/v1/responses` SSE (try the curl in step 4). |
| **Skills list empty** | You haven't added the `/v1/commands` endpoint (Part 1, step 6), or the gateway is unreachable. |
| **Can't reach it on the phone** | `API_SERVER_HOST` must be `0.0.0.0` (not `127.0.0.1`), and the phone must reach the host (same LAN, or via the tunnel). |

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
3. Restart the Hermes gateway so the api_server picks up the new config (use the
   launchd service `ai.hermes.gateway` if present, else `hermes gateway run --replace`).
   Wait until port 8642 is LISTENING.
4. Verify: `curl -s http://127.0.0.1:8642/health` returns ok, a POST to
   /v1/responses WITH the Bearer key streams a reply, and the SAME request
   WITHOUT the key returns HTTP 401. Confirm all your Hermes channels reconnected.
5. (Optional, for the app's "/" suggestions + Skills list) Add a `GET /v1/commands`
   route + handler to gateway/platforms/api_server.py that returns
   telegram_menu_commands() as {command, description, kind} (kind="command" for
   names in telegram_bot_commands(), else "skill"). py_compile it, restart, verify.
6. (Optional) If I want to use the app away from home, set up a Cloudflare tunnel
   (or reverse proxy) from a hostname to http://127.0.0.1:8642 over HTTPS.

Then tell me: the gateway URL to enter in the app (LAN IP:8642 or the tunnel
hostname), and remind me the API key is in ~/.hermes/.env as API_SERVER_KEY.
Treat the key like a password — it grants full agent (tool/shell) access.
```

---

## Security

- Every `/v1/*` endpoint requires the Bearer key (constant-time compared); only `/health` is open.
- The key grants **full agent access** (it can run tools/shell) — treat it like a password. It lives in `~/.hermes/.env` on the server and the iOS **Keychain** on the phone, never in this repo.
- Over a tunnel the key is HTTPS-encrypted; on a plain-HTTP LAN it crosses your local network in the clear — fine for a trusted home network.
