# ✦ Cantrip

<img src="Resources/Cantrip.svg" width="128" alt="Cantrip: a pearl-violet C casting a golden spark" />

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
  renameable, lockable session tabs, recoverable runs, and a terminal per session.
  Names and close-protection locks sync to Cantrip Remote and AgentGateway.
- **Automatic sending:** a separate, tool-free model call interprets busy-run
  messages as context, corrections, or follow-ups. Uncertain decisions queue
  safely; manual Queue/Redirect/Inject overrides remain available.
- **Agent actions:** commands and file edits with backend-specific
  permissions; inspect tool activity and file diffs.
- **Memory and council:** editable Markdown memory and multi-model answers.
- **Copilot usage:** account-wide remaining allowance, reset date, and additional
  usage in the Mac's **Usage** panel and AgentGateway's header beside the lane picker.
  Reads your existing Copilot login without sending a prompt; credentials stay on the Mac.
- **Long prompts:** compact, plain-text previews with **Read full prompt**,
  paged reading, and full-text copy/download in Mac and Remote. The submitted
  text stays intact. Memory retrieval uses bounded, deduplicated query terms
  and runs off the UI thread; large Remote responses are encoded off-thread.
- **Remote control:** use the Mac's sessions from AgentGateway on iPhone/iPad,
  another Mac, or a browser. Native clients support paired LAN connections;
  a saved Tailscale Serve URL is preferred even on the local network. Automatic
  routing uses LAN if Tailscale is unavailable and restores Tailscale with
  two confirmed read-only probes. Bounded reads and coalesced web refreshes avoid
  stalled request backlogs, without switching healthy Tailscale connections to LAN or replaying sends;
  Tailscale-only mode is also available. AgentGateway can display and remove queued prompts.
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

### App artwork

The Cantrip mark is a pearl-violet **C** casting a warm golden spark: a small,
useful spell on a midnight-amethyst background. The same mark is used by the
Mac and Windows apps and the AgentGateway iOS companion.

Run `make artwork` on macOS to regenerate the artwork using native CoreGraphics
and ImageIO, with no fonts, downloaded images, or extra dependencies.
Edit `Scripts/generate-artwork.swift`, not the generated assets:

| Asset | Use |
|---|---|
| `Resources/Cantrip.svg` | Scalable full-color artwork |
| `Resources/CantripIcon.png` | Opaque, full-bleed 1024px iOS master; let iOS apply its own corner mask |
| `Resources/AppIcon.png` / `AppIcon.icns` | Mac icon with rounded tile and transparent desktop padding |
| `windows/assets/Cantrip.ico` | Windows app/installer icon at 16, 24, 32, 48, 64, 128, and 256px |

To sync the companion in a sibling checkout, run
`cp Resources/CantripIcon.png ../Hermes/Sources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`.
Normal app builds use the checked-in PNG/ICO assets; `make app` regenerates
the ignored ICNS as needed without requiring artwork regeneration.
