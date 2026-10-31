# Cantrip Gateway for Windows

Cantrip Home on a Windows PC, built to match [Cantrip Gateway Mac](../README.md) in design
and features: Pip, Home chat, every project tab, Tasks, Artifacts, Background runs and voice,
all from [Cantrip](https://github.com/FlyingViet/cantrip) running on your Mac. It's a client,
so everything you send runs on the Mac, the same as the iPhone and Mac apps.

## What's in it

- **The Mac app's window.** A floating sidebar with Pip (same moods and outfits), Chat,
  Tasks and Artifacts with their badges, and every project tab (status, age, drag to
  reorder, right-click actions), grouped under collapsible sections when the Mac has any
  (Move to Section, drop on a header, section menus; drag a header onto another, or focus it
  and press Alt+↑/↓, to reorder sections; **New Section** at the end makes an empty one; deleting
  a section with tabs asks first and keeps its tabs). Child tabs sit indented under their
  parent with a branch mark. A unified toolbar with Background, delivery (Auto, Queue,
  Redirect, Inject), Refresh and More.
- **Chat.** Replies with Markdown and the Mac's image previews, reasoning steps, MCP App
  views, a live agent browser card (click for a larger view; Escape closes it), subagent cards (running ones pinned above the composer), handoff cards with
  **Open tab**, child tab cards (the request, replies and files; merge state; the merge
  question on a conflict) and a child's banner with **Open parent**, thread tags in Home, drawn
  like inline replies in Messages (a reply from a different thread than the message above
  quotes its prompt, joined to it by a curved line that runs on past the replies right after it
  in that thread; a prompt whose replies got split up says
  "N Replies"; either opens the whole thread over the blurred window, even before older
  messages load), questions answered in the reply panel, approvals and sign-ins inline,
  prompt token usage, older history loading as you scroll up, and Start Fresh.
- **Slash commands.** Type `/` in a tab's or Home's composer to see the tab backend's
  commands, custom commands and skills, as the Mac lists them (needs a Cantrip version that
  offers them; older ones keep the composer as it was).
- **Mention a tab.** Type `@` at the start of a word in Home's or a tab's composer to pick
  one of the Mac's open tabs (filtered as you type; ↑/↓, Return or Tab picks, Esc closes).
  The pick shows as "@Tab name" with a chip, and the message carries that tab's ID so Cantrip
  reads, asks or hands work to exactly that tab. Mentions in the conversation show as
  "@Tab name" and open the tab when clicked. Private tabs are never offered (needs a Cantrip
  version that supports mentions; older ones show no list).
- **Attachments.** Up to 4 images, a video and up to 5 files per message (pasted into the
  message box, dropped or picked), uploaded resumably the way the Mac app sends them. Copied
  text still pastes as text, even when Excel or Word put a picture of it on the clipboard too.
- **Terminal.** The toolbar's terminal button (or Ctrl+`) opens the tab's shell on the Mac
  under its conversation: the same persistent shell as the Cantrip panel's terminal mode, so
  `cd`, exports and history carry across devices, and the agent's own commands show up too.
  Up/Down browse history, Ctrl+C interrupts (or copies when text is selected), and the pane has
  Clear, Restart Shell and Close; drag its top edge to resize. Line-based, so full-screen
  programs such as `vim` don't work. Not in Private Local (needs a Cantrip version that offers
  the terminal).
- **Tasks and Artifacts.** Scheduled tasks with runs, workspaces and their records;
  artifacts with thumbnails, the image viewer, Save and Delete.
- **Sheets.** Background runs (answer a waiting run in place), a tab's background tasks and
  queue (each message's suggested plan, **Run in child tab**, Send now, Remove), Model Settings (with the Mac-wide usage limit fallback; and Private Local), Rename, Usage Limits (Claude Code and Copilot), Cantrip Memory (formatted
  Markdown or its source), GitHub Builds, Update & Rebuild Cantrip, and Mac Permissions & View Mac.
- **Voice.** Dictation from the composer's microphone and Voice Mode (hold the microphone),
  with speech recognition running on this PC after a one-time model download, and replies
  read aloud with a Windows voice.
- **Encrypted direct connection.** The app talks to the Mac's TLS-PSK listener (the same
  pairing token) on your home network or over Tailscale, with no certificates and no open
  port on the PC, and falls back to the Mac's Tailscale HTTPS address.
- **Several Macs.** Settings keeps a list of Macs, like the Mac app; pick one to connect.
- **Token kept out of reach.** Pairing tokens are encrypted with Windows' DPAPI for your
  account. The window's page never sees them; the app adds them to each request itself.

Requires Windows 10 or 11 (x64) and Cantrip v1.0-161 or later on the Mac with **Remote
control** on.

## Install

1. Download **CantripGateway-Setup-<version>-x64.exe** from the
   [latest release](https://github.com/FlyingViet/CantripGatewayMac/releases/latest)
   (a preview build), or a newer build from the latest
   [Windows app workflow run](https://github.com/FlyingViet/CantripGatewayMac/actions/workflows/windows.yml)
   (Artifacts section).
2. Run it. The installer isn't code-signed yet, so Windows SmartScreen may say
   "Windows protected your PC": choose **More info**, then **Run anyway**.
3. Open **Cantrip Gateway** from the Start menu and pair it (below).

## Pair with your Mac

On the Mac, in Terminal:

```sh
cantrip pair --direct
```

It prints a `cantripagent://pair?...` link with the Mac's local address and current
encrypted port, its Tailscale HTTPS address and the token. In **Settings > Connection**,
paste it under **Pair with a Link** and choose **Use Link**, then **Add Server**. Or fill in
**Add Cantrip Remote** yourself:

| Field | What to enter |
| --- | --- |
| Pairing token | From Cantrip's **Settings > Remote control** on the Mac. |
| Direct address | The Mac's address and the encrypted port shown in Cantrip's **Settings > Remote control** (or `cantrip status`), e.g. `192.168.0.20:50310`. On Tailscale, the Mac's Tailscale IP works too. While that port is on Auto it changes whenever Cantrip restarts; set a fixed port there to keep this address working. |
| Tailscale URL | Optional. The Mac's Tailscale Serve address, used when the direct address can't be reached. |

**Test Connection** checks each route without saving. **Add Server** saves only if at least
one route reaches the Mac with that token; the first Mac you add connects right away.
Click a saved Mac to switch to it; right-click (or the trash button) removes it. Open
Settings any time with **Ctrl+,** or **More > Connection Settings…**.

The sidebar's footer shows the Mac's address on the route in use.

## Keyboard

| Keys | Does |
| --- | --- |
| Ctrl+1 / 2 / 3 | Chat, Tasks, Artifacts |
| Ctrl+B | Background |
| Ctrl+T | New tab |
| Ctrl+N | New message (Home chat) |
| Ctrl+R or F5 | Refresh |
| Ctrl+; | Model Settings |
| Ctrl+Shift+V | Voice Mode |
| Ctrl+Shift+P | Pause or resume the agent |
| Ctrl+` | Show or hide the terminal |
| Up / Down, Ctrl+C | In the terminal: browse history, interrupt the running command |
| Ctrl+, | Settings |
| Enter / Shift+Enter | Send / new line |
| Up / Down, Tab, Enter, Esc | In the `/` command list: move, insert, choose (or send as typed when nothing is highlighted), dismiss |
| Alt+Up / Alt+Down | Move the focused tab in the sidebar |

## Troubleshooting

- **"refused the secure connection"**: the token doesn't match, or Cantrip on the Mac is
  older than v1.0-161. Copy the token again or update Cantrip.
- **"Couldn't reach … (ECONNREFUSED / timed out)"**: Cantrip isn't running, Remote control
  is off, the encrypted port changed (Auto), or the PC isn't on the Mac's network or
  tailnet.
- **More > Show Log File** opens `%APPDATA%\Cantrip Gateway\logs\gateway.log`. It records
  routes and connection errors only, never tokens or messages.

## Build from source

Requires Node.js 22 or later.

```sh
cd windows
npm ci
npm test           # pairing, routing, TLS-PSK, store and interface logic tests
npm start          # build and run (works on macOS too, for development)
npm run dist:win   # Windows x64 installer in release/ (run on Windows)
```

GitHub Actions builds the installer on Windows for every change under `windows/`
([workflow](../.github/workflows/windows.yml)). It also runs `scripts/psk-smoke.cjs`, which
checks that Electron's TLS library completes a real TLS-PSK request.

| Path | What |
| --- | --- |
| `src/main/main.ts` | Windows, the private `cantrip-host://mac/` scheme (serves the bundled interface and carries API calls to the Mac, adding the token), Settings IPC |
| `src/main/transport.ts` | HTTP over TLS-PSK (`ECDHE-PSK-CHACHA20-POLY1305`, identity `cantrip-remote-v1`, key SHA-256 of the token) and over HTTPS |
| `src/main/router.ts` | Route order and fallback; a send that may have reached the Mac is never repeated |
| `src/main/pairing.ts`, `store.ts` | Pairing link and address validation; saved Macs with DPAPI-encrypted tokens |
| `src/preload/` | The main window's and Settings window's bridges to the app |
| `src/gateway/` | The interface (Preact + TypeScript, bundled by `scripts/build-gateway.mjs`): `api/` (client and API types), `state/` (polling like the Mac's `CantripRemoteModel`, navigation), `ui/` (sidebar, toolbar, chat, Pip, Tasks, Artifacts, sheets, voice), `settings.tsx` |

Not on Windows: push alerts, widgets and Live Activities (iPhone features), the Home
Builds tab (iPhone install links), Touch ID before approvals, and finding the Mac
automatically on the network (enter its address or use a pairing link).
