# ✦ Cantrip

<img src="Resources/Cantrip.svg" width="128" alt="Cantrip: a pearl-violet C casting a golden spark" />

**A keyboard-first launcher with an AI agent built in.**

Open apps, calculate, ask questions, or give an agent a task. Cantrip drives
Claude Code, GitHub Copilot CLI, OpenAI Codex CLI, Google Antigravity (`agy`), or your own
OpenAI-compatible model server. Bring an authenticated backend; provider
charges and usage limits still apply.

**[User Guide](docs/README.md)** ·
[Mac setup](docs/getting-started-macos.md) ·
[Windows setup](docs/windows.md)

<img width="692" height="236" alt="Cantrip launcher interface" src="https://github.com/user-attachments/assets/ee8f9398-b48d-4455-b30b-77193cc05275" />

## Apps

Agents run on your Mac. The phone, Mac and browser clients connect to the same
live sessions.

| App | Runs on | Source |
|---|---|---|
| **Cantrip** (host) | macOS 14+, Universal | [`Sources/Cantrip/`](Sources/Cantrip/) |
| **Cantrip for Windows** | Windows 10/11 x64 | [`windows/`](windows/) |
| **Cantrip Agent** | iPhone, iPhone Duo, iPad (iOS 26+), Apple Watch | [`Clients/CantripIOS/`](Clients/CantripIOS/) |
| **Cantrip Gateway Mac** | macOS 26+ | [`Clients/CantripGatewayMac/`](Clients/CantripGatewayMac/) |
| **Cantrip Gateway for Windows** | Windows 10/11 x64 | [`Clients/CantripGatewayMac/windows/`](Clients/CantripGatewayMac/windows/) |
| Browser remote | Any modern browser | Served by the Mac host |

Cantrip Agent (formerly AgentGateway) is the native iPhone and iPad client; an
unfolded iPhone Duo gets a navigation rail and a sidebar, and its Apple Watch
app talks to Cantrip Home by voice.
Cantrip Gateway Mac brings the same Home and project tabs to a Mac window by
compiling Cantrip Agent's shared Swift code from `Clients/CantripIOS`. Pair either one
under **Settings > Remote control**; see [Remote control](docs/remote-control.md).
On macOS 26 the Cantrip menu bar app can also show that same window itself,
in place of the panel, with no pairing: see
[Use the Home window instead of the panel](docs/everyday-tasks.md#use-the-home-window-instead-of-the-panel).

Windows supports the launcher, math, Claude/Copilot/Codex/Antigravity, screen capture and
plugins, and shows a paired Mac's Cantrip Home read-only, but doesn't yet have
local models, session tabs, memory, voice, council or Remote hosting; Cantrip
Gateway for Windows is the full client for a Mac. See the [feature comparison](docs/windows.md#what-is-and-is-not-available)
and [macOS version support](docs/updating-and-troubleshooting.md#macos-26-and-27-support).

## Features (macOS)

- **Launcher:** open apps, search files with Spotlight, calculate, convert
  units and run shell commands. [Everyday tasks](docs/everyday-tasks.md)
- **AI workspace:** streaming answers, attachments, voice, and renameable,
  lockable session tabs, each with its own terminal. Runs survive crashes and
  relaunches; a run that fails or times out stops on **Continue**, with the
  queue waiting behind it; **Start Fresh** drops a stuck tab's context but
  keeps its history; **Delete Message** removes a prompt and reply everywhere,
  model context included. [Sessions](docs/sessions-and-council.md)
- **Busy-run messages:** Auto reads each new message and injects context,
  redirects, queues, combines related follow-ups, or starts a parallel
  subagent. Queue, Redirect, Inject and **Send now** stay available.
  [Send while busy](docs/sessions-and-council.md#send-instructions-while-the-agent-is-busy)
- **Background work:** watchers and subagents keep running while you keep
  chatting; Cantrip wakes the run when they finish. Home's **Background** list
  shows every tab's running tasks, each with **Stop**, and tab lists mark the
  tabs that have them. [Tabs' background tasks](docs/cantrip-home.md#tabs-background-tasks)
- **Keep agents running when Cantrip quits:** a background engine runs tabs,
  Home and paired devices with no window open, so quitting or updating the app
  doesn't stop them. [Background engine](docs/headless.md#keep-agents-running-when-cantrip-quits)
- **Cards:** replies about the weather, places and links get cards, and tools
  can return their own. Builds, tests and transfers an agent runs get one live
  card per reply with the elapsed time, an estimate from earlier runs and the
  result, its earlier steps folded into a one-line summary. The Mac, Cantrip
  Agent, both Gateways and the browser Remote draw them. [Cards](docs/cards.md)
- **Child tabs:** an independent queued message runs (on its own for Auto
  delivery, paired devices and Home handoffs, several at once within the caps
  and the Mac's resources) in a nested tab with its own git branch; work that
  depends on it follows it there. It merges back when the parent is idle and
  asks on a conflict. [Child tabs](docs/sessions-and-council.md#child-tabs)
- **Tabs look into each other:** parents see live child status, and models and
  Home read any non-private tab's conversation on demand or ask it a question,
  which shows as an **Asked tab** card until the answer arrives. Type `@` to
  point a message at one tab. [Look into other tabs](docs/sessions-and-council.md#look-into-other-tabs)
- **Remote control:** the Mac's sessions from Cantrip Agent, Cantrip Gateway
  Mac, another Mac or a browser, over LAN or Tailscale, with push alerts,
  approvals, attachments and full-screen View Mac (touch on the phone). Every
  client changes the Mac's settings on the same pages.
  [Remote control](docs/remote-control.md), [Mac settings](docs/remote-control.md#mac-settings);
  on a cloud or SSH-only Mac, run it headless. [Headless host](docs/headless.md)
- **Cantrip Home:** one permanent conversation that answers questions, hands
  project changes to the right tab or opens a new one, and runs scheduled
  (interval, weekday or monthly) tasks, trackers and incident investigations,
  with cards on their results. In Cantrip Agent, Home's **Builds** section
  lists your over-the-air install page. [Cantrip Home](docs/cantrip-home.md)
- **Shared Mac resources:** tabs lease simulators from a small shared pool, and
  with **Heavy builds take turns** on, `xcodebuild` and `swift` builds from
  tabs, child tabs, self-hosted CI runners and Home wait for a few build slots, listed in
  Background on every client. [Shared simulators](docs/updating-and-troubleshooting.md#shared-simulators),
  [Heavy builds take turns](docs/updating-and-troubleshooting.md#heavy-builds-take-turns)
- **Private Local:** a saved tab that only talks to your self-hosted Ollama
  server, with no tools or cloud fallback.
  [Setup](docs/remote-control.md#persistent-private-local-tab)
- **Memory and council:** editable Markdown memory and multi-model answers.
  [Privacy and memory](docs/privacy-and-memory.md)
- **Usage and context:** Copilot AI-credit usage and a per-prompt context
  window breakdown.
- **OpenAI-compatible API:** scripts and apps on the Mac call
  `127.0.0.1:11439/v1` and get the same backend, usage-limit backups and usage
  tracking as tabs, counted per app. [Backends](docs/backends.md#serve-your-backends-to-other-apps-openai-compatible-api)
- **Extensions:** dashboards, MCP tools with inline MCP App views, custom
  slash commands and a `cantrip` CLI. Typing `/` suggests the backend's own
  commands and skills. [Extensions](docs/extensions-and-skills.md)
- **Same skills and rules on every backend:** one skills library and folder
  rules, linked or passed to Claude Code, Copilot, Codex and Antigravity.
  [Share skills](docs/extensions-and-skills.md#share-skills-and-rules-with-every-backend)

Capabilities depend on the backend. The Local Model backend does not receive
attachments or screen captures.

## Quick start

On macOS, install Xcode Command Line Tools and
[set up one AI backend](docs/backends.md). Then either download
**Cantrip-X.Y.Z.dmg** from the [latest release](https://github.com/FlyingViet/cantrip/releases/latest),
open it and drag Cantrip to Applications (signed with Developer ID, notarized,
updates itself from releases; **Install Command-Line Tool** in Settings ›
About & Updates adds the `cantrip` command), or build it from source:

```sh
mkdir -p ~/Coding
git clone https://github.com/FlyingViet/cantrip.git ~/Coding/Cantrip
cd ~/Coding/Cantrip
./install.sh
```

The installer builds and signs `Cantrip.app`, installs the `cantrip` CLI and
opens the app (a signing-certificate password dialog may appear). Keep the
checkout; updates rebuild from it. Press **Option+Space**, choose a
**Backend** in Settings › Models (the gear), then type a question and press **Return**.
See [Mac setup](docs/getting-started-macos.md) or the
[update guide](docs/updating-and-troubleshooting.md).

On Windows, follow [Windows setup](docs/windows.md) and open Cantrip with
**Alt+Space** (or **Ctrl+Space** if that is taken).

## Command line (macOS)

| Command | What it does | Details |
|---|---|---|
| `cantrip "question"` | Ask the active backend (pipe input: `cat log \| cantrip "why?"`) | [Ask from Terminal](docs/everyday-tasks.md#ask-cantrip-from-terminal) |
| `cantrip --backend NAME "question"` | Ask a specific backend (`claude`, `copilot`, `codex`, `agy` or `local`), e.g. `< changes.diff` | [Ask from Terminal](docs/everyday-tasks.md#ask-cantrip-from-terminal) |
| `cantrip runs [session-or-run-id]` | List recent runs, or show one session's or run's events | [Recover after a crash](docs/sessions-and-council.md#recover-after-a-crash-or-interruption) |
| `cantrip tab list` / `read ID` / `ask ID "question"` | List tabs with their child tabs, read a tab's recent turns (read-only), or ask a tab and print its reply | [Look into other tabs](docs/sessions-and-council.md#look-into-other-tabs) |
| `cantrip daemon start` | Run Cantrip in the background now and at every login (no windows) | [Headless](docs/headless.md#commands) |
| `cantrip daemon stop` | Stop it and don't start it at login | [Headless](docs/headless.md#commands) |
| `cantrip daemon restart` | Restart it (installs a staged update) | [Headless](docs/headless.md#commands) |
| `cantrip daemon run` | Run in this terminal (for tmux, screen or containers) | [Headless](docs/headless.md#commands) |
| `cantrip daemon logs [-f]` | Show the host log | [Headless](docs/headless.md#commands) |
| `cantrip status [--json]` | Is Cantrip running, and is Remote reachable? | [Headless](docs/headless.md#commands) |
| `cantrip pair [options]` | Show a QR code and details to pair Cantrip Agent or Gateway. Options: `--url URL`, `--direct [HOST:PORT]`, `--name NAME`, `--rotate` (new token; devices pair again), `--no-qr` or `--json` | [Pair a device](docs/headless.md#pair-a-device) |
| `cantrip config` | List settings | [Headless](docs/headless.md#commands) |
| `cantrip config get KEY` | Show one setting | [Headless](docs/headless.md#commands) |
| `cantrip config set KEY VALUE [KEY VALUE ...]` | Change one or more settings | [Headless](docs/headless.md#commands) |
| `cantrip doctor` | Check the host, Remote, backends and Tailscale | [Headless](docs/headless.md#commands) |
| `cantrip cleanup [--dry-run] [--list] [--simulators] [--json]` | Remove unused agent sessions, worktrees, simulators and build caches now, and show package cache sizes (Cantrip also does this daily) | [Free up disk space](docs/updating-and-troubleshooting.md#free-up-disk-space) |
| `cantrip seed-worktree PATH [--from CHECKOUT]` | Clone another checkout's installed `node_modules`, `Pods` and `.spm` into a new worktree, copy-on-write | [New worktrees reuse installed packages](docs/updating-and-troubleshooting.md#new-worktrees-reuse-installed-packages) |
| `cantrip mcp` / `migrate [--apply]` / `connect NAME` / `approve NAME` / `enable` / `disable NAME [--backend B \| --tab ID]` / `restore` | Share MCP servers and their sign-ins with every backend, sign in to remote ones (approve from any client) | [Share MCP servers](docs/extensions-and-skills.md#share-mcp-servers-with-every-backend) |
| `cantrip skills` / `add PATH [--move]` / `edit NAME` / `enable` / `disable NAME` / `sync` / `check` | One skills library linked for every backend: which backends see each skill, problems, credentials refused | [Share skills](docs/extensions-and-skills.md#share-skills-and-rules-with-every-backend) |
| `cantrip instructions [list [DIR]]` / `edit FOLDER [--mirror PATH]` / `check` | Rules for everything under a folder, given to every backend; drift in repositories' AGENTS.md and CLAUDE.md files | [Share skills](docs/extensions-and-skills.md#share-skills-and-rules-with-every-backend) |
| `cantrip secret list` / `sync` / `run NAME… -- COMMAND` / `import FOLDER [--apply]` / `verify FOLDER` | Secrets from a Bitwarden folder, cached in the Keychain and handed to commands by name with their values masked in output | [Hand secrets to scripts](docs/privacy-and-memory.md#hand-secrets-to-scripts-jobs-and-mcp-servers) |
| `cantrip env [list]` / `show [FOLDER]` / `set NAME …` / `run [--dir F] -- CMD` / `hook install` | Per-project environment profiles: the Xcode, Node, PATH and variables every backend, child tab and `!` command in a project gets | [Project toolchains](docs/backends.md#give-each-project-the-same-toolchain-on-every-backend) |
| `cantrip api [--json]` / `api key new` / `api key clear` | Cantrip's OpenAI-compatible API for apps on this Mac: status, calls per consumer and the proxy key | [OpenAI-compatible API](docs/backends.md#serve-your-backends-to-other-apps-openai-compatible-api) |
| `cantrip sim acquire --device NAME [--os VERSION] [--exact] [--wait SECONDS]` / `release` / `list` / `adopt UDID` / `tidy` | Lease a shared simulator to a tab (one iPhone for every iPhone request, a Duo per iOS version, at most 2 running at once) and give it back | [Shared simulators](docs/updating-and-troubleshooting.md#shared-simulators) |
| `cantrip build-queue` / `run [--tool NAME] -- COMMAND` | Builds running and waiting for a slot while heavy builds take turns, or run any command in one | [Heavy builds take turns](docs/updating-and-troubleshooting.md#heavy-builds-take-turns) |
| `cantrip weather [PLACE] [--json]` | The forecast a reply's weather card shows (default: the Mac's location) | [Weather cards](docs/remote-control.md#weather-cards) |
| `cantrip help` | Show the usage of these host commands (`cantrip --help` shows the ask and `runs` examples) | [Headless](docs/headless.md#commands) |

## Permissions and privacy

**Act on my behalf** is off by default. Keep it off, with Claude
**Permissions** at **Safe** and Copilot **Allow all tools** off, until you
trust the setup; explicit shell commands still run on their own. Either way,
one [agent policy](docs/privacy-and-memory.md#set-what-agents-may-do) of allow,
ask and deny rules applies to every tab and backend, checked on the Mac before
each tool call. A push rule can scan the outgoing commits for private details:
a clean scan lets the push run, and a finding stops it for your approval. Memory,
document search, calendar and location context are **on** by default (subject
to macOS permissions); screen context and Remote hosting are off. Private mode
stops Cantrip saving the conversation, but not tool writes, image caches or
provider logging.

Read [permissions, privacy, and memory](docs/privacy-and-memory.md), and for
the phone apps, [approvals and secure input](docs/remote-control.md#remote-approvals-and-secure-input),
[push setup](docs/remote-control.md#cantrip-agent-completion-notifications) and
[View Mac](docs/remote-control.md#mac-attention-view-mac-and-face-id).

## Development

| Component | Build / test |
|---|---|
| Mac host ([`Sources/Cantrip/`](Sources/Cantrip/)) | From the repo root: `make build`, `make test` |
| Windows ([`windows/`](windows/)) | From `windows/`: `npm ci`, then `npm run build` / `npm test` |
| Cantrip Agent ([`Clients/CantripIOS/`](Clients/CantripIOS/)) | XcodeGen iOS project; see its README |
| Cantrip Gateway Mac ([`Clients/CantripGatewayMac/`](Clients/CantripGatewayMac/)) | XcodeGen Mac project that compiles `Clients/CantripIOS`; from its folder: `make test`. Windows: `windows/` in that folder |

See the [plugin reference](PLUGINS.md), [backend onboarding guide](BACKEND-ONBOARDING.md),
[Windows parity checklist](windows/PARITY.md) and [app artwork](Resources/README.md).
