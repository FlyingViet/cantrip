# Onboarding a new AI backend

Read this before adding a backend (a new agent CLI, SDK or API) to Cantrip, or before
deepening support for one that only half works. It is written for the coding agent doing the
work as much as for people: follow it in order and finish the checklist at the end.

A backend is "onboarded" only when every Cantrip feature that the backend *can* support works
through it, on every surface, and the features it can't support fail clearly. Launching the
CLI and streaming text is the start, not the finish. Antigravity (`agy`) is the worked example
throughout: it first shipped streaming and hooks (84827f8), and then needed about a dozen
follow-ups to reach parity. Each lesson below links to the commit that fixed it.

User-facing setup for existing backends is in [docs/backends.md](docs/backends.md).

## 1. Investigate the CLI before writing code

Install the CLI, sign in, and answer each question from its `--help`, docs and real output.
Save sample output (JSON lines, errors) as test fixtures. Write down the CLI version you tested,
because options change between releases.

| Question | Why Cantrip needs it | Antigravity answer |
|---|---|---|
| Is there a headless, structured stream (JSON lines, ACP, SDK)? | Text, reasoning, tool steps and errors must come from fields, not scraped terminal text. | `--input-format stream-json --output-format stream-json` |
| Can one process serve many turns, or is it one process per turn? | Decides process lifecycle, idle cleanup and mid-turn input. | One persistent process per tab |
| How do you resume a conversation, and is it tied to a folder? | Tabs survive restarts; a tab whose folder changes must not keep working in the old one. | `--conversation <id>`; bound to the starting folder |
| How do you stop a turn without losing the session? | Stop must keep the conversation. | `SIGINT` |
| Can a running turn take new user messages? | Live steering and "send now". | No |
| How are models listed, and does listing spend quota? | Model pickers must show the account's real catalog, without a model call. | `agy models` (free) |
| Which effort, reasoning or context options exist? | Per-tab and Home task model settings. | `--effort low/medium/high` |
| How are usage limits and their reset times reported, both on error and on demand? | Usage limit fallback and the Usage Limits screens. | `agy -p /usage` (free); errors give no code |
| Can every tool call be checked before it runs (hook, permission callback, ACP request)? | Cantrip's action policy, read-only council seats and Home guardrails depend on it. | Global `PreToolUse` hook |
| What does it do with no permission flags? | You must know what runs without asking. | Headless `agy` edits workspace files without asking |
| How are subagents and background tasks reported, and can one be stopped? | Subagent monitor, `watch-` and `side-` agents. | Steps plus transcript files on disk |
| Does it read MCP servers, skills or slash commands, and from where? | Slash command discovery, shared MCP servers. | `~/.gemini/...` skill folders |
| How are images and files attached? | Staged attachments and screen captures. | Paths in the prompt; Cantrip stages files |
| What environment, PATH and login shell does it need? | Cantrip launches tools outside the user's terminal. | Standard PATH |

If a question has no answer, mark that feature unsupported and make sure Cantrip says so
(for example `SubagentCancelError.unsupported`). Don't fake it.

## 2. Map Cantrip's features to the backend

Fill in this table for the new backend before wiring anything. Every row must end up either
working or deliberately unsupported with a clear message.

| Cantrip feature | What the backend must provide | Where Cantrip does it | Reference |
|---|---|---|---|
| Streaming reply | `BackendEvent`s: `.textDelta`, `.thinkingDelta`, `.status`, then exactly one `.done` or `.failure` | `Backends/Backend.swift` | every backend |
| Tool steps | `.activity(ToolActivity)` via `ToolActivityFactory`, with an honest final state | `Backend.swift`, the backend's parser | `ClaudeCodeBackend`, `AntigravityBackend` |
| Token usage and context | `.usage` per turn (convert cumulative totals to deltas), `.context` | backend | `AntigravityBackend.handleResult` |
| Conversation resume | Session ID stored under a per-tab `persistKey`; `reset()` clears it | `TabDefaults.swift`, `ChatSession.backendKeepsSession` | all CLI backends |
| Stop | `cancel()`; `interruptTurn()` when the session survives | backend | Claude, Antigravity |
| Live steering | `injectMidTurn`, `supportsMidTurnInjection`, `canSteerTurns` | backend | Copilot, Claude |
| Action policy | Every tool call checked; asks through `.inputRequired`; read-only seats only look | `CantripHomeGuardrails.swift` | `AntigravityHook.swift`, Claude permission prompts |
| Cantrip Home | `CantripHomeGuardedBackend`, `CantripHomeApproval.chosen(for:)` | `CantripHomeGuardrails.swift` | Copilot, Claude, Antigravity |
| Per-tab model and effort | Model catalog, `modelOverride`, `effortOverride` | `ClaudeModels.swift`, `SessionTabMetadata.swift`, `SessionModelSettings*.swift` | `AntigravityModels.swift` |
| Home task models | Model list for task settings | `CantripHomeTaskModels.swift` | a1e4a83 |
| Child tabs | Inherit the parent's model selection | `ChildTabCoordinator.swift` | a1e4a83 |
| Council seats | Own session per seat and model; read-only | `ChatSession` council setup, `TabDefaults.council*` | 6dd4ee5 |
| Usage limit fallback | `.usageLimit(UsageLimitReport)` from a structured code, sent just before `.failure` | `BackendLimits.swift`, `ChatSession` | 825fcfb, 86abf76 |
| Usage Limits screens | Quota used and reset times, read without spending quota | `UsageTracker.swift`, `CopilotUsage.swift`, `CopilotUsageView.swift` | `AntigravityUsage.swift` (3a04b3f) |
| Auto routing, queue plans, Done-when checks | A tool-free, fast one-shot call | `MessageRouter.swift`, `ChatSession.routerProvider` | daa63fe |
| Memory consolidation (optional) | Same one-shot call, with write limits | `ConsolidationPolicy.swift`, `Consolidator.swift` | 6b2942f, 291336e |
| Slash commands and skills | Built-ins plus discovered skills | `BackendCommands.swift`, `BackendCommandDiscovery.swift`, `BackendCommandCatalog.swift` | 84827f8 |
| Subagent monitor | `ToolActivity.subagent` (`SubagentInfo`), `canCancel` only if it really can | `SubagentMonitorView.swift`, `RemoteHistory.swift` | cae49b5 |
| Background watchers and parallel requests | Background agents named `watch-*` and `side-*`, `.backgroundWake`, `supportsParallelSubagents` | backend system guidance | `CopilotBackend`, `ClaudeCodeBackend` |
| Long commands | `.heartbeat` while a step runs without output, so the inactivity watchdog doesn't fire | backend | Copilot, Claude |
| Attachments and screen captures | Files staged where the CLI can read them | backend | `AntigravityBackend.stagePromptAttachments` |
| `cantrip tab ask`/`read` | `CANTRIP_TAB_ID` in the agent's environment (`tabID` set by `ChatSession`) | `TabInsight.swift` | Claude, Copilot, Codex |
| `sudo`/`ssh` prompts | `RemoteAskpass` broker on the child process | `RemoteAskpass.swift` | Claude, Copilot, Codex |
| Reply visibility | `ReplyVisibility.guidance` in the session's system message | `Backend.swift` | Claude, Copilot |
| Terminal CLI | `cantrip ask --backend <name>` aliases | `CLIServer.swift`, `HostControl.swift` | 84827f8 |

Context such as memory, location, calendar, files, screen and continuity is added to
`request.prompt` by `ChatSession.composeContext` and `prepareMemory`, so a backend gets it
without extra work and must not add it again. A backend that keeps its own session still needs
the turns it hasn't seen: a tab that ran on another backend, or a lost session. See
`ClaudeCodeBackend` and bb39eeb.

## 3. Wire it in on macOS

Add the backend in this order. Many `switch` statements over `BackendKind` have a `default:`
branch that quietly treats an unknown backend as Copilot, so the compiler won't list them all.
Run both of these and decide each hit by hand:

```sh
grep -rn "case \.antigravity\|\.antigravity\b" Sources Tests
grep -rn "switch .*backend\|default:" Sources/Cantrip/ClaudeModels.swift Sources/Cantrip/SessionModelSettings.swift
```

1. **Kind and settings.** Add a case to `BackendKind` in `Settings.swift`. Add settings for the
   path, model, effort and permission mode, plus the model catalog with its refresh error and
   in-flight state. Add executable resolution (`isInstalled`, `resolveExecutable`; see
   `ToolLocator.swift`) that honours a custom path and never falls back to some other cached
   version.
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
   `UsageLimit.phrases` only as a last resort. Add a usage loader and state to
   `UsageTracker`/`CopilotUsage`, and a view in `CopilotUsageView` shown from `LauncherView`.
7. **Routing.** Add a `MessageRouter.Provider` case and a `routerProvider` branch, or return
   `.unavailable` with a reason.
8. **Commands.** Add a `BackendCommandFamily` case, built-ins in `BackendCommands`, discovery in
   `BackendCommandDiscovery` (skill folders, `cliNames`), and the catalog key.
9. **UI.** Settings section, icon, model labels and council menu in `LauncherView`; also
   `PluginPanelData`, `AppSettings.backendLabel`, and the aliases in `CLIServer` and `HostControl`
   (the `limitFallbackBackend` names and error text).
10. **Hooks or helpers** that the CLI runs as a separate program dispatch from `main.swift`
    (see `AntigravityHook.helperArgument`).

## 4. Behaviour rules

These are the rules Antigravity broke at first. Check each one with a test or a live run.

**Tool steps**
- A command the policy refused, or that the CLI reports as failed, ends as `.failed` with the
  reason, never "succeeded" (ec168a6).
- Unfinished steps and subagents end when the turn ends (`ToolActivity.finishing`).
- Give each step a readable title and, for edits, a diff. If the CLI's tool names are new, add
  them to `ToolActivityFactory` (`displayName`, `fileChanges`, `terminalCommand`).

**Sessions and folders**
- Store the session ID per tab, council seat and model, never globally (6dd4ee5).
- If the CLI ties a conversation to a folder, record the folder with the session. When a tab's
  folder changes (folder picker, or a child tab returning to its parent), start a fresh
  conversation in the new folder (200c958).
- A launch signature (folder, model, effort, permission mode, guardrail) decides when the
  persistent process must restart. A model change resumes the same conversation.

**Permissions** (never weaker than Cantrip's policy; see CLAUDE.md)
- With **Act on my behalf** off, every tool call is checked before it runs. Read-only council
  seats may only look. Cantrip Home and child tabs apply their own policy.
- Don't write config into the user's projects. If the CLI only reads hooks from a project or a
  global file, add one Cantrip entry to the global file that does nothing for runs Cantrip
  didn't start (03acc10).
- Count the CLI's tool steps against the hook requests it made. If a tool ran without the
  check, stop the session.
- Check text sent into a running task the same way as a command (19ce907).
- Where a platform has no hook (Windows `agy` today), refuse to run without actions on rather
  than run unchecked (7089526).

**Models**
- List models from the CLI or API, never by calling a model, and never ship a guessed list.
  Refresh at launch, when a picker opens with a stale list, and from the refresh button. A
  failed refresh keeps the previous list and shows the error (e39ede5).
- Keep per-tab overrides per backend, because model IDs differ (a1e4a83). An unsupported saved
  value stays visible with a warning; don't reset it silently.
- Automatic model tiering (picking a small model for small tasks) applies only when the user
  left the model on default or auto. A model the user picked is used as picked (c768334).

**Usage limits**
- Detect limits from the CLI's error code or field, not its wording (825fcfb). Send
  `.usageLimit` with the reset time just before `.failure`.
- Read limits on demand without spending quota, on `UsageTracker`'s regular refresh. When the
  window the current model uses is full, mark the backend limited so new messages go to the
  fallback (3a04b3f).
- In the Usage Limits screens, show only how much of each quota is used and when it resets.
- Add the new section to the paired usage API so remote clients show it too.

**Routing and other helper calls**
- Router calls must be tool-free: block tools outright, or the model may try a command, get
  refused and return nothing.
- Time out after the CLI's real startup time plus the answer, measured live (`agy` takes 5 to
  11 seconds to start, so it gets 25 seconds). Measure the success rate over about 20 live
  tries (daa63fe).
- If a helper call would send the user's messages or memory to a provider they didn't choose
  for that tab, it must be an opt-in setting that is off by default (291336e).

**Agent guidance and environment**
- Add `ReplyVisibility.guidance` and `RemoteGeneratedImages.agentGuidance` to the session's
  system message. If the backend can run background agents, add the `watch-`/`side-`
  conventions in its own terms (see `ClaudeCodeBackend`).
- Set `CANTRIP_TAB_ID` and attach `RemoteAskpass` to the child process.
- Rewrite internal links the CLI prints that Cantrip's apps can't open into plain labels
  (`TabMentions`, for `conversation://`).

**Privacy**
- Private Local tabs never reach a cloud backend. Private tabs follow `MemoryStore`'s rules.
  Never log prompts, secrets or tokens.

## 5. Other platforms and clients

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

## 6. Tests and live verification

Add unit tests next to Antigravity's in `Tests/SessionTabTests/` (register them in its
`main.swift`):

- stream parsing from saved fixtures: text, reasoning, tools, results, errors and cumulative usage
- argument building for each permission mode, model, effort and resume case
- tool-call policy: read-only, ask, Home attended and unattended, and an unhooked tool
- folder change and reset
- model list parsing and labels
- usage parsing and limit detection, with and without a reset time

Also extend `Tests/MessageRoutingTests`, `Tests/ConsolidationTests`, `Tests/BackendCommandTests`
and `Tests/SessionTabTests/CantripHomeGuardrailTests.swift` where the backend appears. Run
`make test` and, for Windows changes, `npm test` and `npm run typecheck` in `windows/`.

Then do a live check with the real, signed-in CLI. Record the CLI version and the results:

1. A three-turn conversation that remembers the earlier turns, survives a Cantrip restart, and
   survives Stop.
2. A tool call with actions off (Cantrip asks), one denied (shown as failed), and one with
   actions on.
3. A read-only council seat that tries to edit (refused).
4. A tab whose folder changes, then runs `pwd`.
5. The model list matches the CLI's own; a per-tab model change takes effect.
6. The Usage Limits screen matches the CLI's own usage command.
7. About 20 Auto-routing tries; note the success rate.
8. A Home task and a child tab on the backend.
9. A subagent, if supported: shown in the monitor, and stopped if it can be.
10. The same tab viewed from Cantrip Agent, Gateway Mac and the browser Remote.

Delete the test chats and scratch files afterwards, and point any global hook back at the
installed Cantrip.

## 7. Documentation

Update [docs/backends.md](docs/backends.md) (setup, permissions, limits, models), and
[docs/headless.md](docs/headless.md), [docs/remote-control.md](docs/remote-control.md) and
[docs/cantrip-home.md](docs/cantrip-home.md) where behaviour differs. Also update the backend
list in `README.md`, the rows in [windows/PARITY.md](windows/PARITY.md), and the gaps table
below.

## 8. Known gaps in current backends

Checked against `main` on 2026-10-30. Fix these when working on the backend, and update the
table when you do.

| Backend | Missing |
|---|---|
| Antigravity | `ReplyVisibility` and `watch-`/`side-` guidance; `CANTRIP_TAB_ID`; `RemoteAskpass`; `.usageLimit` from a run's error (limits are detected only from the usage read and phrase matching); `.heartbeat`; per-subagent stop |
| Codex | Model discovery; usage screen; structured limit codes; tool-call checks (so no unattended Home); subagents |
| Windows (all) | Structured events, conversation resume and usage fallback (see PARITY.md) |

## Done checklist

- [ ] Section 1's questions answered, with the CLI version and saved fixtures
- [ ] Section 2's table filled in; every unsupported row fails with a clear message
- [ ] Every `BackendKind` switch and `default:` branch reviewed
- [ ] Section 4's rules covered by tests or the live check
- [ ] Windows and paired clients updated, or the gap recorded in PARITY.md
- [ ] `make test` passes (and the Windows suite, if touched)
- [ ] Live check in section 6 done and recorded; test data cleaned up
- [ ] Docs and the gaps table updated
