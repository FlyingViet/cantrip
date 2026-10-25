# ✦ Cantrip

<img src="Resources/Cantrip.svg" width="128" alt="Cantrip: a pearl-violet C casting a golden spark" />

**A keyboard-first launcher with an AI agent built in.**

Open apps, calculate, ask questions, or give an agent a task. Cantrip drives
Claude Code, GitHub Copilot CLI, OpenAI Codex CLI, or your own
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
| **Cantrip Agent** | iPhone, iPad (iOS 26+) | [FlyingViet/Hermes](https://github.com/FlyingViet/Hermes) |
| **Cantrip Gateway Mac** | macOS 26+ | [FlyingViet/CantripGatewayMac](https://github.com/FlyingViet/CantripGatewayMac) |
| **Cantrip Gateway for Windows** | Windows 10/11 x64 | [CantripGatewayMac/windows](https://github.com/FlyingViet/CantripGatewayMac/tree/main/windows) |
| Browser remote | Any modern browser | Served by the Mac host |

Cantrip Agent (formerly AgentGateway) is the native iPhone/iPad client.
Cantrip Gateway Mac brings the same Home and project tabs to a Mac window by
compiling Cantrip Agent's shared Swift code as a submodule. Pair either one
under **Settings > Remote control**; see [Remote control](docs/remote-control.md).

Windows supports the launcher, math, Claude/Copilot/Codex, screen capture and
plugins, but not yet local models, session tabs, memory, voice, council or
Remote. See the [feature comparison](docs/windows.md#what-is-and-is-not-available)
and [macOS version support](docs/updating-and-troubleshooting.md#macos-26-and-27-support).

## Features (macOS)

- **Launcher:** open apps, search files with Spotlight, calculate, convert
  units and run shell commands. [Everyday tasks](docs/everyday-tasks.md)
- **AI workspace:** streaming answers, attachments, voice, and renameable,
  lockable session tabs, each with its own terminal. Runs survive crashes,
  relaunches and network drops; **Start Fresh** drops a stuck tab's context but
  keeps its history. [Sessions](docs/sessions-and-council.md)
- **Busy-run messages:** Auto reads each new message and injects context,
  redirects, queues, combines related follow-ups, or starts a parallel
  subagent. Queue, Redirect, Inject and **Send now** stay available.
  [Send while busy](docs/sessions-and-council.md#send-instructions-while-the-agent-is-busy)
- **Background work:** watchers and subagents keep running while you keep
  chatting; Cantrip wakes the run when they finish.
- **Remote control:** the Mac's sessions from Cantrip Agent, Cantrip Gateway
  Mac, another Mac or a browser, over LAN or Tailscale, with push alerts,
  approvals, attachments and View Mac. [Remote control](docs/remote-control.md);
  on a cloud or SSH-only Mac, run it headless. [Headless host](docs/headless.md)
- **Cantrip Home:** one permanent conversation that answers questions, hands
  project changes to the right tab, and runs scheduled tasks, trackers and
  incident investigations. [Cantrip Home](docs/cantrip-home.md)
- **Private Local:** a saved tab that only talks to your self-hosted Ollama
  server, with no tools or cloud fallback.
  [Setup](docs/remote-control.md#persistent-private-local-tab)
- **Memory and council:** editable Markdown memory and multi-model answers.
  [Privacy and memory](docs/privacy-and-memory.md)
- **Usage and context:** Copilot AI-credit usage and a per-prompt context
  window breakdown.
- **Extensions:** dashboards, MCP tools with inline MCP App views, custom
  slash commands and a `cantrip` CLI. Typing `/` suggests the backend's own
  commands and skills. [Extensions](docs/extensions-and-skills.md)

Capabilities depend on the backend. The Local Model backend does not receive
attachments or screen captures.

## Quick start

On macOS, install Xcode Command Line Tools and
[set up one AI backend](docs/backends.md), then run:

```sh
mkdir -p ~/Coding
git clone https://github.com/FlyingViet/cantrip.git ~/Coding/Cantrip
cd ~/Coding/Cantrip
./install.sh
```

The installer builds and signs `Cantrip.app`, installs the `cantrip` CLI and
opens the app (a signing-certificate password dialog may appear). Keep the
checkout; updates rebuild from it. Press **Option+Space**, choose a
**Backend** under the gear, then type a question and press **Return**.
See [Mac setup](docs/getting-started-macos.md) or the
[update guide](docs/updating-and-troubleshooting.md).

On Windows, follow [Windows setup](docs/windows.md) and open Cantrip with
**Alt+Space** (or **Ctrl+Space** if that is taken).

## Command line (macOS)

| Command | What it does | Details |
|---|---|---|
| `cantrip "question"` | Ask the active backend (pipe input: `cat log \| cantrip "why?"`) | [Ask from Terminal](docs/everyday-tasks.md#ask-cantrip-from-terminal) |
| `cantrip --backend NAME "question"` | Ask a specific backend (`claude`, `copilot`, `codex` or `local`), e.g. `< changes.diff` | [Ask from Terminal](docs/everyday-tasks.md#ask-cantrip-from-terminal) |
| `cantrip runs [session-or-run-id]` | List recent runs, or show one session's or run's events | [Recover after a crash](docs/sessions-and-council.md#recover-after-a-crash-or-interruption) |
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
| `cantrip cleanup [--dry-run] [--list] [--json]` | Remove unused agent sessions and worktrees now (Cantrip also does this daily) | [Free up disk space](docs/updating-and-troubleshooting.md#free-up-disk-space) |
| `cantrip help` | Show the usage of these host commands (`cantrip --help` shows the ask and `runs` examples) | [Headless](docs/headless.md#commands) |

## Permissions and privacy

**Act on my behalf** is off by default. Keep it off, with Claude
**Permissions** at **Safe** and Copilot **Allow all tools** off, until you
trust the setup; explicit shell commands still run on their own. Memory,
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
| [Cantrip Agent](https://github.com/FlyingViet/Hermes) | XcodeGen iOS project; see its README |
| [Cantrip Gateway Mac](https://github.com/FlyingViet/CantripGatewayMac) | XcodeGen Mac project with Hermes as a submodule; see its README |

See the [plugin reference](PLUGINS.md), [Windows parity checklist](windows/PARITY.md)
and [app artwork](Resources/README.md).
