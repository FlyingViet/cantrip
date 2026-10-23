# Cantrip Gateway for Windows

Cantrip Home on a Windows PC: Home chat, every project tab, Tasks and Artifacts from
[Cantrip](https://github.com/FlyingViet/cantrip) running on your Mac. It's a client, so
everything you send runs on the Mac, the same as the iPhone and Mac apps.

It shows the Mac's own web client (the one the browser and Mac Remote use) inside an
Electron window, so new Remote features on the Mac reach Windows without a new build.
The app adds what a browser can't do:

- **Encrypted direct connection.** It talks to the Mac's TLS-PSK listener (the same
  pairing token) on your home network or over Tailscale, with no
  certificates and no open port on the PC. Browsers can't use pre-shared-key TLS.
- **Fallback to HTTPS.** With the Mac's Tailscale HTTPS address saved, it switches over
  when the direct address can't be reached and moves back once it can.
- **Token kept out of reach.** The pairing token is encrypted with Windows' DPAPI for
  your account and handed only to the Mac's page.
- **Pairing links.** `cantripagent://pair?...` links from `cantrip pair` open the app's
  Connection settings with everything filled in.

Requires Windows 10 or 11 (x64) and Cantrip v1.0-161 or later on the Mac with **Remote
control** on. Earlier Cantrip builds refuse the Windows app's encryption suite.

## Install

1. Download **CantripGateway-Setup-<version>-x64.exe** from the latest
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
encrypted port, its Tailscale HTTPS address and the token. Paste the link into **Pairing link** and choose **Use link**,
then **Save and connect**. Or fill in the fields yourself:

| Field | What to enter |
| --- | --- |
| Direct address | The Mac's address and the encrypted port shown in Cantrip's **Settings > Remote control** (or `cantrip status`), e.g. `192.168.0.20:50310`. On Tailscale, the Mac's Tailscale IP works too. While that port is on Auto it changes whenever Cantrip restarts; set a fixed port there to keep this address working. |
| HTTPS URL | Optional. The Mac's Tailscale Serve address, used when the direct address can't be reached. |
| Pairing token | From Cantrip's **Settings > Remote control** on the Mac. |

**Test connection** checks each route without saving. **Save and connect** saves only if
at least one route reaches the Mac with that token. Reopen these settings with
**File > Connection Settings** (Ctrl+,). **Forget this Mac** removes the saved token
from the PC.

The window title shows the route in use, for example
`Cantrip Gateway · Mac mini · Direct, encrypted (192.168.0.20:8766)`.

## Troubleshooting

- **"refused the secure connection"**: the token doesn't match, or Cantrip on the Mac is
  older than v1.0-161. Copy the token again or update Cantrip.
- **"Couldn't reach … (ECONNREFUSED / timed out)"**: Cantrip isn't running, Remote control
  is off, or the PC isn't on the Mac's network or tailnet.
- **Help > Show Log File** opens `%APPDATA%\Cantrip Gateway\logs\gateway.log`. It
  records routes and connection errors only, never tokens or messages.

## Build from source

Requires Node.js 22 or later.

```sh
cd windows
npm ci
npm test           # pairing, routing and TLS-PSK transport tests
npm start          # build and run (works on macOS too, for development)
npm run dist:win   # Windows x64 installer in release/ (run on Windows)
```

GitHub Actions builds the installer on Windows for every change under `windows/`
([workflow](../.github/workflows/windows.yml)). It also runs `scripts/psk-smoke.cjs`, which
checks that Electron's TLS library completes a real TLS-PSK request.

| Path | What |
| --- | --- |
| `src/main/main.ts` | Windows, menu, the private `cantrip-host://` scheme that carries the web client to the Mac, Connection settings IPC |
| `src/main/transport.ts` | HTTP over TLS-PSK (`ECDHE-PSK-CHACHA20-POLY1305`, identity `cantrip-remote-v1`, key SHA-256 of the token) and over HTTPS |
| `src/main/router.ts` | Route order and fallback; a send that may have reached the Mac is never repeated |
| `src/main/pairing.ts`, `store.ts` | Pairing link and address validation; DPAPI-encrypted settings |
| `src/preload/` | Gives the Mac's page its token; gives the settings page its controls |
| `src/renderer/` | Connection settings page |

Not in this version: Pip, voice, the on-device Hermes model, Windows notifications for
finished runs, and finding the Mac automatically on the network (enter its address or use
a pairing link).
