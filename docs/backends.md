[User Guide](README.md) / AI backends

# Choose and configure an AI backend

Use one backend you already have access to. Cantrip launches the CLI for
Claude Code, Copilot, Codex, or Google Antigravity (`agy`); **signing in to a provider's website alone does
not sign in its CLI**.

| Choice | What you need |
|---|---|
| Claude Code | Installed `claude` CLI and an authorized account |
| Copilot | Installed `copilot` CLI and an account with Copilot CLI access; macOS also needs Node.js and the CLI's bundled SDK/runtime |
| Codex | Installed `codex` CLI and an authorized account |
| Antigravity | Installed Google Antigravity `agy` CLI and an authorized account |
| Local Model (Mac only) | A running OpenAI-compatible server and its exact model ID |

## Install and sign in to a cloud backend

The npm installation options below require [Node.js and npm](https://nodejs.org/).
Use a Node.js version supported by the CLI you choose. Run **one** matching
pair of commands in Terminal on Mac, or in your backend's supported shell on
Windows:

| Backend | Install | Open and sign in |
|---|---|---|
| Claude Code | `npm install -g @anthropic-ai/claude-code` | `claude` |
| Copilot | `npm install -g @github/copilot` | `copilot` |
| Codex | `npm install -g @openai/codex` | `codex` |
| Antigravity | Install Google Antigravity (`agy` CLI) | `agy` |

1. Complete that CLI's sign-in prompts.
2. Ask it a short question to confirm your account works.
3. Open Cantrip's **gear**, then select the matching **Backend**.
4. Start with the default **Model** and **Effort**, where those controls are
   available.
5. Send a new question in Cantrip.

Model names in examples are not a promise of access. If a model is rejected,
return to the default or choose one your CLI/account supports. An option
visible in a picker may still require provider entitlement.

On Mac, the backend's **path (blank = auto)** field normally stays blank.
Automatic detection uses the same PATH Cantrip gives the tools it starts
(`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` ahead of the system
folders), then the CLI's own install folder (`~/.npm-global/bin` for Copilot,
`~/.claude/local` for Claude), then your login shell's PATH. Copilot tabs,
slash commands, the model list, Auto routing and memory upkeep all run the CLI
it finds. The path field also accepts a different command name.
If automatic detection fails, run `command -v claude`, `command -v copilot`,
or `command -v codex` in Terminal and paste the returned executable path into
the matching field.

On Mac, Antigravity keeps one `agy` process per tab. Unless **Act on my
behalf** (or Antigravity's **Allow everything**) is on, Cantrip checks each
tool call before it runs: read-only council seats may only look, and other tabs
ask before edits and commands. Cantrip Home and child tabs apply their own
policy. `agy` reads hooks only from a project's `.agents/hooks.json` or the
global `~/.gemini/config/hooks.json`, so Cantrip adds one `cantrip-guardrail`
entry to the global file instead of writing into your projects. The entry does
nothing for `agy` runs Cantrip didn't start. If `agy` ever runs a tool without
that check, Cantrip stops the session.

On macOS, local Copilot runs through a persistent native SDK session, not a
one-shot prompt process. Use a recent CLI with its bundled SDK and runtime
(exercised with 1.0.83), and ensure `node` is available in your login shell.
Cantrip resolves both from the configured CLI installation/version; it does
not substitute another cached version when a custom path is invalid.
This enables [live context injection](sessions-and-council.md#send-instructions-while-the-agent-is-busy).
Without action permissions the native adapter exposes only read/search tools;
read-only council advisors receive no tools. Permission requests that cannot
be approved by the current action policy are denied rather than left hanging.

## Choose a model, effort, or context window

1. Open **Settings** and select the backend first.
2. Choose a **Model** or enter an ID in the backend's model field.
3. If **Effort** is offered, leave it at **Default** until you have a reason
   to change it. Higher effort can take longer and consume more usage.
4. For Copilot, use **Context window** only with a model/account that supports
   the selected tier. A larger context can increase usage.
5. Apply the choice to your next request; changing a picker does not rewrite
   an answer already being generated.

On macOS, the backend and its defaults are shared app settings. Copilot and
Claude Code tabs can override the model and effort (Copilot also the context
tier) through **Model Settings** in
the tab's context menu, Mac/browser Remote or Cantrip Agent. Overrides persist
per tab, require idle work and Council mode off, and can be removed with
**Use Mac defaults**. Each backend keeps its own override, since their model
IDs differ. Claude Code's list comes from the CLI's `initialize` reply (no model
call); a change restarts that tab's `claude` process, which resumes the same
conversation. Working directories and conversations are also per-session.

On Mac, the refresh button beside the Copilot model picker reads the signed-in
CLI's live account catalog, including each model's supported efforts and context
tiers. It does not create a chat or invoke a model. Opening the picker refreshes
catalogs older than six hours; lookup failures leave the previous catalog intact
and show an error rather than substituting guessed models.

The model label shows the API's advertised **maximum context**. Context-tier
labels separately show the API's **input-token budget**, when available; these
are not interchangeable with total context or maximum output tokens. Unsupported
saved effort/tier values remain visible with a warning, without changing active
sessions or silently resetting your preferences.

## Claude Code context

Claude Code tabs get the same context as Copilot tabs: Cantrip's memory and notes, location,
calendar and screen context with each message, and the tab's earlier conversation. Claude keeps
its own session, so earlier turns are replayed only when it hasn't seen them: a tab that ran on
Copilot until now, a new or lost Claude session, or turns another backend answered since. Those
turns go in front of the message, selected like Copilot's continuity (a summary plus related and
recent turns). The Copilot CLI's local MCP servers (`~/.copilot/mcp-config.json`, for example
homelab and the agent vault) are passed to Claude too, unless Claude Code already has a server
with that name; remote servers that sign in through Copilot aren't shared.

## Claude Code background agents

Claude Code tabs follow the same watcher and parallel-request conventions.
Cantrip adds them to the system prompt in Claude's terms: a background agent
(Agent/Task tool with `run_in_background`) whose description starts with
`watch-` waits on a build or upload, and `side-` agents take forwarded
independent requests. When the root turn ends while background agents or
shells run, the run stays open ("Background watcher running") and still takes
new messages. When the work finishes, the CLI starts a turn of its own; Cantrip
shows it as the run's continuation, in its own bubble when the work came from
another thread. Stop ends the run and its background work. An idle `claude`
process is stopped after the **Free an idle tab's memory** delay (Settings >
Copilot), and the next message resumes its session. Child tabs on Claude Code
take the same Simulator/build turns as Copilot child tabs.

## Copilot subagents

**Allow subagents** (Settings > Copilot, on by default) lets Copilot delegate
broad multi-file searches, noisy builds/tests and independent parallel work.
Cantrip adds brief token-saving guidance once to the session's system message,
not to every prompt, and does not stream subagent text into the reply.
Subagent token usage is included in the run's usage totals. Background
subagents keep the turn open until they finish, and Stop cancels them.

### Monitor subagents

While a reply's subagents run, a line pinned to the bottom of the chat shows
their progress, such as
`2 subagents running · Find tests: Searching Tests/ · 42s`, so it stays in
view as the reply grows. When a subagent finishes, a summary line for it
moves into the reply at the point it ended, after the paragraph that was
being written at the time, so later text follows it. Click either line to open
the **Progress** pane. Its **Subagents** section has a card for each subagent,
running ones first. A card shows:

- the subagent's name and type (for example `explore`), and whether it runs in
  the background
- its status: Running, Waiting (a background agent that finished its turn and
  is waiting for instructions), Done, Failed or Stopped
- **Now**: what it reports doing, or its current step
- elapsed time, step count, tokens used so far, and model and effort
- its steps and latest message, under the disclosure, plus any failure reason

**Stop** on a card cancels only that subagent. The rest of the reply keeps
going, and Copilot is told the subagent was stopped. Claude Code background
agents can be stopped the same way (the CLI's `stop_task`); its foreground
Task subagents are shown but can't be stopped one at a time. Subagent cards last as long as the conversation is open, like
other tool steps. The browser Remote, another Mac's Remote tab and Cantrip
Agent show the same cards: running ones pinned at the bottom of the chat with
Stop, finished ones in their reply; see
[Monitor subagents remotely](remote-control.md#monitor-subagents-remotely).

Turning the setting off removes the `task`, `read_agent`, `write_agent` and
`list_agents` tools from new Copilot sessions, which also saves their schema
tokens on every model call. The change applies to each tab's next request.

## Interactive MCP App views

**Show interactive MCP App views** (Settings > Copilot, on by default) opts
Copilot sessions into [MCP Apps](https://github.com/modelcontextprotocol/ext-apps)
(SEP-1865). MCP servers that support it, such as Mobbin, then return a small
web view with their tool results, and the Mac chat shows it inline above the
reply: for example, a scrollable gallery of the screens a Mobbin search found.
Click a screen to open it on Mobbin in your browser. A caption above each view
names the server it came from. Views are saved with the conversation and
reappear when you reopen the tab.

Each view runs in its own sandbox:

- It is an isolated origin inside a Cantrip wrapper page, with no access to
  Cantrip, other views or your files, and nothing it stores is kept after
  Cantrip quits.
- It can load resources only from the domains the server declared, under a
  Content Security Policy. It cannot navigate away; web links open in your
  browser.
- It can call tools and read resources on **its own** MCP server only, and the
  Copilot runtime also blocks tools the server marked model-only. These
  calls go through the tab's live Copilot session. If that session has ended
  (for example after Stop, a relaunch, or once an idle tab's memory is freed),
  send a message in the tab first.
- A view can ask Cantrip to send a chat message for you. The confirmation
  dialog shows the exact text; approved text goes to the model labelled with
  the view's server and never runs as a `!` or `/` command. Context a view
  shares for the model is added to your next prompt only and is dropped when
  you start a new conversation.

The browser Remote, another Mac's Remote tab and Cantrip Agent show views too;
see [MCP App views remotely](remote-control.md#interactive-mcp-app-views-remotely).
On the Mac, scrolling up or down over a view scrolls
the conversation; sideways scrolling moves through the gallery. Turning the
setting off hides all views, including saved ones, and stops opting in from
each tab's next request.

## Free memory from idle tabs

Each tab keeps its own Copilot runtime, which holds 0.5–3 GB. **Free an idle
tab's memory after** (Settings > Copilot, 30 minutes by default) stops a tab's
runtime once it has been idle that long. Your next message in the tab resumes
the same Copilot conversation in a new runtime, about 3 seconds slower than
usual. Choose **Never** to keep runtimes running.

A tab is kept while its runtime still has work running: a background agent,
a shell command or script it started, or a turn in progress. Cantrip checks
again every 5 minutes. MCP servers alone don't keep a tab running. Even with
**Never**, a runtime idle for 2 hours is restarted before its next message,
because the Copilot CLI can crash after long idle periods.

## Fall back when a backend hits its usage limit

Choose a backend under **Usage limit fallback** (Off by default): in Mac
Settings, or in any tab's **Model Settings** on Cantrip Agent (iPhone/iPad),
Cantrip Gateway (Mac and Windows) or the browser/Mac Remote. It's one setting
for the whole Mac, so changing it there saves right away and applies to every
tab. Those screens also show which backend is at its limit and until when, with
**Try every backend again** to clear that early. When the backend you use reports that its plan's usage limit
is reached (Claude's 5-hour or weekly limit, Copilot's premium requests, a
Codex or Gemini quota), Cantrip:

1. Shows the error and notes which backend takes over.
2. Continues the same task on the fallback backend, with the original request
   and the steps already taken, like an automatic resume.
3. Sends new messages from every tab to the fallback until the limit resets.
   Cantrip uses the reset time from the error when the backend gives one, and
   tries the original backend again after an hour when it doesn't. Copilot's
   monthly premium-request allowance is skipped until it resets on the 1st
   (00:00 UTC). Quitting Cantrip clears this, so the next message tries the
   original backend first.

Cantrip decides from each backend's own error fields, not the error's wording:
Copilot's `session.error` category (`quota` or `rate_limit`, with codes such as
`quota_exceeded` or `user_weekly_rate_limited`), and Claude Code's `rate_limit`
or `billing_error` message error and `rejected` rate-limit event, which also
gives the reset time. Matching known phrases in the message is only the last
resort, for CLIs that don't send a code (Codex and Gemini today); the host log
notes when a switch relied on it.

The fallback uses its own model and effort settings. It doesn't share the
original backend's session, so it works from the conversation Cantrip passes
along. If the fallback is at its limit too, the run stops with the error.
Council seats and Private Local tabs never switch. Scheduled Cantrip Home tasks
don't move to Codex or Copilot Remote, because Cantrip can't check their
actions one at a time. A full context window ("Context limit reached") isn't a
usage limit and doesn't switch backends.

From Terminal: `cantrip config set limitFallbackBackend copilot` (or `claude`,
`codex`, `agy`, `local`, `off`). Paired clients use `GET/POST
/api/v1/usage-fallback`; see [Remote control](remote-control.md#usage-limit-fallback).

## Connect a local model

**Mac only.** Cantrip does not install or start the model server for you.
Ollama, llama.cpp, and vLLM are examples of servers that can expose an
OpenAI-compatible API.

1. Start your server using its own setup instructions and load a model.
2. Find the server's API base URL, including `/v1`, and its exact model ID.
3. In Cantrip Settings, select **Local Model**.
4. Enter **Base URL**, **Model**, and **API key (optional)** if the server
   requires one.
5. Send `Reply with one short sentence so I can confirm this connection.`

For example, an Ollama server on the same Mac commonly uses
`http://127.0.0.1:11434/v1`. Other servers may use a different port.
For that example, this command lists the model IDs the server exposes:

```sh
curl --fail http://127.0.0.1:11434/v1/models
```

Use an `id` from the response; do not assume the default name `hermes` matches
your server. For a password-protected server, use its documented authentication.
Do not expose an unauthenticated model server to the public internet.

**Expected result:** the model responds through Cantrip. Tool use also requires
a model with compatible tool-calling support and **Act on my behalf** enabled.
The current Local Model backend does not receive Cantrip's staged file/image
attachments or screen captures; use a supported CLI backend for those tasks.

## Let the agent take actions

1. Select the intended project with the toolbar's **folder** button.
2. Review [what action permissions allow](privacy-and-memory.md#let-an-agent-make-changes).
3. Enable **Act on my behalf** only if you want unattended commands and edits.
4. Give a bounded request, such as `In this project, update the README to
   explain the setup command. Do not change application code.`
5. Review the output and the **Progress** sidebar.

An action-enabled agent can work outside its starting directory. The selected
folder is a convenience, not a sandbox.

## Do not confuse the two Remote features

**Cantrip's Remote tab** connects to another Mac's Cantrip sessions; follow
[Remote control](remote-control.md).

**Copilot Remote** in the backend picker is an advanced connection to a
Copilot ACP server. It does not connect to a Cantrip host or use a Cantrip
pairing token. Ordinary Copilot users should choose **Copilot**, not
**Copilot Remote**.
