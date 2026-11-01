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
that Mac's agents, so never share yours. The one exception is
[Local Model](#local-model-on-this-mac-direct-not-synced), which talks to a model server on
this Mac directly.

On a Windows PC, use [Cantrip Gateway for Windows](windows/) (Home chat, project tabs,
Tasks and Artifacts over the same encrypted connection).

## How it shares the iOS app's logic

The iOS app lives in [FlyingViet/CantripIOS](https://github.com/FlyingViet/CantripIOS). This repo
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
| `Sources/Settings` | Settings window: the shared pages (Hermes `Sources/Settings`) beside a sidebar, plus this Mac's local model tools |
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

Build output goes to `build/`. To keep it on another disk (a NAS, say), set
`CANTRIP_BUILD_ROOT` to a folder there: each checkout builds in its own folder below it, and
whenever that folder can't be written (the disk isn't mounted) the build falls back to `build/`.

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

**In Cantrip Gateway Mac:** open **Settings (⌘,) › Macs › Pair a Mac**, paste the **Pairing
token**, fill in a route (the direct address and Tailscale only are under **Advanced**) and
click **Pair**. The first Mac you pair becomes the active one; switch to another from its page
in **Macs**. Or run `cantrip pair` on the host and open the `cantripagent://pair` link
it prints on this Mac: Cantrip Gateway shows the host and its routes and saves nothing until
you click **Pair**.

| Route | Use it when | What to enter |
|---|---|---|
| Local network | Both Macs are on the same network, or it's the same Mac | Nothing more. The app finds Cantrip with Bonjour, exactly like the iPhone app. |
| Tailscale Serve | Home and away | **Tailscale URL**, e.g. `https://your-mac.your-tailnet.ts.net`, after running `tailscale serve --bg http://127.0.0.1:8765` on the Cantrip Mac. Used first whenever it works. |
| Direct address | The Cantrip Mac can't run Tailscale (e.g. a work laptop) | Set **Direct port** (e.g. `8766`) in that Mac's Cantrip settings, then enter **Direct address** as `IP:port`, e.g. `192.168.0.152:8766`. Works wherever this Mac can route to that IP, such as through a home router's Tailscale subnet route. |

Every route is end-to-end encrypted with the pairing token. The connection code, host API
and capability checks are shared with the iPhone app; see
[Host API](https://github.com/FlyingViet/CantripIOS#host-api) in the CantripIOS README and
Cantrip's [remote-control guide](https://github.com/FlyingViet/cantrip/blob/main/docs/remote-control.md).
If a control shows an update notice, update and relaunch Cantrip on the host Mac.

## Using it

- **Sidebar:** Pip shows Home's mood. Below Pip are Chat, Tasks and Artifacts, with
  badges for questions waiting and running tasks, then **Tabs · N**: every project tab on
  the Mac with a spinner while it works (or a question mark while it waits for you), an idle
  dot otherwise, and how long ago it last ran. **+** (⌘T) starts a tab; drag to reorder;
  right-click for Model Settings, Start Fresh, Tools for This Tab, Rename, Lock, Move to
  Section, Move Up/Down and Close. With sections (made on any device), tabs show under collapsible headers, each
  with its own **+** and a right-click menu (Rename, New Tab Here, Move Up/Down, Delete, Edit
  Sections); drop a tab on a header to file it there, or drag a header onto another to reorder
  sections. **New Section** (last row) makes an empty section; deleting one with tabs asks
  first and moves its tabs back to Tabs. **Edit Sections** renames, reorders (drag or
  arrows), deletes and adds them.
  Collapsed sections still show working tabs. Child tabs sit indented under their parent
  with a branch mark and stay there until their work merges. The footer
  shows the connection.
- **Tabs:** selecting a tab shows its transcript and composer in place. The toolbar shows its
  name and **Working / Idle · folder**, with Stop, delivery (**Auto**) and **⋯** for the tab's
  actions, Resume, voice mode and **Back to Home**. ⌘1–⌘3 or any Home section returns.
  **Start Fresh** (also in the Tab menu) keeps the tab and its messages but starts the next
  prompt in a new model session; a repeated error offers it, and **Change Model**, in place.
- **Chat:** Return sends; Option-Return adds a line. Drag images onto the chat to
  attach them, or press ⌘V in the message box with a copied screenshot, photo, video or
  Finder file (copied text still pastes as text). Questions from Cantrip appear above the composer.
- **Delete a message:** right-click a prompt or an error in Home's chat or a tab and choose
  **Delete Message** (beside **Copy**), then **Delete**. Cantrip removes it and the rest of its
  exchange (the prompt and its reply) from the tab's history, so the model doesn't have them
  anymore; it can't be undone. To delete a reply, delete its prompt: replies have no menu, so
  their text keeps the system's selection and right-click menu. Not while the tab works, and
  never on Start Fresh dividers, handoff results or child tab cards. Messages deleted on another
  device disappear here too. Needs a Cantrip host with `supportsDeleteMessage` (`POST …/delete-message`).
- **Save artifacts:** an artifact's **…** menu (or right-click) has **Save As…**, a Save panel
  opened in Downloads that writes the Mac's original file to disk as it arrives; artifacts in a
  folder also have **Save Folder as Zip…**. Files come only over the paired connection. Folder
  zips (and streaming) need a Cantrip host with `supportsDownloads` on its artifact list.
- **Slash commands:** type `/` in Home's or a tab's composer to list that tab's backend
  commands, custom commands and skills. Up/Down move the highlight (Return runs a command
  without arguments, or inserts one that takes an argument), Tab inserts, Escape hides the list
  for the current text; with nothing highlighted Return sends the text as typed. **/model** opens
  Model Settings. Needs a Cantrip host with `supportsBackendCommands`.
- **Mention a tab:** type `@` at the start of a word in Home's or a tab's composer to list the
  open tabs (filtered as you type; never private tabs, Home or the tab itself). Up/Down move the
  highlight, Return or Tab picks (Return doesn't send while the list shows), Escape hides it;
  a click picks too. The pick shows as `@Title` plus a removable chip, and goes to the Mac as
  that tab's ID, so Cantrip acts on exactly that tab. Sent mentions read **@Title** and open
  the tab when clicked. Needs a Cantrip host with `supportsTabMentions`. Shared with iOS (see
  Hermes' README, *Mention a tab with @*).
- **Terminal:** the toolbar's terminal button (or ⌃`) opens the tab's shell on the Mac under its
  conversation: the same persistent shell as the Cantrip panel's terminal mode, so `cd`, exports
  and history carry across devices, and the agent's own commands appear there too. Type a line
  and press Return (while a command runs, the line goes to its input); Up/Down browse history,
  ⌃C interrupts, and the pane has Clear, Restart Shell and Close. Drag its top edge to resize.
  The button turns orange while a command runs with the pane hidden. Line-based, so full-screen
  programs such as `vim` or `top` don't work. Not in Private Local. Needs a Cantrip host with
  `supportsTerminal`.
- **Toolbar:** Background (⌘B, with the same running and needs-input badges as iOS),
  delivery mode and one **More** menu everywhere: the open tab's actions (or
  Home's Model Settings and Start Fresh, or the local model's settings), then Back to Home and
  Settings. Voice Mode opens from the composer's microphone (double-click it) or ⇧⌘V.
- **Menus:** **File** has New Tab (⌘T) and New Message (⌘N). **View** has Chat, Tasks and
  Artifacts (⌘1–⌘3), Local Model on This Mac (⌘4), Background (⌘B), GitHub Builds (⇧⌘B),
  Toggle Terminal (⌃`). **Tab** has Model Settings… (⌘;), Start Fresh and Voice Mode (⇧⌘V).
  The app menu has Pause Agent (⇧⌘P) next to Settings…. **Window** and **Help** are the standard
  ones. The Dock icon's menu has New Message, New Tab, Background, Pause Agent and Settings….
- **No refresh button:** the window polls the Mac every 1.5 seconds while the tab you're
  viewing is working, has queued messages or the connection is down, every 5 seconds
  otherwise (15 behind other apps), and at once when it comes to the front.
- **Settings (⌘,):** the same pages as the iPhone app, beside a sidebar, in a window you can
  resize, under a status card with the **Pause Agent** switch (chat shows **Agent paused** with
  **Resume** while it's on): Macs, Models (model tiers, usage-limit backups, Usage Limits), Tools & sign-ins (GitHub sign-in for the Mac, the
  Mac's shared MCP servers, and this Mac's local model tools), Memory, Voice, Appearance (the
  mascot) and About & Updates (Update & rebuild Cantrip, Mac permissions). It reopens on the
  last page you used. Each page says who its settings change.
- **Location (off by default):** Settings › Location › Share location with messages sends this
  Mac's location with each message (When In Use only; rounded to about 1 km unless Precise
  location is on; one fix reused for up to 15 minutes), so weather and "near me" answers are for
  where this Mac is and name the place. It goes only to the paired Cantrip and isn't saved; while
  it's off, the host uses its own location and says so. Needs a Cantrip host with
  `supportsClientLocation`.

When a tab Home handed work to finishes, fails, stops or needs an answer, a result card in
the chat shows its outcome; **Open tab** opens that tab right in the window. Not on the Mac:
the iPhone's Builds tab (its OTA install links only work on iPhone), push alerts, widgets and
Live Activities. Tab ages and outcomes need Cantrip host e8e5c0b or later.

## Local model on this Mac (direct, not synced)

**On This Mac › Local Model** in the sidebar (⌘4) chats with a model served on the Mac
running Cantrip Gateway Mac, straight from the app. It works without a paired Cantrip, for
example on a laptop with [Ollama](https://ollama.com) or
[mlx-serve](https://github.com/ddalcu/mlx-serve) and no Cantrip host.

1. Start an Ollama-compatible server on this Mac (Ollama listens on `http://127.0.0.1:11434`).
2. Open **Local Model**, then **Set Up…** (or the sliders button in the toolbar).
3. Enter the server address, for example `http://127.0.0.1:11434`, or `http://127.0.0.1:11234`
   for `mlx-serve --serve --host 127.0.0.1`. Click **Load Models**, pick one, and **Save**.
4. Type in the composer. Return sends, Option-Return adds a line, and the stop button ends a
   reply early.

The trade-off: this conversation exists only on this Mac. It doesn't go through Cantrip, it
isn't stored on the Cantrip host, and it doesn't sync to Cantrip Agent, the browser Remote or
your other Macs. The app saves it in `~/Library/Application Support/<bundle ID>/DirectLocal/`
(readable only by you) and the settings in its preferences. **Clear Conversation…** in the
toolbar's **⋯** menu deletes it.

It follows the same rules as Cantrip's Private Local tab:

- Plain HTTP only to `127.0.0.1`, `localhost` or `[::1]`; any other server needs HTTPS. No
  password, API key, cookie or other credential is ever sent, and redirects and proxies aren't
  followed.
- Only models the server reports as installed: names containing `cloud` and models with
  `remote_model` or `remote_host` are left out. Before each message the app asks `/api/show`
  and requires `general.architecture`, so a cloud alias never gets your text.
- No cloud fallback. If the server fails, the error appears in the chat (for example
  mlx-serve's "Not enough free memory to load model" when the Mac is short of memory).
- Context: 512 to 131072 tokens (default 8192). System prompt: up to 8000 characters. Older
  messages are dropped from what's sent once the conversation outgrows the context window.

The **Private Local** tab on your paired Cantrip is separate and unchanged: it runs on the
host Mac, syncs like any other tab and has no tools.

### Tools from MCP servers on this Mac

The local model can use tools from the MCP servers already set up for your coding agents on
this Mac: Copilot CLI's `~/.copilot/mcp-config.json`, then Claude Code's `~/.claude.json`
(the first file wins a name). Nothing is on until you turn it on:

1. In **Settings › Tools & sign-ins** (saved as you change it) or Local Model **Settings…**,
   under **Tools from MCP servers**, turn on a server. The app
   starts it once to list its tools.
2. Open the tools list to turn individual tools off, and choose **Ask First** (the default) or
   **Run Automatically** for each. Tools the server marks read-only run automatically. A
   config file's own `tools` list still limits what's offered.
3. **Save**, then ask for something that needs the tool, for example "summarize my latest
   10 emails" with the `apple-mail` server.

When the model calls a tool, the reply shows an approval card with the exact arguments:
**Allow Once**, **Always Allow** (switches that tool to Run Automatically) or **Deny** (the
model is told you declined). Each call and its result is kept under the reply's
**Intermediate steps**. The model can chain up to 8 rounds of calls per reply; Stop ends it.

- Only servers that run on this Mac (stdio) are used; remote HTTP servers are listed but
  can't be turned on. Commands resolve with your login shell's `PATH`, so `npx` and Homebrew
  tools work as in Terminal, and the config's `env`, `args` and `cwd` apply.
- Servers start when first needed and stop after 5 idle minutes or when the app quits.
- Tool descriptions are sent with every message, so they use context. Settings shows the
  estimate, for example about 1,900 tokens for apple-mail's 9 reading tools; Local Model won't
  send when turned-on tools would take more than 60% of the context window. Results are cut to
  about a third of the window, and earlier turns' results to 600 characters.
- Tools run with your access. A server that scripts another app (apple-mail drives Mail with
  AppleScript) makes macOS ask once whether Cantrip Gateway Mac may control that app.
- Tool lists are cached in the same `DirectLocal` folder (`mcp-tools.json`) and reloaded when a
  server's command changes.

To check the connection from Terminal without opening a window (nothing is saved):

```sh
"/Applications/Cantrip Gateway Mac.app/Contents/MacOS/Cantrip Gateway Mac" \
  --direct-local-check --url http://127.0.0.1:11434 [--model NAME] [--prompt "Say hi"]
```

It lists the server's local models, confirms the model, and with `--prompt` streams one reply.
`--mcp-check [--server NAME]` instead lists the MCP servers it found, starts each one that can
run here, lists its tools with their context cost and stops it, without calling any tool.

## Updating the shared code

```sh
cd Hermes && git pull origin master && cd ..
make test
git commit -am "Bump Hermes" 
```

If a Hermes change adds UIKit-only code to a shared file, wrap it in `#if os(iOS)`.
If the Mac needs that piece, add an AppKit equivalent under `Sources/Platform`.
