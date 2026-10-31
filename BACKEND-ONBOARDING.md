# Onboarding a new AI backend

Read this before adding a backend (a new agent CLI, SDK or API) to Cantrip, or before
deepening support for one that only half works. It is written for the coding agent doing the
work as much as for people: follow it in order and finish the checklist at the end.

A backend is "onboarded" only when every Cantrip feature that the backend *can* support works
through it, on every surface, and the features it can't support fail clearly. Launching the
CLI and streaming text is the start, not the finish.

The guide collects what three onboardings taught. Each lesson names the commit that fixed it,
so `git show <sha>` gives the details.

- **Copilot** came first, so most features were built for it. Its lessons are mostly about
  the CLI's runtime: version changes, crashes, sign-ins and memory.
- **Claude Code** worked for months while silently missing those features: background agents,
  per-tab models, earlier turns, MCP servers and Home's protocol. They were added later in
  d1549c6 and bb39eeb.
- **Antigravity** (`agy`) first shipped streaming and tool checks (84827f8), and then needed
  about a dozen fixes to reach parity.

The lesson common to all three: **a feature built for one backend doesn't reach the others
unless someone checks.** Section 5 is that check.

User-facing setup for existing backends is in [docs/backends.md](docs/backends.md).

## 1. Investigate the CLI before writing code

Install the CLI, sign in, and answer each question from its `--help`, docs and real output.
Save sample output (JSON lines, errors) as test fixtures. Write down the CLI version you
tested: Copilot 1.0.88 changed when a turn counts as idle and when background agents start,
which broke queued messages and subagent cards until Cantrip caught up (a8df390, edd4aba).

| Question | Why Cantrip needs it | Claude Code | Copilot | Antigravity |
|---|---|---|---|---|
| Is there a headless, structured stream? | Text, reasoning, tool steps and errors must come from fields, not scraped terminal text. | `-p --input-format stream-json` plus a control protocol | SDK session through a Node bridge (`CopilotSessionBridge`); ACP for Copilot Remote | `--input-format`/`--output-format stream-json` |
| One process for many turns, or one per turn? | Process lifecycle, idle cleanup, mid-turn input. | Persistent per tab | Persistent runtime per tab (0.5 to 3 GB) | Persistent per tab |
| How do you resume, and is it tied to a folder? | Tabs survive restarts and folder changes. | `--resume <id>` | `resumeSession(id)` | `--conversation <id>`; tied to the starting folder |
| How do you stop a turn and keep the session? | Stop must keep the conversation. | `control_request` `interrupt` on stdin | `session.abort()` | `SIGINT` |
| Can a running turn take new messages? | Live steering and "send now". | Yes | Yes | No |
| How are models listed, without spending quota? | Pickers must show the account's real catalog. | `initialize` reply | Account models API, with efforts and context tiers | `agy models` |
| Which effort, reasoning or context options exist? | Per-tab and Home task model settings. | Effort | Reasoning effort, context tiers (from `--help` and the API) | `--effort low/medium/high` |
| How are usage limits reported, on error and on demand? | Usage limit fallback and the Usage Limits screens. | `rate_limit`/`billing_error` errors and a `rejected` rate-limit event with reset time; usage API | `session.error` `errorType`/`errorCode`; GitHub allowance endpoint | No error code; `agy -p /usage` |
| Can every tool call be checked before it runs? | Action policy, read-only council seats, Home guardrails. | `PreToolUse` hook and `--permission-prompt-tool stdio` | SDK `onPermissionRequest` | Global `PreToolUse` hook |
| What runs without asking when no permission flags are set? | You must know what escapes the check. | Its permission mode decides | Each tool asks through `onPermissionRequest` | File edits in the workspace |
| What is the safest native mode, for read-only seats? | Council advisors must not act. | `--permission-mode plan` | A read-only session with no tools | Cantrip's hook only allows reads |
| How are subagents and background work reported, and can one be stopped? | Subagent monitor, `watch-`/`side-` agents. | `task_started`, `background_tasks_changed`, `task_notification`; `stop_task` | `subagent.*` events; `tasks.cancel` | Steps plus transcript files |
| Where do MCP servers, skills and slash commands come from? | Slash command discovery, shared MCP servers. | `initialize` reply; its own MCP config | Throwaway SDK session (`commands.list`, `skills.list`); `~/.copilot/mcp-config.json` | Skill folders under `~/.gemini` |
| Where are its sign-ins stored? | Features must run the binary that owns the sign-in. | Login keychain | Keychain items of the signed CLI binary | CLI's own store |

If a question has no answer, mark the feature unsupported and make sure Cantrip says so
(for example `SubagentCancelError.unsupported`). Don't fake it.

## 2. Map Cantrip's features to the backend

Fill in this table for the new backend before wiring anything. Every row must end up either
working or deliberately unsupported with a clear message.

| Cantrip feature | What the backend must provide | Where Cantrip does it | Reference |
|---|---|---|---|
| Streaming reply | `BackendEvent`s: `.textDelta`, `.thinkingDelta`, `.status`, then exactly one `.done` or `.failure` | `Backends/Backend.swift` | every backend |
| Tool steps | `.activity(ToolActivity)` via `ToolActivityFactory`, with an honest final state | `Backend.swift`, the backend's parser | `ClaudeCodeBackend`, `AntigravityBackend` |
| Token usage and context | `.usage` per turn (convert cumulative totals to deltas), `.context` with the breakdown if reported | backend | b343e18; `AntigravityBackend.handleResult` |
| Conversation resume | Session ID under a per-tab `persistKey`; `reset()` clears it | `TabDefaults.swift`, `ChatSession.backendKeepsSession` | all CLI backends |
| Earlier turns | Replay the turns the backend's own session hasn't seen | backend | bb39eeb |
| Stop | `cancel()`; `interruptTurn()` when the session survives | backend | b74702b |
| Live steering | `injectMidTurn`, `sendNowMidTurn`, `supportsMidTurnInjection`, `canSteerTurns` | backend | 553237b, a8df390 |
| Action policy | Every tool call checked; asks through `.inputRequired`; read-only seats only look | `CantripHomeGuardrails.swift` | `AntigravityHook.swift`, Claude's `PreToolUse` hook |
| Cantrip Home | `CantripHomeGuardedBackend`, `CantripHomeApproval.chosen(for:)` | `CantripHomeGuardrails.swift` | fd7faaa, d774fe6 |
| Per-tab model and effort | Model catalog, `modelOverride`, `effortOverride` | `ClaudeModels.swift`, `SessionTabMetadata.swift`, `SessionModelSettings*.swift` | c480a60, d1549c6, a1e4a83 |
| Home task models | Model list for task settings | `CantripHomeTaskModels.swift` | 5062f5b |
| Child tabs | Inherit the parent's model; shared Simulator/build turns enforced in the tool check | `ChildTabCoordinator.swift`, `ChildTabResources.swift` | d1549c6 |
| Council seats | Own session per seat and model; safest native mode | `ChatSession` council setup, `TabDefaults.council*` | 1c1b362, 6dd4ee5 |
| Usage limit fallback | `.usageLimit(UsageLimitReport)` from a structured code, sent just before `.failure` | `BackendLimits.swift`, `ChatSession` | 825fcfb, 86abf76 |
| Usage Limits screens | Quota used and reset times, read without spending quota | `UsageTracker.swift`, `CopilotUsage.swift`, `CopilotUsageView.swift`, `QuotaFetcher.swift` | 5c08fdc, 3a04b3f |
| Auto routing, queue plans, Done-when checks | A tool-free, fast one-shot call | `MessageRouter.swift`, `ChatSession.routerProvider` | daa63fe |
| Memory consolidation (optional) | Same one-shot call, with write limits | `ConsolidationPolicy.swift`, `Consolidator.swift` | 6b2942f, 291336e |
| Slash commands and skills | Built-ins plus discovered skills | `BackendCommands.swift`, `BackendCommandDiscovery.swift`, `BackendCommandCatalog.swift` | 2a2272c |
| Subagent monitor | `ToolActivity.subagent` (`SubagentInfo`); `canCancel` only if it really can | `SubagentMonitorView.swift`, `RemoteHistory.swift` | c70aaa8, edd4aba, 21b114d |
| Background watchers and parallel requests | `watch-*` and `side-*` background agents, `.backgroundWake`, `supportsParallelSubagents` | backend system guidance | 29f4f46, d1549c6 |
| Long commands | `.heartbeat` while a step runs without output | backend | 751f6eb |
| Idle memory release | Stop an idle process; resume on the next message | backend, `Settings` idle delay | e3ace30 |
| Attachments and screen captures | Files staged where the CLI can read them | backend | `AntigravityBackend.stagePromptAttachments` |
| Shared MCP servers | Pass Cantrip's or Copilot's local MCP servers to the CLI | `ClaudeSharedMCP.swift` | bb39eeb, c9a0739 |
| `cantrip tab ask`/`read` | `CANTRIP_TAB_ID` in the agent's environment (`tabID` set by `ChatSession`) | `TabInsight.swift` | 0b9c00a |
| `sudo`/`ssh` prompts | `RemoteAskpass` broker on the child process | `RemoteAskpass.swift` | 087f1c5 |
| Reply visibility | `ReplyVisibility.guidance` in the session's system message | `Backend.swift` | f3ca958, 05b8c08 |
| Terminal CLI | `cantrip ask --backend <name>` aliases | `CLIServer.swift`, `HostControl.swift` | 84827f8 |

Context such as memory, location, calendar, files, screen and continuity is added to
`request.prompt` by `ChatSession.composeContext` and `prepareMemory`, so a backend gets it
without extra work and must not add it again.

## 3. Wire it in on macOS

Add the backend in this order. Many `switch` statements over `BackendKind` have a `default:`
branch that quietly treats an unknown backend as Copilot, so the compiler won't list them all.
Search for an existing backend and decide each hit by hand:

```sh
grep -rn "\.antigravity\b" Sources Tests windows/src
grep -rn "default:" Sources/Cantrip/ClaudeModels.swift Sources/Cantrip/SessionModelSettings.swift
```

1. **Kind and settings.** Add a case to `BackendKind` in `Settings.swift`. Add settings for the
   path, model, effort and permission mode, plus the model catalog with its refresh error and
   in-flight state. Find the executable through `ToolLocator` (see section 4, "Launching").
2. **Backend class** in `Sources/Cantrip/Backends/<Name>Backend.swift` that conforms to
   `Backend`, and to `CantripHomeGuardedBackend` if it can check tools. Take `persistKey`,
   `readOnly`, `modelOverride` and `effortOverride` in its initializer, like `AntigravityBackend`.
3. **Sessions.** In `ChatSession`, create the instance with a `TabDefaults` key and add it to the
   backend switch, the guarded-backend lists, `reset`, `backendKeepsSession` and the per-tab
   model override block. Set `tabID`. Add council seat keys in `TabDefaults` and include them in
   its cleanup.
4. **Models.** Add a `<Name>Models.swift` loader, the catalog in `ClaudeModels.swift`
   (`tabModelBackends`, `tabModelCatalog`, `tabModelDefaults`, `refreshTabModels*`), a field in
   `SessionTabMetadata`, labels in `SessionModelSettingsView`, `CantripHomeTaskModels`, and
   inheritance in `ChildTabCoordinator`. Refresh at launch in `AppDelegate` when installed.
5. **Policy.** Add the backend to `CantripHomeApproval.chosen(for:)`, plus a
   `CantripHomeActionRequest` initializer that converts its tool calls. If tools can't be checked
   one at a time, Home must not run unattended on it (see `BackendFallback.target`, which keeps
   Home runs off Codex and Copilot Remote).
6. **Limits and usage.** Emit `.usageLimit` from the CLI's structured error, and add phrases to
   `UsageLimit.phrases` only as a last resort. Add a usage reader and state to
   `UsageTracker`/`CopilotUsage`, and a view in `CopilotUsageView` shown from `LauncherView`.
7. **Routing.** Add a `MessageRouter.Provider` case and a `routerProvider` branch, or return
   `.unavailable` with a reason.
8. **Commands.** Add a `BackendCommandFamily` case, built-ins in `BackendCommands`, discovery in
   `BackendCommandDiscovery` (skill folders, `cliNames`), and the catalog key.
9. **UI.** Settings section, icon, model labels and council menu in `LauncherView`; also
   `PluginPanelData`, `AppSettings.backendLabel`, and the aliases in `CLIServer` and `HostControl`
   (the `limitFallbackBackends` names and error text).
10. **Hooks or helpers** that the CLI runs as a separate program dispatch from `main.swift`
    (see `AntigravityHook.helperArgument`).

## 4. Behaviour rules

Each rule below was broken by at least one backend first. Check each one with a test or a
live run.

**Launching**
- Every feature runs the same binary. Copilot was once found four different ways, so tabs,
  the model list, routing and memory upkeep could run different installs. Use
  `ToolLocator.shared`, which accepts only absolute executable paths and doesn't cache misses,
  so a CLI installed later is found (a22565a).
- Run the signed CLI binary, not a per-version runtime inside it. Copilot's runtime path changed
  with every self-update, and the keychain sign-ins it saved belonged to a path that no longer
  existed (5044094). MCP OAuth sign-ins only work from the binary that saved them (c9a0739).
- Build the child's PATH with `ToolPath`, which keeps the caller's order and adds only the
  missing tool folders (91af48f).
- Read a helper command's output while it runs (`ProcessRunner`). A pipe holds 64 KB, and a
  command that prints more never exits (6b34f7c).

**Turns**
- Send exactly one `.done` or `.failure` per turn. After a cancel, a dying process must not send
  events into the next run, which SIGKILL can reach seconds late (e4fae56). After an in-band
  interrupt, drop the stopped turn's trailing events (b74702b).
- Stop in-band when the CLI allows it, so the process and session stay warm (Claude's
  `control_request`, b74702b).
- Send `.heartbeat` for progress-only events. A Claude build that sent only `tool_progress` for
  15 minutes was killed by the inactivity watchdog (751f6eb).
- A turn that stops on a limit error ends as a failure, not a reply (86abf76).
- Detect a dead runtime instead of waiting for a timeout. If nothing reached the user yet,
  replace the runtime once and resend, resuming the same session. Copilot runtimes crashed
  after 9 to 19 idle hours, so they are restarted after 2 idle hours (8998bf1).
- Free an idle tab's process after the **Free an idle tab's memory** delay, keeping one with
  running agents or commands, and resume the session on the next message (e3ace30, d1549c6).

**Sessions and folders**
- Store the session ID per tab, council seat and model, never globally (6dd4ee5).
- If the CLI ties a conversation to a folder, record the folder with the session. When a tab's
  folder changes (folder picker, or a child tab returning to its parent), start a fresh
  conversation in the new folder (200c958).
- A launch signature (folder, model, effort, permission mode, guardrail) decides when the
  persistent process must restart. A model change resumes the same conversation (d1549c6).
- A backend that keeps its own session still needs the turns it hasn't seen: a tab that ran on
  another backend, a new or lost session, or turns another backend answered. Count what the
  session has seen and add only the rest (bb39eeb).

**Prompts and agent guidance**
- Put fixed instructions (Home's protocol) in the session's system instructions once, and send
  only per-turn data with each message. On Copilot this cut a Home message from about 117K to
  21K characters, and compaction can't drop it (8b3cd70).
- Add `ReplyVisibility.guidance` and `RemoteGeneratedImages.agentGuidance` to the system
  message (f3ca958). Check where the model's text before a tool call ends up: through Copilot,
  Claude's "narration" blocks arrived only as reasoning, so 101 notes went missing in one
  session until they were shown as reply text (05b8c08).
- If the backend runs background agents, add the `watch-`/`side-` conventions in its own terms
  (see `ClaudeCodeBackend` and `CopilotBackend`).
- Slash commands reach the backend exactly as typed, with no memory or context added. Refuse
  commands that bypass Cantrip's approvals or break remotely, including aliases. Map the CLI's
  `/model` to the tab's model settings and its `/clear` to Start fresh (2a2272c).
- Set `CANTRIP_TAB_ID` and attach `RemoteAskpass` to the child process.
- Rewrite internal links the CLI prints that Cantrip's apps can't open into plain labels
  (`TabMentions`, for `conversation://`).

**Tool steps**
- A command the policy refused, or that the CLI reports as failed, ends as `.failed` with the
  reason, never "succeeded" (ec168a6).
- Unfinished steps and subagents end when the turn ends (`ToolActivity.finishing`).
- Give each step a readable title and, for edits, a diff. If the CLI's tool names are new, add
  them to `ToolActivityFactory` (`displayName`, `fileChanges`, `terminalCommand`).

**Subagents and background work**
- Show a subagent's card when it is launched, not when it starts. Copilot 1.0.88 queues
  background agents, which stayed invisible until then (edd4aba).
- Nest a subagent's steps under it, keep its text out of the reply, and don't let its idle or
  error end the root turn (10af9aa).
- When the root turn ends with background agents still running, keep the run open, take new
  messages, and treat the CLI's own wake-up turn as the run's continuation. Claude's background
  agents once stayed "running" forever (d1549c6, a8df390).
- To turn subagents off, remove their tools from the session instead of asking the model not to
  use them; that also saves their tokens (10af9aa).
- Set `canCancel` only when the backend can stop that one agent (c70aaa8).

**Permissions** (never weaker than Cantrip's policy; see CLAUDE.md)
- With **Act on my behalf** off, every tool call is checked before it runs. A permission
  request the current policy can't approve is denied, not left waiting.
- Read-only council seats run the backend's safest native mode, and Cantrip still denies
  anything that isn't a read, even if the server would allow it (1c1b362, ec439d1).
- Cantrip Home's rules are enforced on the host for every backend, and follow the approval
  mode chosen for that backend. A backend whose tool calls Cantrip can't see fails closed for
  unattended runs (fd7faaa, d774fe6).
- Don't write config into the user's projects. If the CLI only reads hooks from a project or a
  global file, add one Cantrip entry to the global file that does nothing for runs Cantrip
  didn't start (03acc10).
- Count the CLI's tool steps against the checks it asked for. If a tool ran without the check,
  stop the session (03acc10).
- Check text sent into a running task the same way as a command (19ce907).
- Where a platform has no way to check tools (Windows `agy` today), refuse to run without
  actions on rather than run unchecked (7089526).

**Models**
- List models from the CLI or API, never by calling a model, and never ship a guessed list.
  Refresh at launch, when a picker opens with a list older than six hours, and from the refresh
  button. A failed refresh keeps the previous list and shows the error (e39ede5).
- Keep the metadata the catalog returns (context window, efforts, context tiers), not just IDs
  (8f8c107). Offer every effort or tier the CLI's help, the API or the current setting accepts,
  so narrowing never hides a working option (acd945a).
- Keep per-tab overrides per backend, because model IDs differ (d1549c6, a1e4a83). An
  unsupported saved value stays visible with a warning; don't reset it silently.
- A Home task whose model isn't available runs on Home's model and its summary says so
  (5062f5b).
- Automatic model tiering (a small model for small tasks) applies only when the user left the
  model on default or auto. A model the user picked is used as picked (c768334).

**Usage limits**
- Detect limits from the CLI's error code or field, not its wording, and make sure any bridge
  passes those fields through: the Copilot bridge dropped them, so a monthly quota error never
  triggered the fallback (825fcfb). Send `.usageLimit` with the reset time just before
  `.failure`.
- Work out reset times the error leaves out. Copilot's monthly allowance resets on the 1st at
  00:00 UTC, so retrying hourly would fail all month (825fcfb).
- Read limits directly and cheaply every five minutes, without spending quota and without
  refreshing the user's sign-in: Claude's usage API with Claude Code's keychain sign-in (read
  only), GitHub's allowance endpoint with the `gh` sign-in. Keep a slower fallback reader, and
  test that both agree (5c08fdc).
- When the window the current model uses is full, mark the backend limited so new messages go
  to the fallback before the backend refuses one (5c08fdc, 3a04b3f).
- In the Usage Limits screens, show only how much of each quota is used and when it resets
  (used, not remaining: a2832b6). Add the section to the paired usage API so remote clients
  show it too.

**Routing and other helper calls**
- Router calls must be tool-free: block tools outright, or the model may try a command, get
  refused and return nothing.
- Time out after the CLI's real startup time plus the answer, measured live (`agy` takes 5 to
  11 seconds to start, so it gets 25 seconds). Measure the success rate over about 20 live
  tries (daa63fe).
- If a helper call would send the user's messages or memory to a provider they didn't choose
  for that tab, make it an opt-in setting that is off by default (291336e).

**Privacy**
- Private Local tabs never reach a cloud backend. Private tabs follow `MemoryStore`'s rules.
  Never log prompts, secrets or tokens. Secrets the agent asks for use the secure prompt, never
  the chat (eed73f0).

## 5. Parity sweep

Run this when adding a backend, and again whenever a feature is built for one backend. Claude
Code missed every item on this list until d1549c6 and bb39eeb. For each row, the new backend
either matches or the gap goes in section 9.

- Background agents, `watch-`/`side-` conventions and wake-up turns
- Stopping one subagent, and subagent cards with nested steps
- Per-tab model and effort, Home task models, child tab inheritance
- Home's protocol in the system instructions; Home's tool checks
- Child tabs taking Simulator and build turns
- Earlier turns replayed when the session hasn't seen them
- Shared MCP servers
- Idle process release and resume
- Context window size and token breakdown
- Live steering and "send now"
- Slash commands and skills
- Usage reading, limit codes and fallback
- Reply visibility guidance
- `CANTRIP_TAB_ID` and `RemoteAskpass`

## 6. Other platforms and clients

- **Windows** (`windows/`): add a `BackendId` and argument builder in `src/main/backends.ts`,
  allow it in IPC validation, the renderer picker and `src/shared/types.ts`, and add tests in
  `tests/backendPolicy.test.ts`. Validate privileged IPC in the main process.
- **Paired clients**: the host's Remote API carries backends, models, usage
  (`/api/v1/copilot/usage`) and fallback (`/api/v1/usage-fallback`). Keep new fields additive
  and optional so older clients still decode them. Then update Cantrip Gateway Mac
  (`External/CantripGatewayMac`, and pin the submodule), Cantrip Agent for iPhone/iPad
  (FlyingViet/CantripIOS), Gateway Windows and the browser/Mac Remote. A host feature isn't
  done until each client shows it or deliberately leaves it out.
- **Plugin manifest**: keep the schema compatible across platforms.

## 7. Tests and live verification

Add unit tests next to the existing ones in `Tests/SessionTabTests/` (`ClaudeBackendTests`,
`Antigravity*Tests`, `UsageLimitFallbackTests`), and register them in its `main.swift`:

- stream parsing from saved fixtures: text, reasoning, tools, results, errors and cumulative usage
- argument building for each permission mode, model, effort and resume case
- tool-call policy: read-only, ask, Home attended and unattended, and an unchecked tool
- turn lifecycle: one terminal event, late events after cancel, interrupt, heartbeat
- folder change and reset
- model list parsing and labels
- usage parsing and limit detection, with and without a reset time

Also extend `Tests/MessageRoutingTests`, `Tests/ConsolidationTests`, `Tests/BackendCommandTests`,
`Tests/ToolPathTests` and `Tests/SessionTabTests/CantripHomeGuardrailTests.swift` where the
backend appears. Run `make test` and, for Windows changes, `npm test` and `npm run typecheck`
in `windows/`.

Then do a live check with the real, signed-in CLI. Record the CLI version and the results:

1. A three-turn conversation that remembers the earlier turns, survives a Cantrip restart, and
   survives Stop.
2. A tab that ran on another backend, switched to this one, still knows the earlier turns.
3. A tool call with actions off (Cantrip asks), one denied (shown as failed), and one with
   actions on.
4. A read-only council seat that tries to edit (refused).
5. A tab whose folder changes, then runs `pwd`.
6. A command that runs over 15 minutes without output (not killed by the watchdog).
7. The model list matches the CLI's own; a per-tab model change takes effect.
8. The Usage Limits screen matches the CLI's own usage command.
9. About 20 Auto-routing tries; note the success rate.
10. A Home task and a child tab on the backend.
11. A background `watch-` agent, if supported: the run stays open and resumes when it ends.
12. The same tab viewed from Cantrip Agent, Gateway Mac and the browser Remote.

Delete the test chats and scratch files afterwards, and point any global hook back at the
installed Cantrip. After the CLI updates itself, repeat items 1, 3 and 11.

## 8. Documentation

Update [docs/backends.md](docs/backends.md) (setup, permissions, limits, models), and
[docs/headless.md](docs/headless.md), [docs/remote-control.md](docs/remote-control.md) and
[docs/cantrip-home.md](docs/cantrip-home.md) where behaviour differs. Also update the backend
list in `README.md`, the rows in [windows/PARITY.md](windows/PARITY.md), and the gaps table
below. When a fix teaches something new, add it to section 4 with its commit.

## 9. Known gaps in current backends

Checked against `main` on 2026-10-30. Fix these when working on the backend, and update the
table when you do.

| Backend | Missing |
|---|---|
| Antigravity | `ReplyVisibility` and `watch-`/`side-` guidance; `CANTRIP_TAB_ID`; `RemoteAskpass`; `.usageLimit` from a run's error (limits are detected only from the usage read and phrase matching); `.heartbeat`; stopping one subagent; live steering (the CLI has none) |
| Claude Code | Stopping one foreground Task subagent (the CLI can stop only background agents) |
| Codex | Model discovery; usage screen; structured limit codes; tool-call checks (so no unattended Home); subagents |
| Windows (all) | Structured events, conversation resume and usage fallback (see PARITY.md) |

## Done checklist

- [ ] Section 1's questions answered, with the CLI version and saved fixtures
- [ ] Section 2's table filled in; every unsupported row fails with a clear message
- [ ] Every `BackendKind` switch and `default:` branch reviewed
- [ ] Section 4's rules covered by tests or the live check
- [ ] Section 5's parity sweep done, with gaps recorded in section 9
- [ ] Windows and paired clients updated, or the gap recorded in PARITY.md
- [ ] `make test` passes (and the Windows suite, if touched)
- [ ] Live check in section 7 done and recorded; test data cleaned up
- [ ] Docs and the gaps table updated
