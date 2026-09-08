# ✦ Cantrip

**A keyboard-first launcher with an AI agent built in.**

Open apps, calculate, ask questions, or give an agent a task. Cantrip connects
to Claude Code, GitHub Copilot CLI, OpenAI Codex CLI, or an OpenAI-compatible
model server on macOS. AI access is separate: bring an authenticated backend
or your own model server. Provider charges and usage limits still apply.

**[User Guide](docs/README.md)** ·
[Mac setup](docs/getting-started-macos.md) ·
[Windows setup](docs/windows.md)

<img width="692" height="236" alt="Cantrip launcher interface" src="https://github.com/user-attachments/assets/ee8f9398-b48d-4455-b30b-77193cc05275" />

## Platforms

| Platform | Requirements | Status |
|---|---|---|
| macOS | macOS 14+, Xcode Command Line Tools | Full Swift app; open with **Option+Space** |
| Windows | Windows 10/11 x64; Node.js 20.19+ for source builds | Electron app; open with **Alt+Space** |

Windows supports app launching, math, Claude/Copilot/Codex, screen capture,
and plugins. It does **not** yet support local models, persistent session
tabs, memory, voice, council, or Cantrip Remote. See the
[feature comparison](docs/windows.md#what-is-and-is-not-available).

## What it does

The macOS app includes:

- **Launcher and terminal:** open apps, search files through Spotlight,
  calculate, convert units, and run explicit shell commands.
- **AI workspace:** streaming answers, file/screenshot attachments, voice,
  session tabs, recoverable runs, and a terminal per session.
- **Agent actions:** commands and file edits with backend-specific
  permissions; inspect tool activity and file diffs.
- **Memory and council:** editable Markdown memory and multi-model answers.
- **Remote control:** use the Mac's sessions from AgentGateway on iPhone/iPad,
  another Mac, or a browser. Native clients support paired LAN connections;
  Tailscale Serve provides optional away-from-home access. Automatic routing
  backs off failed LAN connections and recovers without replaying sends;
  Tailscale-only mode is also available. AgentGateway can display queued prompts.
- **Extensions:** dashboards, MCP tools, custom slash commands, and a
  `cantrip` command for asking questions from Terminal.

Capabilities depend on the backend. The current Local Model backend does
not receive file/image attachments or screen captures; tool use requires
a compatible model and action permissions.

## Quick start

### macOS

Install Xcode Command Line Tools and
[set up one AI backend](docs/backends.md), then run:

```sh
mkdir -p ~/Coding
git clone https://github.com/FlyingViet/cantrip.git ~/Coding/Cantrip
cd ~/Coding/Cantrip
./install.sh
```

The installer builds and signs `Cantrip.app`, installs the `cantrip` CLI,
and opens the app. A signing-certificate password dialog may appear.
Keep the checkout: rebuilds and updates use it.

1. Press **Option+Space**, then open the **gear**.
2. Select your **Backend** and review the permissions and context settings below.
3. Type a question and press **Return**. If an app suggestion is selected,
   **Command+Return** sends to the AI instead.

For prerequisites, sign-in, and launch-at-login instructions, see
[Mac setup](docs/getting-started-macos.md). Already installed?
Use the [update guide](docs/updating-and-troubleshooting.md).

### Windows

Follow [Windows setup](docs/windows.md) to install a release that includes
a Windows installer, or run from source. If **Alt+Space** is occupied,
Cantrip falls back to **Ctrl+Space** and reports the conflict.

## Permissions and privacy

On Mac, **Act on my behalf** is off by default. For your first question,
leave it off, keep Claude **Permissions** at **Safe**, and leave Copilot
**Allow all tools** off. These controls are separate; explicit shell
commands also execute independently of the action toggle.

**Memory, document search, calendar, and location context are enabled by
default** on Mac, subject to OS permissions where required. Review Settings
before sharing sensitive work. Screen context and Remote hosting are off
by default. Private mode suppresses Cantrip conversation persistence, but
does not prevent tool writes, image caches, or backend/provider logging.
Read [permissions, privacy, and memory](docs/privacy-and-memory.md).

## Learn more

| Task | Guide |
|---|---|
| Choose a backend or local model | [Backend setup](docs/backends.md) |
| Launch apps, run commands, or use voice/CLI | [Everyday tasks](docs/everyday-tasks.md) |
| Attach files, screenshots, or selected text | [Files and screen context](docs/files-and-screen-context.md) |
| Resume work or compare models | [Sessions and council](docs/sessions-and-council.md) |
| Pair AgentGateway, send photos, or connect another Mac | [Remote control](docs/remote-control.md) |
| Add dashboards, tools, or slash commands | [Extensions and skills](docs/extensions-and-skills.md) |
| Find a shortcut or fix a problem | [Keyboard reference](docs/keyboard-shortcuts.md) / [Troubleshooting](docs/updating-and-troubleshooting.md) |

## Development

| Platform | Source | Build / test |
|---|---|---|
| macOS | [`Sources/Cantrip/`](Sources/Cantrip/) | From the repo root: `make build`, `make test` |
| Windows | [`windows/`](windows/) | From `windows/`, run `npm ci`, then `npm run build` / `npm test` |

See the [plugin reference](PLUGINS.md) and
[Windows parity checklist](windows/PARITY.md) for implementation details.
