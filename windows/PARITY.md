# macOS / Windows Feature Parity

This is the acceptance checklist for bringing
[`FlyingViet/cantrip`](https://github.com/FlyingViet/cantrip) to Windows.
“Implemented” means the Windows-native behavior is tested; it does not require
using the same operating-system API.

## Current status

macOS packaging builds Universal `arm64` + `x86_64` binaries and rejects
incompatible bundled native components before replacing the app, avoiding a
Rosetta dependency on Apple silicon. The gate also checks each slice's macOS
deployment target against the bundle metadata and preserves macOS 14 support.
macOS 26 is supported; Xcode 27 builds retain that minimum, with macOS 27 runtime
confirmation pending. This does not change the Windows x64
target or certify separately installed backend runtimes on either platform.

| Subsystem | Status | Windows implementation / remaining gap |
|---|---|---|
| Global summon shortcut | Partial | Alt+Space with conflict reporting, Ctrl+Space fallback, and retry. Selected-text shortcut remains. |
| App search and launch | Partial | Start Menu and WindowsApps discovery with fuzzy matching. Icons and running-window activation remain. |
| Math and unit conversions | Implemented | Local parser; no model round-trip. |
| Raw shell | Partial | Explicit `!` PowerShell commands work; persistent per-session ConPTY terminal remains. |
| Claude / Copilot / Codex / Antigravity | Partial | Detection, safe/action modes, model, effort, context, cancellation, and raw streaming work. Windows still runs `codex exec` with a fixed model list; macOS runs `codex app-server` with per-call approvals, resume, steering and `model/list`. Antigravity runs only with actions on: headless `agy` edits workspace files without asking, and Windows has no tool-call hook yet. Structured events and conversation resume remain. |
| Settings | Implemented for current features | Per-backend configuration, opacity, launch at login, action policy, shortcut status. |
| In-app updates | Implemented; release bootstrap required | Checks the newest `windows-v*` GitHub release, download progress, restart-to-install, tray controls, and release workflow. A first release (and signing) must be published. |
| File search | Missing | Use Windows Search API, with optional Everything integration. |
| Session tabs and history | Missing | Persist per-tab backend, workdir, transcript, and open/archive state. macOS also supports persistent custom tab names, close/reset locks, and drag/menu tab reordering shared with Remote and AgentGateway; order is host-authoritative and preserves the selected conversation. Native tab mouse handling prevents accidental window drags. AgentGateway uses animated native list reordering and keeps its drawer open while saving. Mac Remote uses an expanded, vertically scrollable left tab list, with pulsing-brain activity/queue indicators and pinned selected-session status; disconnected activity is explicitly stale and animations respect Reduce Motion. Main Cantrip and browser tabs remain across the top. Remote lists preserve position during polling and reveal newly selected tabs. |
| Durable run journal | Missing | Port macOS's ordered background event writer, durable completion/queue claims, explicit storage failures, partial-output/tool replay, compaction of finished runs, retention, and run inspection to the main process. |
| Backend continuity | Missing | Capture backend session IDs and use Claude/Copilot/Codex resume flags. |
| Usage limit fallback | Missing | macOS recognizes a backend's plan usage-limit error from its structured fields (Copilot `session.error` `quota`/`rate_limit`, Claude `rate_limit`/`billing_error` and `rejected` rate-limit events), Codex `codexErrorInfo` `usageLimitExceeded`/`rateLimitExceeded` from its app server), with known phrases only as a last resort (Gemini quotas), but not a full context window, continues the run on the first backup in Settings' ordered chain (`limitFallbackEntries`: any number of backend, model and effort entries, a backend listed again with another model, off by default) that isn't at its limit too, moves down the chain each time another backup hits its limit, and sends every tab's new messages there until the error's reset time or for an hour. Limits are kept per model where the backend's quotas are (Antigravity model groups, Claude's weekly Opus/Sonnet limits), so a used-up model moves the run to the same backend's next model; shared quotas skip the whole backend. Council seats and Private Local don't switch; the run stops once every backup is limited; unattended Home runs skip Copilot Remote in the chain. Paired clients read and set it, and clear limits, through `/api/v1/usage-fallback`: the browser/Mac Remote, Cantrip Agent and Gateway Mac/Windows all add, reorder and remove backups (`backends`) and pick each backup's model and effort from its backend's list (`entries`, `limitFallbackModels`; a model no longer offered runs the default and the run's note says so), and fall back to the single `backend` with Macs from before the chain. Depends on structured error events and resume. |
| Idle runtime memory release | Missing | macOS stops a tab's idle Copilot runtime after a configurable delay (30 minutes by default) and resumes its session on the next prompt. It keeps runtimes with running agents, shell commands or scripts; MCP servers alone don't count. Depends on backend continuity. |
| Relaunch and network continuity | Missing | After a relaunch, macOS resumes each tab's interrupted run (automatically at most twice per run) and then sends its restored queue. Runs that fail in a conversation (errors, timeouts, network drops) stop on their error message with **Continue**, and the queue waits behind them; Send now skips one, and Continue on an earlier failed message continues it as a new run. Child tabs and Home handoff tabs wait for the network and continue by themselves; queued messages don't send while offline. |
| Persistent terminal | Missing | Use ConPTY (`node-pty`) per session with state/history/Ctrl-C. |
| Local OpenAI-compatible backend | Missing | Stream `/v1/chat/completions`; add approved shell/MCP tool loop. |
| Persistent Private Local tab | Missing | macOS and AgentGateway share a permanent saved self-hosted-model tab. Ollama may run on another machine via HTTPS (LAN/Tailscale hostnames and reverse-proxy base paths); HTTP is loopback-only. Idle/revision-guarded endpoint/model/context/system-prompt settings and model preflight; no cloud fallback, tools, shared-memory logging, push summaries or external-content fetching. Remote access and history stay on the Cantrip Mac. Separate from unsaved Private mode. |
| Attachments and screen context | Partial | Multi-monitor screen capture, previews, backend delivery, and transient cleanup are implemented. Clipboard/drop files remain. |
| Remote image uploads | Missing | macOS accepts bounded authenticated AgentGateway photo/screenshot uploads, with session capability discovery and durable image files for queued/recovered prompts. Session-scoped authenticated image/thumbnail reads let AgentGateway show tappable previews without exposing arbitrary Mac files. |
| Remote model settings | Missing | macOS local tabs, Mac/browser Remote and AgentGateway share persisted per-tab Copilot model/effort/context and Claude Code, Codex and Antigravity model/effort overrides (kept per backend) and a Mac-defaults reset. Host catalog validates supported combinations; idle-only, revision-guarded saves preserve transcripts and other tabs. Council and ACP remain separate. |
| Remote video analysis | Missing | macOS accepts paired resumable MOV/MP4 uploads from AgentGateway (one clip, 100 MB / five minutes), verifies SHA256, retains the original, and supplies four oriented timestamped frames plus a file path for deeper tool analysis. Audio is retained but not automatically transcribed. Final prompts are not replayed after uncertain delivery. |
| Remote route recovery | Missing | macOS prefers saved Tailscale HTTPS with bounded reads, uses LAN as backup, and requires two successful recovery probes before restoring Tailscale; healthy Tailscale never probes/promotes LAN. A stable web bridge retains drafts and coalesces refreshes; late failures cannot displace a newer healthy route. All-down reads retry without a cooldown lockout. LAN-only and Tailscale-only modes remain supported; uncertain mutations are never automatically replayed. |
| Remote host diagnostics | Missing | macOS separates network-queue liveness from authenticated session readiness, records content-free request-stage timings and numeric response-write errors, and bounds stalled response sends. Fast health alone never establishes client session readiness. |
| Remote history loading | Missing | macOS serves opt-in recent-message pages with complete text, reasoning, and tool details, revision-based conditional reads, and stable older-history cursors. AgentGateway and Mac/browser Remote load older pages only on request, with idle polling backoff, cached history, and independent tab-list/conversation error state. Soft page/cache boundaries retain the first response's user prompt and intervening responses; budgets never truncate messages or orphan their prompts. Old full-snapshot clients remain compatible. |
| Selected-text capture | Missing | Windows UI Automation or guarded clipboard capture. |
| Git actions/diffs/revert | Missing | Git status, staged-diff commit prompt, diff renderer, explicit revert. |
| Notifications | Missing | Windows Action Center notifications for background completion. |
| AgentGateway completion push | Missing | macOS provides opt-in paired device registration, durable completion dedup/queue and direct APNs delivery of final-answer previews. Requires a host APNs key and newly provisioned AgentGateway build; no success alerts for private, cancelled or failed runs. |
| Remote input and attention alerts | Missing | macOS, web Remote and AgentGateway share single-use expiring tool approvals, questions, verified OS SSH/sudo askpass and explicit GitHub device login. Secrets bypass chat/journals; generic opt-in APNs attention alerts contain no request contents. Mac OS authorization dialogs are not bypassed. |
| View Mac and biometric client approval | Missing | macOS offers locally enabled, time-limited ScreenCaptureKit view/basic CGEvent control with in-memory AES-GCM frames/input, recent-frame and replay guards, local Stop and permission-attention status. AgentGateway requires Face ID/Touch ID for affirmative input and starting a viewer. This does not grant TCC, unlock Mac Keychain items or replace Mac biometrics. |
| Mid-flight queue/redirect/inject | Missing | Mac: persistent native Copilot SDK sessions with immediate steering, Claude streaming input, separate queue/redirect/stop, durable ordered context delivery and no blind resend after lost acknowledgements. Existing AgentGateway/Mac/browser Remote Inject controls share the host implementation. Ordered queued prompt IDs/text and durable stable-ID removal remain available. A queued prompt can also be sent now: it joins the live turn (Copilot moves a blocking step to the background) or redirects. |
| Content-aware Auto sending | Missing | macOS defaults to a bounded, tool-free message classifier for Copilot, Claude and local models. Conservative queue fallback, manual overrides, and shared Remote/iOS decisions; no Windows router yet. |
| OpenAI-compatible API | Missing | macOS serves `/v1/chat/completions`, `/v1/models` and `/health` on loopback (off by default) for other apps: each request is one stateless, tool-free call through the Mac's backend and usage-limit backup chain (Codex and Copilot Remote skipped), images go to Copilot and Claude natively, a structured limit error marks the backend limited and moves on, 429 with `Retry-After` when every backend is limited, calls counted per consumer (`/consumer/NAME/v1`) on the usage screen, `cantrip api` and the paired usage API (`endpoint`). Proxied requests need a Keychain-stored key. |
| Memory and file RAG | Missing | Markdown vault plus Windows Search/local semantic retrieval. |
| Long-prompt responsiveness | Missing | macOS bypasses launcher suggestions for large pastes, prepares memory context and encodes Remote responses off the UI thread, bounds retrieval terms, and displays paged full-text prompt previews in Mac/Remote. Prompt content is not truncated. |
| MCP and plugins | Partial | Compatible manifests, hash approvals, sandbox dashboards, bounded data sources, Claude/Codex MCP merge, and live reload are implemented. Local-model MCP client, Copilot injection, daily briefing, and in-window side panes remain. macOS also renders Copilot MCP App (SEP-1865) tool views inline in isolated, CSP-restricted web views, proxies same-server calls through the session, and asks before a view posts a message; the browser Remote (opaque-origin frames from single-use addresses) and Cantrip Agent render them too. Windows has no MCP App renderer yet. |
| Council mode | Missing | Parallel read-only seats and one active chair synthesis. |
| CLI bridge | Missing | Named pipe server plus installed `cantrip` command. |
| Shared MCP servers | Partial | macOS hosts the shared list, Keychain sign-ins and the relay. Gateway for Windows shows the Mac's servers, connects them, approves sign-in pages and switches servers per backend or tab (MCP Servers in the toolbar and tab menus). The Windows app has no shared MCP list of its own. |
| Shared build caches | Missing | macOS: child-tab worktrees start with copy-on-write clones (APFS `clonefile`) of another checkout's `node_modules`, `Pods` and `.spm` where lockfiles match and the install is current (`cantrip seed-worktree`); the daily cleanup removes stale DerivedData and SwiftPM checkouts and caps the SwiftPM, npm, pnpm, CocoaPods and Gradle caches; the `buildRoot` setting exports `CANTRIP_BUILD_ROOT` so builds can use a build disk with a local fallback. Windows would need ReFS block cloning or hardlinks for the seeding. |
| Shared simulators | Not applicable | macOS: tabs lease iOS simulators from a pool (`cantrip sim acquire` / `release`), get a temporary copy while another tab holds one, and the daily cleanup tidies simulators. Windows has no iOS simulators. |
| Tab insight | Missing | macOS: a parent tab's model gets a live status line per child tab with each message; models and Home read any non-private tab's recent turns on demand (`cantrip tab list` / `read`) and ask a tab a question that runs as a turn there, with the reply back as a card (`cantrip tab ask`, `--steer` for a running child). Private, Private Local and Home background conversations are never exposed. Depends on session tabs, child tabs and the CLI bridge. |
| Auto-fork for queued messages | Missing | macOS: independent queued messages (Auto delivery, paired-device queues, Home handoffs without a dependency) start in child tabs on their own, several per pass, up to configurable caps (3 per tab, 4 overall) and only while the Mac has CPU, disk and Simulator room; messages that depend on one follow it into its child's queue. Each waiting row says why, on every client, through the plan's `reason` (and `autoFork`), and **Run in child tab** overrides. Depends on child tabs and queue plans. |
| Home handoffs in child tabs | Missing | macOS: a Cantrip Home handoff whose queued request moves into a child tab (Run in Child Tab or auto-fork) follows it there, reports the child's reply, then its merge outcome; discarding or closing the child says so, and Run in This Tab Instead returns it to the parent's queue. Depends on Cantrip Home, session tabs and child tabs. Remote clients: the browser labels the cards *in child tab*; Cantrip Agent, Cantrip Gateway Mac and Cantrip Gateway for Windows show the child's title and merge line with their usual *in tab* labels. |
| Tab mentions | Missing | macOS, the browser Remote, Cantrip Agent and Cantrip Gateway (Mac and Windows) suggest open, non-private tabs when `@` starts a word and send a picked one as `@[Label](cantrip-tab:<ID>)`; the host tells the model to read, ask or (in Home) hand off to exactly that tab. Depends on tab insight. |
| Usage dashboard | Missing | Mac: Claude CLI figures and Copilot account SDK AI credits used/total, secondary percentages, reset/overage; Antigravity's weekly and 5-hour limits per model group from `agy -p /usage` (no quota spent), where a full window of the group the Mac's model runs on moves new messages to the usage-limit fallback; Codex's 5-hour and weekly (free plan: 30-day) limits from `codex app-server` `account/rateLimits/read`, kept current by running tabs, where a full window does the same; paired read-only API for AgentGateway. |
| GitHub build monitor | Missing | macOS provides a pairing-authenticated, read-only cached GitHub Actions dashboard for AgentGateway, scoped by configured repository/runner registrations. GitHub credentials remain on the Mac. |
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
