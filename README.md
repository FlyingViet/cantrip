# ✦ Cantrip

*A small spell you can cast instantly, at will, without cost.*

**TL;DR: Spotlight, but it's an AI agent.** ⌥Space opens a bar that launches
apps, finds files, and does math like Spotlight — but you can also tell it to
*do things* ("text Dan I'm late", "what am I working on?", "record this
stream") and it acts on your Mac using Claude, Copilot, Codex, or your own
local model. It sees your screens, remembers what works, runs jobs in
parallel tabs, and can even upgrade its own code.

![Cantrip icon](Resources/AppIcon.png)

## What it does

Press **⌥Space** and type. Instant, local, no AI round-trip:

- **App launching** — type `saf` or `open chrome`, get the matching app with its
  icon; running apps rank first and Enter switches to them instead of launching
  another instance
- **File search** — filename fragments search the Spotlight index; click to open
- **Math & conversions** — `142*8.5`, `10 km to miles`, `72 f to c`
- **Raw shell** — `!git status` streams command output right into the panel
- **Terminal mode** — the `>` toolbar icon opens a persistent shell inside
  the panel: `cd`, exports, and state carry between commands
- **Skills** — `/name args` runs your own scripts from
  `~/.config/cantrip/commands` (typeahead shows each skill's description);
  stdout renders as markdown in the panel

Ask anything more and it goes to an AI agent that can genuinely act:

- **Four swappable backends** — Claude Code (full agentic harness), GitHub
  Copilot CLI, OpenAI Codex CLI, or any OpenAI-compatible local model
  (vLLM / Ollama / llama.cpp — e.g. Hermes), with per-backend model *and*
  reasoning-effort pickers (context-window hints included). Local models get
  a tool-calling loop (`run_shell` + your MCP servers), so even they can act.
- **Steerable mid-flight** — while a response runs: ↩ queues your next
  message, ⌘↩ interrupts and redirects, and on Claude ⌥↩ injects your
  message into the *current* turn's context without interrupting (the same
  streaming-input mechanism Claude Code itself uses).
- **A real CLI** — `cat build.log | cantrip "why did this fail?"` streams
  answers to stdout through the running app, with `--backend`, your cwd as
  the working directory, and its own conversation continuity.
- **Context, automatically** — your location, next 48h of calendar, a
  screenshot of what you were just doing (opt-in), text you selected in any
  app (⌥⇧Space), pasted or dropped files, and content excerpts from your
  own documents matching the query (via the Spotlight index). Stateless
  backends keep three recent raw turns, retrieve up to two related older turns
  with local semantic matching, and send a compact topic summary instead of
  repeatedly reinjecting the full transcript.
- **Hermes-style memory** — a folder of plain markdown (Obsidian-compatible):
  always-loaded core files with hard caps that force consolidation, procedure
  notes the agents write after figuring things out, searchable session logs,
  and a nightly background consolidation pass. It gets better with use, and
  you can read everything it knows.
- **Parallel sessions** — tabs (⌘T, ⌘1–9), each with its own conversation,
  working directory, and backend processes. A 90-minute download babysits
  itself in one tab while you work in another; finished background sessions
  notify you. Closed sessions archive: reopen any of them (titles, dates,
  full context) from the history view.
- **Self-updating** — when the GitHub repo is ahead, an "Update available"
  chip appears; one click streams the pull + rebuild into the transcript
  and relaunches the new build.
- **Voice** — dictate queries; voice mode speaks replies and auto-listens
  for follow-ups.
- **On-screen tutorials** — ask how to do something in a visible app and it
  draws numbered tooltips directly on your screen pointing at the controls.
  Multi-display aware: all monitors are captured for context, and tooltips
  can point at any of them.
- **Progress you can audit** — a sidebar shows every tool step live, grouped
  by kind; Claude Code subagents appear nested inside their parent task.
  File edits render as colored diffs with one-click revert.
- **Usage dashboard** — per-platform quota overview: Claude's rate-limit
  window and 30-day spend (from the CLI's own figures), Copilot AI credits
  via GitHub's billing API, honest placeholders where platforms expose
  nothing.
- **Private mode** — per-session incognito (eye-slash button, panel turns
  purple): no transcript, no history, no memory writes, nothing on disk
  from Cantrip's side. (Backend CLIs and providers keep their own records —
  only a local model is end-to-end local.)
- **Developer extras** — per-session repo workdirs, git quick actions
  (commit message from staged diff, branch review), colored diffs of every
  file the agent touched with one-click revert, MCP server integration,
  settings in a dotfile.
- **Self-healing** — it knows its own source location, log file, and rebuild
  command; ask it to fix or extend itself and it will.

<img width="692" height="236" alt="image" src="https://github.com/user-attachments/assets/ee8f9398-b48d-4455-b30b-77193cc05275" />

## Install

Requirements: macOS 14+, Xcode Command Line Tools, and at least one backend
(Claude Code, Copilot CLI, or a local OpenAI-compatible server).

```sh
git clone https://github.com/brihoang1995/cantrip.git ~/Coding/Cantrip
cd ~/Coding/Cantrip
./install.sh
```

The installer checks prerequisites, creates a self-signed code-signing
certificate (so macOS permission grants survive rebuilds — expect one
password dialog), renders the app icon, builds, installs the `cantrip`
CLI on your PATH, adds a `cantrip-rebuild` alias, and launches the app.
A sparkle appears in your menu bar; press **⌥Space**.

### Backends

- **Claude Code**: `npm install -g @anthropic-ai/claude-code`, then run
  `claude` once to authenticate. In Cantrip's gear menu, pick a model
  (`sonnet`, `opus`, `haiku`, `fable`…) and a permission level.
- **Copilot**: `npm install -g @github/copilot`, run `copilot` once to
  authenticate. The model dropdown tries your account's entitlement (via
  the Copilot API when a token is available) and falls back to a curated
  current-models list.
- **Codex**: `npm install -g @openai/codex`, run `codex` once to sign in.
  Optional model override (e.g. `gpt-5-codex`) in the gear.
- **Local model**: point the gear's Base URL at any `/v1` endpoint
  (e.g. `http://hermes.local:8000/v1`), set the model name.

### Permissions

macOS prompts as features are first used — approve what you want:

| Permission | Enables | How |
|---|---|---|
| Microphone + Speech | voice input | automatic prompt |
| Location | "what's the weather" | automatic prompt |
| Calendar (Automation) | schedule-aware answers | automatic prompt |
| Accessibility | ⌥⇧Space selected-text capture | prompt → System Settings |
| Screen Recording | screen context, tutorials | manual: System Settings → Privacy, then relaunch |
| Full Disk Access | reading iMessage history | manual, optional |

The big switch — **"Act on my behalf"** in the gear — lets agents run
commands, edit files, and send messages without per-action approval. It's
off by default; treat it like handing over a terminal, because it is one.

## Usage cheat sheet

| Keys / prefix | Action |
|---|---|
| ⌥Space | summon / dismiss |
| ⌥⇧Space | grab selected text from the frontmost app, then summon |
| ↩ | send (or launch the suggested app) · while busy: queue |
| ⌘↩ | interrupt the current run and redirect it |
| ⌥↩ | inject into the current turn without interrupting (Claude) |
| `!cmd` | run a raw shell command |
| `/skill args` | run a script from ~/.config/cantrip/commands |
| ⌘T · ⌘1–9 · ⌘⇧[ ] | new / jump / cycle sessions |
| ⌘← ⌘→ | with text: jump cursor to start/end (⇧ selects) · empty field: switch tabs |
| ⌘N | new conversation (current session) |
| ⌘V | paste text — or attach an image/file from the clipboard |
| Esc | dismiss panel & overlays |

The bar is two rows: input + mic on top; below it the toolbar — working
directory, git actions (in repos), then terminal, private mode, history,
usage dashboard, progress sidebar, pin, screen context, backend picker,
gear, and new conversation/session. Hover any icon for an instant caption.
Drag any file onto the panel to attach it. Settings open as a right-hand
sidebar so you can tweak models mid-conversation.

## Configuration

- **Settings**: gear icon in the panel; export/import as
  `~/.cantriprc` JSON via the menu bar icon (dotfiles-friendly).
- **Memory vault**: `~/Cantrip Memory` by default (configurable) —
  open it in Obsidian; edit `USER.md` to tell it about yourself.
- **MCP servers**: `~/.config/cantrip/mcp.json`, standard
  `{"mcpServers": {…}}` format; their tools go to the local-model backend.
- **Skills**: executables in `~/.config/cantrip/commands/` — a
  `# description: …` header line feeds the typeahead; args arrive as `$@`,
  the session workdir as `$CANTRIP_WORKDIR`; emit markdown.
- **CLI**: `cantrip "question"`, `--backend claude|copilot|codex|local`,
  stdin is appended to the prompt. Requires the app running.
- **Logs**: `~/Library/Logs/Cantrip.log`.

## Troubleshooting

- **Panel won't appear**: check the menu bar sparkle exists; see the log.
- **"Failed to authenticate"**: re-login the backend CLI (`claude` → `/login`).
- **Permissions re-asked after rebuilds**: signing fell back to ad-hoc — run
  `make cert`, and if needed set the cert to Always Trust in Keychain Access.
- **Stuck request**: red stop button, or menu bar → Stop Current Request /
  Hide Panel & Overlays. Silent streams auto-cancel after 15 minutes.
- **Copilot quota "unavailable"**: GitHub's billing API needs the `user`
  scope — run `gh auth refresh -h github.com -s user`, then ↻ in the
  usage dashboard.
- **Weird behavior after self-modification**: `git diff`, laugh, revert.
