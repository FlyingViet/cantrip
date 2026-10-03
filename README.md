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

Mac builds are Universal (`arm64` + `x86_64`): Cantrip runs natively on Apple
silicon without Rosetta and retains Intel Mac support. Packaging rejects native
bundled components missing either architecture or requiring a newer macOS than
the app declares. The minimum remains macOS 14; it is not a maximum version.
macOS 26 is supported, and builds with Xcode 27 retain that same minimum for
macOS 27 readiness. macOS 27 runtime compatibility still needs confirmation on
that OS; see [macOS version support](docs/updating-and-troubleshooting.md#macos-26-and-27-support).
Separately installed AI CLIs,
their runtimes, MCP tools, and local model servers must also support your Mac;
see [Rosetta compatibility](docs/updating-and-troubleshooting.md#intel-app-or-rosetta-compatibility-warning).

Windows supports app launching, math, Claude/Copilot/Codex, screen capture,
and plugins. It does **not** yet support local models, persistent session
tabs, memory, voice, council, or Cantrip Remote. See the
[feature comparison](docs/windows.md#what-is-and-is-not-available).

## What it does

The macOS app includes:

- **Launcher and terminal:** open apps, search files through Spotlight,
  calculate, convert units, and run explicit shell commands.
- **AI workspace:** streaming answers, file/screenshot attachments, voice,
  renameable, lockable, reorderable session tabs, recoverable runs, and a terminal per session.
  Names, close-protection locks, and tab order sync to Cantrip Remote and Cantrip Agent.
  Drag a session tab onto another to move it, or use **Move Tab Left/Right** in
  its right-click menu. The Remote connection tab stays pinned first.
  Order survives restarts without switching conversations or interrupting work.
- **Automatic sending:** a separate, tool-free model call interprets busy-run
  messages as context, corrections, or follow-ups. Uncertain decisions queue
  safely; manual Queue/Redirect/Inject overrides remain available.
- **Background waiters:** after starting a long external build, TestFlight upload,
  download, or similar job, the agent can hand passive monitoring to a dedicated
  watcher and continue independent work. The watcher stays visible in the subagent
  monitor; when it finishes, Cantrip wakes the same run and continues from where it
  paused instead of making you send another message. The Mac Progress pane has
  separate **Steps** and **Background** tabs, while Cantrip Agent shows active
  background tasks in a compact button that opens their detail sheet.
- **Live context:** local Copilot and Claude Code can accept **Inject** messages
  without stopping their current work, including from Cantrip Agent and Mac/browser
  Remote. Copilot uses a persistent native SDK session per tab; accepted context is
  never blindly resent if its acknowledgement is lost. Requires Node.js and a
  recent Copilot CLI with its matching bundled SDK/runtime.
- **Agent actions:** commands and file edits with backend-specific
  permissions; inspect tool activity and file diffs.
- **Memory and council:** editable Markdown memory and multi-model answers.
  Cantrip Agent's **Cantrip Memory** menu browses saved facts, preferences, notes,
  and session logs read-only, with search and paged file contents.
- **Copilot usage:** account-wide AI credits used / total, reset date, and additional
  usage in the Mac's **Usage** panel and Cantrip Agent's header beside the lane picker.
  Reads your existing Copilot login without sending a prompt; credentials stay on the Mac.
- **Prompt context:** a line under each sent prompt shows how many tokens were in
  the model's context and how full the window is. Click it (Mac, Remote, Cantrip
  Agent) for the breakdown: system instructions, tool definitions, conversation,
  the message's estimated size with what Cantrip added, and the run's model calls,
  input (with cached share) and output tokens. Copilot reports the full breakdown;
  Claude Code reports totals.
- **Long prompts:** compact, plain-text previews with **Read full prompt**,
  paged reading, and full-text copy/download in Mac and Remote. The submitted
  text stays intact. Memory retrieval uses bounded, deduplicated query terms
  and runs off the UI thread; large Remote responses are encoded off-thread.
- **Remote control:** use the Mac's sessions from Cantrip Agent (formerly
  AgentGateway) on iPhone/iPad,
  another Mac, or a browser. Recent messages load with full text and tool details.
  Cantrip Agent can send one MOV/MP4 video (100 MB / five minutes) for analysis,
  preserving the original and providing four timestamped preview frames.
  Scrolling up automatically pages back through the whole conversation, with no
  button to tap and no jump in what you are reading. Opening a tab or polling
  never prefetches history; a failed page pauses automatic loading and shows Retry.
  Page and cache boundaries retain the prompt before its responses, even when
  a large answer exceeds the soft page limits.
  Mac Remote uses an expanded, vertically scrollable
  tab list on the left; main Cantrip and ordinary browser tabs stay across the
  top. Remote tab lists keep their scroll position during refreshes. Mac Remote
  and browser tabs support drag reordering, move buttons in tab settings, and
  Option/Alt + arrow keys (up/down in the sidebar, left/right in the top strip).
  Cantrip Agent's drawer/sidebar provides drag handles and **Move Tab Up/Down**
  actions. Reordering requires the updated host's `supportsTabReordering`
  capability; unsaved Private mode tabs remain hidden from Remote.
  Native Mac tab labels use dedicated mouse handling, so dragging a tab does
  not move the launcher window; dragging the window background still works.
  Mac Remote
  shows a pulsing brain, live activity and queued counts in the sidebar, with
  the selected session's status pinned near the message box.
  Cantrip Agent includes tappable uploaded-image
  thumbnails and full-screen viewing. Native clients support paired LAN connections;
  a saved Tailscale Serve URL is preferred even on the local network. Automatic
  routing uses LAN if Tailscale is unavailable and restores Tailscale with
  two confirmed read-only probes. Bounded reads and coalesced web refreshes avoid
  stalled request backlogs, without switching healthy Tailscale connections to LAN or replaying sends;
  Tailscale-only mode is also available. Cantrip Agent can display and remove queued prompts.
  Host diagnostics separate lightweight `/health` liveness from authenticated
  session readiness, with content-free request timings and bounded response writes.
- **Durable runs:** journal encoding, writes, and synchronization use an ordered
  background writer. Run completion and Remote mutation acknowledgements wait
  for saved events; storage failures are surfaced instead of reporting success.
  When a run ends or a tab opens, a journal over 4 MB is atomically rewritten to
  just the events recovery replays (queued prompts, the last run's boundaries,
  and any unfinished run), so long-lived tabs keep launching quickly.
- **Private Local:** a permanent, saved tab shared with paired Remote clients.
  "Local" means **self-hosted**, not restricted to the Cantrip Mac. Your Ollama
  server can run on another machine, independently of the global backend and
  Copilot settings, with no cloud fallback. Configure its HTTPS server URL
  (or loopback HTTP), model, context tokens and system prompt through **Private Local
  Settings** in the Mac tab menu, Mac/browser Remote, or Cantrip Agent.
  Model availability on that server is checked before sending conversation text.
  Tools, shell/slash execution, Council, shared memory/digests, push summaries,
  and automatic external content are disabled. Auto queues follow-ups locally.
  This is distinct from unsaved **Private mode**. See [setup and privacy limits](docs/remote-control.md#persistent-private-local-tab).
- **Cantrip Home:** an optional permanent session that stays hidden from the
  ordinary Mac and Remote tab lists. Enable it in Mac Settings to power Cantrip
  Agent's focused **Chat / Tasks / Artifacts** mode with the same backend,
  per-session model controls, tools, attachments, input requests and history as
  Cantrip Remote. Home decides from each message's intent: references,
  questions and status checks about a project are answered in Home, while
  requests to change a project are handed to the open tab that owns it as a
  nested task. Home matches tabs by meaning, using each tab's title, the
  repositories its conversation works in and its latest requests, and a busy
  tab queues the handoff instead of being interrupted. Home keeps a live card for each handoff with the tab's status and
  final result. Tasks can be
  one-time, interval or weekday automations, or
  structured workspaces such as trackers. A weekday task can run at several
  local times a day in its own time zone, with DST handled. After sleep or a
  quit, an overdue task runs once rather than once per missed time, and a task
  never runs twice at the same time. A task can list other tasks in
  `runsAfter` (for example a morning briefing that reviews the trackers): it
  starts after their runs due at or before it finish, or 30 minutes after its
  own time at the latest. Local maintenance can queue a change for an existing
  task by writing `{"version":1,"taskID":"…","schedule":{…}}` (and/or
  `"runsAfter":["…"]`, `"runsAfterTimeoutMinutes":45`) into
  `~/.cache/Cantrip/home/task-edits/` (schedule-only edits also work in
  `schedule-edits/`); it is applied once that task is idle.
  Workspace tasks use a validated
  declarative schema for native list, detail and edit screens; their records can
  be updated conversationally or through the mobile UI. Touch and hold a task to
  drag it into a new order; the order is saved on the Mac. Each due run and
  local ingestion incident runs in its own hidden, single-use session with a
  fresh model context, so unrelated jobs run in parallel (3 at once by default;
  change it under Mac Settings > Remote control) and never add turns to Home
  chat or wait for it. Jobs that write the same task workspace or concern the
  same failing job run one after another, and a repeated trigger folds into the
  run already queued or running. An incident in a repository that an open tab
  clearly owns (by title, folder or the repositories it works in) is handed to
  that tab's queue instead, using Home's handoff cards and a notification; an
  incident whose file is already resolved is skipped. Hidden runs follow the same
  handoff rules for change work they discover. Concurrent jobs refresh Apple
  Mail through `Scripts/mail-refresh`, which shares one refresh between them.
  Results appear in the Background list (with per-run Stop), task run summaries,
  workspaces and completion notifications (which open the run's report in
  Home's background log); finished sessions are removed and their transcripts
  kept in that log. After a quit, interrupted tasks run once more and an
  interrupted incident is retried once. Home can still discuss or rerun any of
  them on request.
  Home's rules and safety checks are enforced by Cantrip, not by the model's
  CLI, so they hold whichever backend runs Home. Cantrip validates every task,
  record, handoff and artifact block (tolerating common JSON slips). When a block
  is invalid, or a task or handoff prompt leans on the conversation instead of
  standing alone, it asks the same model once, inside the same reply, for a
  corrected block. Handoffs are briefs (goal, context, constraints, done-when)
  that Cantrip turns into a standalone tab prompt with the user's own message.
  Before each tool runs in Home (Copilot, Claude Code or a local
  OpenAI-compatible model), Cantrip blocks catastrophic commands: administrator
  commands, erasing disks or the home folder, piping downloads into a shell,
  stopping Cantrip, and writing Home's own state files. In unattended background
  runs, sending messages or email, pushing, deploying, deleting files outside
  temporary folders and Artifacts, and system changes wait for approval through a
  push-notified input request; unanswered after 10 minutes, the step is skipped.
  Background runs can't create or change tasks. Codex and Copilot Remote (ACP) can
  run commands Cantrip never sees, so on them background runs fail closed with an
  explanation and the Home chat follows the rules on its own.
  Deliverable files the agent saves in Home's guarded artifact folder
  appear automatically in Artifacts and can be permanently deleted from the
  mobile app. Images and videos show thumbnails (a video's poster frame about
  one second in, with its duration), built on the Mac by the paired
  `GET /api/v1/home/artifacts/{id}/thumbnail` route (JPEG of at most 600 pixels; 404
  for documents, audio or unreadable media). Sources get the remote-preview
  guards (regular single-link files below the artifact folder, every folder
  opened without following symlinks, 20 MB and 64-megapixel limits; videos decode
  from a private copy with a 15-second limit), and thumbnails are cached in
  `~/.cache/Cantrip/home/thumbnails/` until the file changes or is deleted.
  Cantrip must remain running for scheduled work.
- **Extensions:** dashboards, MCP tools, custom slash commands, and a
  `cantrip` command for asking questions from Terminal. With Copilot, MCP
  tools that return interactive views (such as Mobbin's screen galleries)
  render them inline in the chat, on the Mac and in Remote clients. See
  [MCP App views](docs/backends.md#interactive-mcp-app-views).

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

Cantrip Agent can opt in to per-Mac completion alerts with a short final-answer
preview and generic input-needed alerts with tap-to-tab navigation, including
while the phone is locked. Supported Copilot/Claude/ACP prompts can wait for
**Approve once / Deny** or an answer inline in Cantrip and Remote chat.
Ordinary questions use the normal composer (Auto delivery), including attachments;
only passwords and passphrases use the secure input modal. Input-needed alerts
still open the correct conversation. Verified system
OpenSSH and `sudo -A` children of supported Cantrip runs can request secure
password/passphrase input without putting it in chat. Use `/login github`
for GitHub device sign-in. See [remote input and limitations](docs/remote-control.md#remote-approvals-and-secure-input).
[Apple push setup](docs/remote-control.md#agentgateway-completion-notifications)
and new native phone/host builds are required; ordinary Remote polling is not
a background notification service.

**Mac Permissions & View Mac** adds user-initiated screen viewing and basic
pointer/keyboard control from Cantrip Agent and Mac/browser Remote. Enable
**Allow paired clients to view and control this Mac** locally first, with
Screen Recording and (for control) Accessibility permissions. Sessions expire
after five minutes or 60 seconds without activity; the Mac can end them from
its panel or menu bar. New screen frames and desktop input are not saved or
sent to models. Cantrip Agent requires Face ID/Touch ID for approvals, secure input
and starting View Mac, not ordinary chat replies; this is an app-side safeguard, not macOS
authorization. See [Mac attention and biometrics](docs/remote-control.md#mac-attention-view-mac-and-face-id).

## Learn more

| Task | Guide |
|---|---|
| Choose a backend or local model | [Backend setup](docs/backends.md) |
| Launch apps, run commands, or use voice/CLI | [Everyday tasks](docs/everyday-tasks.md) |
| Attach files, screenshots, or selected text | [Files and screen context](docs/files-and-screen-context.md) |
| Resume work or compare models | [Sessions and council](docs/sessions-and-council.md) |
| Pair Cantrip Agent, send photos, or connect another Mac | [Remote control](docs/remote-control.md) |
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
Mac and Windows apps and the Cantrip Agent iOS companion.

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
