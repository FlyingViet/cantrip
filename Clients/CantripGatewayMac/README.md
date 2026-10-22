# Cantrip Gateway Mac

Cantrip Home as a native macOS app: the same Home as the Cantrip Agent iPhone app
(Chat, Tasks, Artifacts, Background and every project tab), sized for a Mac window.

## Install

1. Download **CantripGatewayMac-*.dmg** from the
   [latest release](https://github.com/FlyingViet/CantripGatewayMac/releases/latest).
2. Open it and drag **Cantrip Gateway Mac** to **Applications**. Releases are signed with
   Developer ID and notarized by Apple, so the app opens normally.
3. Pair it with [Cantrip](https://github.com/FlyingViet/cantrip) (see
   [Connect to Cantrip](#connect-to-cantrip) below).

Requires macOS 26 or later. Cantrip Gateway Mac is a client: it needs Cantrip running on a
Mac you own, the same Mac or another one, with **Remote control** enabled in Cantrip's
Settings. Each person pairs with their own Cantrip; a pairing token gives full control of
that Mac's agents, so never share yours.

## How it shares the iOS app's logic

The iOS app lives in [FlyingViet/Hermes](https://github.com/FlyingViet/Hermes). This repo
includes it as the `Hermes` git submodule and compiles its `Sources/` and `Shared/`
directly, so pairing, LAN/Tailscale routing, history paging, sending, input requests,
tasks, artifacts, background runs, MCP Apps and voice all run the exact same code.
The Swift module is even named `Hermes`, so the shared logic test suites run here
unchanged.

Only Mac-specific code lives in this repo:

| Folder | What |
| --- | --- |
| `Sources/App` | App entry, window/menu commands, navigation state |
| `Sources/Home` | Home window: sidebar (Pip, sections, connection), chat, toolbar |
| `Sources/Settings` | Settings window: pairing and voice |
| `Sources/Platform` | AppKit stand-ins for the UIKit/ActivityKit names the shared code uses, and the macOS image viewer |
| `Tests` | Mac tests; `project.yml` also runs the shared Hermes logic suites |

The shared files need no Mac-specific knowledge beyond `#if os(iOS)` guards around
UIKit-only classes, which this repo replaces with AppKit versions of the same names.

## Build from source

Requires macOS 26, Xcode 26+ and XcodeGen (`brew install xcodegen`).

```sh
git clone --recurse-submodules https://github.com/FlyingViet/CantripGatewayMac.git
cd CantripGatewayMac
make install   # Release build copied to /Applications
make test      # Mac tests + shared Hermes logic suites
make build     # Debug build in build/Debug
```

`make install` signs with the maintainer's team by default. With your own Apple developer
team use `make install TEAM=<your team ID>`; without one, sign ad hoc with
`make install TEAM= SIGN_IDENTITY=-`.

Maintainers publish a release with `Scripts/release.sh <version>`: it archives with
Developer ID, notarizes and staples the app and a DMG, then creates the GitHub release.
See the script's header for the one-time `notarytool` setup.

Debug builds use the bundle ID `com.itzhoang.cantripgateway.mac.debug`, so test runs
never touch the installed app's saved servers.

## Connect to Cantrip

Cantrip Gateway Mac is a client for [Cantrip](https://github.com/FlyingViet/cantrip), the
agent harness. Cantrip runs the agents and owns every tab, queue and Home task on the Mac
that does the work; this app pairs with it and shows those live sessions. It can run on
that same Mac or on another one.

**On the Mac running Cantrip:**

1. Install Cantrip ([quick start](https://github.com/FlyingViet/cantrip#quick-start)) and
   set up one AI backend.
2. Press **Option+Space**, open the **gear** and check **Remote control daemon**, then
   **Cantrip Home** (this app opens on Home).
3. Click **Copy pairing token**. It gives full control of that Mac's agents, so keep it
   private; **Regenerate** disconnects every paired client.

**In Cantrip Gateway Mac:** open **Settings (⌘,) > Connection**. Under **Cantrip Remote
Servers**, paste the **Pairing token**, fill in a route, click **Add Server**, then select
the saved server.

| Route | Use it when | What to enter |
|---|---|---|
| Local network | Both Macs are on the same network, or it's the same Mac | Nothing more. The app finds Cantrip with Bonjour, exactly like the iPhone app. |
| Tailscale Serve | Home and away | **Tailscale URL**, e.g. `https://your-mac.your-tailnet.ts.net`, after running `tailscale serve --bg http://127.0.0.1:8765` on the Cantrip Mac. Used first whenever it works. |
| Direct address | The Cantrip Mac can't run Tailscale (e.g. a work laptop) | Set **Direct port** (e.g. `8766`) in that Mac's Cantrip settings, then enter **Direct address** as `IP:port`, e.g. `192.168.0.152:8766`. Works wherever this Mac can route to that IP, such as through a home router's Tailscale subnet route. |

Every route is end-to-end encrypted with the pairing token. The connection code, host API
and capability checks are shared with the iPhone app; see
[Host API](https://github.com/FlyingViet/Hermes#host-api) in the Hermes README and
Cantrip's [remote-control guide](https://github.com/FlyingViet/cantrip/blob/main/docs/remote-control.md).
If a control shows an update notice, update and relaunch Cantrip on the host Mac.

## Using it

- **Sidebar:** Pip shows Home's mood. Below Pip are Chat, Tasks and Artifacts, with
  badges for questions waiting and running tasks, then **Tabs · N**: every project tab on
  the Mac with a spinner while it works (or a question mark while it waits for you), an idle
  dot otherwise, and how long ago it last ran. **+** (⌘T) starts a tab; drag to reorder;
  right-click for Rename, Lock, Move, Model Settings, Start Fresh, View Mac and Close. The
  footer shows the connection.
- **Tabs:** selecting a tab shows its transcript and composer in place. The toolbar shows its
  name and **Working / Idle · folder**, with Stop, delivery (**Auto**) and **⋯** for the tab's
  actions, Resume, voice mode and **Back to Home**. ⌘1–⌘3 or any Home section returns.
  **Start Fresh** (also in the Home menu) keeps the tab and its messages but starts the next
  prompt in a new model session; a repeated error offers it, and **Change Model**, in place.
- **Chat:** Return sends; Option-Return adds a line. Drag images onto the chat to
  attach them. Questions from Cantrip appear above the composer.
- **Toolbar:** Background (⌘B, with the same running and needs-input badges as iOS),
  delivery mode, Refresh (⌘R) and More (model settings, Copilot usage, voice mode,
  pause, memory, builds, mascot, Cantrip maintenance).
- **Keyboard:** ⌘1–⌘3 switch sections, ⌘T opens a new tab and ⌘N focuses a new message.
  ⇧⌘V opens voice mode and ⇧⌘P pauses the agent.

When a tab Home handed work to finishes, fails, stops or needs an answer, a result card in
the chat shows its outcome; **Open tab** opens that tab right in the window. Not on the Mac:
the iPhone's Builds tab (its OTA install links only work on iPhone), push alerts, widgets and
Live Activities. Tab ages and outcomes need Cantrip host e8e5c0b or later.

## Updating the shared code

```sh
cd Hermes && git pull origin master && cd ..
make test
git commit -am "Bump Hermes" 
```

If a Hermes change adds UIKit-only code to a shared file, wrap it in `#if os(iOS)`.
If the Mac needs that piece, add an AppKit equivalent under `Sources/Platform`.
