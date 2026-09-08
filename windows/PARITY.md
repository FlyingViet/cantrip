# macOS / Windows Feature Parity

This is the acceptance checklist for bringing
[`FlyingViet/cantrip`](https://github.com/FlyingViet/cantrip) to Windows.
“Implemented” means the Windows-native behavior is tested; it does not require
using the same operating-system API.

## Current status

| Subsystem | Status | Windows implementation / remaining gap |
|---|---|---|
| Global summon shortcut | Partial | Alt+Space with conflict reporting, Ctrl+Space fallback, and retry. Selected-text shortcut remains. |
| App search and launch | Partial | Start Menu and WindowsApps discovery with fuzzy matching. Icons and running-window activation remain. |
| Math and unit conversions | Implemented | Local parser; no model round-trip. |
| Raw shell | Partial | Explicit `!` PowerShell commands work; persistent per-session ConPTY terminal remains. |
| Claude / Copilot / Codex | Partial | Detection, safe/action modes, model, effort, context, cancellation, and raw streaming work. Structured events and conversation resume remain. |
| Settings | Implemented for current features | Per-backend configuration, opacity, launch at login, action policy, shortcut status. |
| In-app updates | Implemented; release bootstrap required | GitHub Releases checks, download progress, restart-to-install, tray controls, and release workflow. Repository and signed releases must be published. |
| File search | Missing | Use Windows Search API, with optional Everything integration. |
| Session tabs and history | Missing | Persist per-tab backend, workdir, transcript, and open/archive state. macOS also supports persistent custom tab names and close/reset locks shared with Remote and AgentGateway. |
| Durable run journal | Missing | Port macOS's append-only event log, queue claims, partial-output/tool replay, retention, and run inspection to the main process. |
| Backend continuity | Missing | Capture backend session IDs and use Claude/Copilot/Codex resume flags. |
| Persistent terminal | Missing | Use ConPTY (`node-pty`) per session with state/history/Ctrl-C. |
| Local OpenAI-compatible backend | Missing | Stream `/v1/chat/completions`; add approved shell/MCP tool loop. |
| Attachments and screen context | Partial | Multi-monitor screen capture, previews, backend delivery, and transient cleanup are implemented. Clipboard/drop files remain. |
| Remote image uploads | Missing | macOS accepts bounded authenticated AgentGateway photo/screenshot uploads, with session capability discovery and durable image files for queued/recovered prompts. |
| Remote route recovery | Missing | macOS prefers saved Tailscale HTTPS with bounded reads, uses LAN as backup, and requires two successful recovery probes before restoring Tailscale; healthy Tailscale never probes/promotes LAN. A stable web bridge retains drafts and coalesces refreshes; late failures cannot displace a newer healthy route. All-down reads retry without a cooldown lockout. LAN-only and Tailscale-only modes remain supported; uncertain mutations are never automatically replayed. |
| Selected-text capture | Missing | Windows UI Automation or guarded clipboard capture. |
| Git actions/diffs/revert | Missing | Git status, staged-diff commit prompt, diff renderer, explicit revert. |
| Notifications | Missing | Windows Action Center notifications for background completion. |
| Mid-flight queue/redirect/inject | Missing | Queue and restart-with-context; Claude streaming input where supported. macOS also exposes ordered queued prompt IDs/text and durable stable-ID queue removal through authenticated Remote APIs for AgentGateway. |
| Content-aware Auto sending | Missing | macOS defaults to a bounded, tool-free message classifier for Copilot, Claude and local models. Conservative queue fallback, manual overrides, and shared Remote/iOS decisions; no Windows router yet. |
| Memory and file RAG | Missing | Markdown vault plus Windows Search/local semantic retrieval. |
| Long-prompt responsiveness | Missing | macOS bypasses launcher suggestions for large pastes, prepares memory context and encodes Remote responses off the UI thread, bounds retrieval terms, and displays paged full-text prompt previews in Mac/Remote. Prompt content is not truncated. |
| MCP and plugins | Partial | Compatible manifests, hash approvals, sandbox dashboards, bounded data sources, Claude/Codex MCP merge, and live reload are implemented. Local-model MCP client, Copilot injection, daily briefing, and in-window side panes remain. |
| Council mode | Missing | Parallel read-only seats and one active chair synthesis. |
| CLI bridge | Missing | Named pipe server plus installed `cantrip` command. |
| Usage dashboard | Missing | Claude CLI figures and Copilot billing API. |
| Voice | Missing | Windows speech recognition and SAPI/WinRT synthesis. |
| Crash recovery | Missing | Version/crash journal, relaunch, visible recovery, loop breaker. |
| Tutorial overlays | Missing | UI Automation bounds plus one overlay window per display. |
| Skills | Missing | `%APPDATA%\Cantrip\commands`, descriptions, and `/name` typeahead. |

## Delivery phases

### P0 — trustworthy core loop

1. Session tabs with independent backend, model, working directory, and run.
2. Native backend session continuity verified by a three-turn memory test.
3. Backend-specific JSON stream parsing for text, reasoning, tools, and errors.
4. Persistent ConPTY PowerShell per tab with `cd`/environment/history and Ctrl-C.

**Exit criteria:** three concurrent tabs retain separate agent and shell state
across restart; UI never labels a one-shot process as a persistent session.

### P1 — everyday Mac parity

1. Windows Search file results under a 150 ms warm typeahead budget.
2. Paste/drop attachments and opt-in screen context.
3. selected-text summon shortcut using Windows UI Automation.
4. Local OpenAI-compatible streaming backend.
5. Git status, diffs, safe revert, and background completion notifications.
6. Queue plus interrupt/redirect for active runs.

**Exit criteria:** each feature has an integration test or a reproducible
Windows smoke test, and privileged context is visibly opt-in.

### P2 — advanced platform

1. Markdown memory vault, RAG, and consolidation.
2. MCP client and manifest-approved sandboxed plugins.
3. Named-pipe CLI bridge.
4. Usage dashboard and crash recovery.
5. Verify signed in-app updates from one published version to the next.

### P3 — differentiators and polish

Council mode, multi-monitor tutorial overlays, skills, persisted panel geometry,
and independently resizable side panes.

## Platform substitutions

| macOS API | Windows equivalent |
|---|---|
| Spotlight / `mdfind` | Windows Search (`ISearchQueryHelper`) or Everything |
| Accessibility selection | Windows UI Automation |
| ScreenCaptureKit | Electron `desktopCapturer` / Windows Graphics Capture |
| EventKit / Calendar automation | Outlook COM or Microsoft Graph |
| Login Items | Electron `app.setLoginItemSettings` |
| Menu bar notifications | Windows tray and Action Center |
| Unix domain CLI socket | Windows named pipe |
| PTY shell | Windows ConPTY |
