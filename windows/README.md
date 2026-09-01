# ✦ Cantrip for Windows

A Windows-first MVP of [Cantrip](https://github.com/FlyingViet/cantrip):
Spotlight-style local actions plus Claude, GitHub Copilot, or Codex in one
global launcher.

## Included

- **Alt+Space** global summon/dismiss shortcut with a clearly reported
  Ctrl+Space fallback when another app already owns it
- Start Menu app discovery, fuzzy search, and launching
- Instant arithmetic and common unit conversions
- Explicit PowerShell commands with `!command`
- Claude Code, GitHub Copilot CLI, and Codex CLI detection
- Streaming process output, cancellation, backend choice, and working directory
- Sanitized GitHub-flavored Markdown responses with fenced code and tables
- Opt-in multi-monitor screen context with removable previews and per-run cleanup
- Hash-approved plugins with sandboxed dashboards, bounded data sources, MCP
  injection, and live reload
- Safe-by-default plan mode with an explicit **Allow agent actions** switch
- Tray menu and compact graphite, macOS-inspired keyboard-first launcher

This is the first usable slice, not full parity with the macOS app. File
indexing, persistent sessions, local OpenAI-compatible models, memory,
file attachments, voice, and council mode are follow-up
milestones. Progress and acceptance criteria are tracked in
[`PARITY.md`](PARITY.md).

## Requirements

- Windows 10/11 x64
- Node.js 20.19+
- At least one authenticated backend:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  - [GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli)
  - [OpenAI Codex CLI](https://github.com/openai/codex)

## Run locally

```powershell
npm install
npm run dev
```

Press **Alt+Space**, type a query, and press Enter. Use Ctrl+Enter to force an
AI prompt when an app suggestion is selected.

If PowerToys Run or another launcher already owns Alt+Space, Cantrip displays a
warning and temporarily uses Ctrl+Space. Disable or change the conflicting
shortcut, then click **Retry Alt+Space** in Cantrip or its tray menu.

Examples:

```text
chrome
142 * 8.5
10 km to miles
!git status
summarize this repository
```

## Settings

Open the **gear** in the bottom-right corner. Settings are applied per backend
and persist across restarts:

| Backend | Model | Reasoning effort | Context |
|---|---|---|---|
| Claude Code | Alias or custom model ID via `--model` | `--effort` | Model-managed; `sonnet[1m]` is offered when entitled |
| GitHub Copilot | Entitled or custom model ID via `--model` | `--reasoning-effort` | Default or `long_context` via `--context` |
| OpenAI Codex | Custom model ID via `--model` | `model_reasoning_effort` config override | Model-managed |

The same panel controls agent actions, panel opacity, launch at login, and
shows the active global shortcut. Model availability still depends on the
installed CLI and your provider account.

## Screen context

Click **▣** to capture every available display for the next AI prompt. Cantrip
shows removable previews, materializes PNG files only for that run, passes them
through each backend’s supported attachment mechanism, and deletes them on
completion, cancellation, quit, or the next startup after a crash.

## Plugins

Open **◈ → Settings → Plugins** to open the plugin folder, rescan, review exact
declarations, approve, enable, and launch dashboards. Windows uses the same
manifest schema as macOS. See [`PLUGINS.md`](PLUGINS.md) and the installable
`..\Examples\plugins\hello-dashboard` sample.

## Validate and package

```powershell
npm test
npm run typecheck
npm run build
npm run package:win
```

The installer is written to `release/`.

Local builds are unsigned, so Windows SmartScreen may warn on first launch.
Production distribution should use an Authenticode code-signing certificate.

## In-app updates

Version 0.2.0 and later include **Settings → Updates** and matching tray
actions. Install the current release once; later versions can be checked,
downloaded, and installed with a restart from inside Cantrip.

Updates are distributed from releases in `FlyingViet/cantrip`. Publish by
matching `windows\package.json` to a repository tag:

```powershell
cd windows
npm version 0.4.0 --no-git-tag-version
cd ..
git add .
git commit -m "Release 0.4.0"
git tag v0.4.0
git push origin main --tags
```

`..\.github\workflows\release-windows.yml` tests and publishes the NSIS
installer, blockmap, and `latest.yml` metadata. Code-sign production releases
before sharing broadly; the updater works unsigned for local testing, but
signing is needed for a smooth SmartScreen experience.

## Safety

The renderer has no Node.js access. OS and process operations live in the main
process behind validated IPC. AI backends start in plan/read-only mode. Turning
on **Allow agent actions** grants the selected CLI its autonomous action mode;
only enable it in directories you trust.
