# Cantrip Gateway Mac

Cantrip Home as a native macOS app: the same Home as the Cantrip Agent iPhone app
(Chat, Tasks, Artifacts, Background), sized for a Mac window, without Remote tabs.

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

## Build and install

Requires macOS 26, Xcode 26+ and XcodeGen.

```sh
git clone --recurse-submodules https://github.com/FlyingViet/CantripGatewayMac.git
cd CantripGatewayMac
make install   # Release build signed with Apple Development, copied to /Applications
make test      # Mac tests + shared Hermes logic suites
make build     # Debug build in build/Debug
```

Debug builds use the bundle ID `com.itzhoang.cantripgateway.mac.debug`, so test runs
never touch the installed app's saved servers.

## Pair with Cantrip

Open **Settings (⌘,) > Connection**, then add the pairing token from Cantrip's Remote
control settings. A Tailscale Serve URL is optional. Without it the app finds Cantrip
on the local network, exactly like the iPhone app.

## Using it

- **Sidebar:** Pip shows Home's mood. Below Pip are Chat, Tasks and Artifacts, with
  badges for questions waiting and running tasks. The footer shows the connection.
- **Chat:** Return sends; Option-Return adds a line. Drag images onto the chat to
  attach them. Questions from Cantrip appear above the composer.
- **Toolbar:** Background (⌘B, with the same running and needs-input badges as iOS),
  delivery mode, Refresh (⌘R) and More (model settings, Copilot usage, voice mode,
  pause, memory, builds, mascot, Cantrip maintenance).
- **Keyboard:** ⌘1–⌘3 switch sections and ⌘N focuses a new message. ⇧⌘V opens voice
  mode and ⇧⌘P pauses the agent.

Not on the Mac: Remote tabs, push alerts, widgets and Live Activities. Handoff cards
show which tab took over but don't open it.

## Updating the shared code

```sh
cd Hermes && git pull origin master && cd ..
make test
git commit -am "Bump Hermes" 
```

If a Hermes change adds UIKit-only code to a shared file, wrap it in `#if os(iOS)`.
If the Mac needs that piece, add an AppKit equivalent under `Sources/Platform`.
