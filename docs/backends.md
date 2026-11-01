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

On Mac, Codex runs as `codex app-server`, one process per tab (tested with
Codex 0.166.0). Each tab keeps its Codex thread across restarts, **Stop**
interrupts the turn and keeps the conversation, and a message sent while Codex
works steers the running turn. Codex asks Cantrip before every command, file
edit and MCP tool call: tabs ask you, read-only council seats run in Codex's
read-only sandbox and may only look, and Cantrip Home and child tabs apply
their own policy. Codex runs a few plain reads (`cat`, `ls`) without asking;
under Cantrip Home, a command other than a plain read that runs without
Cantrip's check stops the run. Settings > Codex > **Permissions** offers **Full
access**, the same as **Act on my behalf**: no sandbox and no approvals.
Council seats stay read-only either way. Cantrip never reads or changes Codex's
sign-in (`codex login`).

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

On macOS, the backend and its defaults are shared app settings. Copilot,
Claude Code, Codex and Antigravity tabs can override the model and effort
(Copilot also the context tier) through **Model Settings** in
the tab's context menu, Mac/browser Remote or Cantrip Agent. Overrides persist
per tab, require idle work and Council mode off, and can be removed with
**Use Mac defaults**. Each backend keeps its own override, since their model
IDs differ. Claude Code's list comes from the CLI's `initialize` reply (no model
call); a change restarts that tab's `claude` process, which resumes the same
conversation. Codex's list, with each model's efforts, comes from its app
server's `model/list` (no model call); a change applies to the tab's next
message in the same Codex thread. Working directories and conversations are
also per-session.

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

## Ask for a model tier instead of a model

Anywhere you pick a model, you can pick a tier instead: **Fast**, **Standard**
or **Deep**. Each backend maps every tier to an ordered list of its own models,
each with an effort, so a deep run stays deep whichever backend serves it, and
changing what deep means is one edit that applies everywhere at once. Exact
model names keep working everywhere; tiers are an addition, and nothing that
names a model today changes until you switch it to a tier.

| Tier | Copilot | Claude Code | Antigravity | Codex |
|---|---|---|---|---|
| Fast | claude-haiku-5.5 (low), then gpt-5.6-sol-fast, mai-code-2-flash | haiku (low) | Gemini 3.8 Flash (Medium), then Flash (Low) | gpt-6-luna (low), then gpt-5.6-luna |
| Standard | gpt-5.6-sol (high), then claude-sonnet-5.5, gpt-6-sol | sonnet (high) | Gemini 4 Argon (Medium), then Claude Sonnet 5.5 (Medium) | gpt-6-luna (medium), then gpt-5.6-terra |
| Deep | claude-opus-5.5 (xhigh), then gpt-6.1-sol, gpt-6-astra | opus (xhigh) | Gemini 4 Argon (High), then Claude Opus 5.5 (High) | gpt-5.6-terra (xhigh), then gpt-6-luna |

Claude Code's aliases always point at the newest model of each family, and
Antigravity's model names already include the effort. Codex's row comes from
its `model/list`: gpt-6-luna is its default and cheapest model, gpt-5.6-terra
its strongest. Local Model runs its one model for every tier, and Copilot
Remote runs its server's model.

**Where tiers work.**

- **Tab model picker** (Mac, browser/Mac Remote, iPhone, Duo, Gateway): Fast,
  Standard and Deep come first, then the backend's models. The tier's own
  effort applies unless you pick one its model takes.
- **Home tasks**: a task's `model` can be `fast`, `standard` or `deep`. Home is
  told to prefer a tier when you ask for a cheaper or stronger model.
- **Child tabs** inherit the parent's tier, not the model it runs today.
- **Usage limit fallbacks**: a backup can be pinned to a tier (for example
  Antigravity · Deep). A backup left on its default model follows the run's
  tier, so a deep run stays deep on whichever backup serves it. A backup pinned
  to an exact model keeps that model.
- **Auto routing, queue plans and Done-when checks** run on the backend's Fast
  model (they used fixed Haiku and Flash models before).
- **OpenAI-compatible API**: `model` can be `deep` (the backup chain at that
  tier) or `copilot:deep` (only that backend).

**When a tier's model can't run.** A run on a tier takes the first model in the
list that its backend offers and that isn't at its own usage limit. If the
first choice is skipped, the run note says why, for example "Deep on
Antigravity: Gemini 4 Argon (High) is at its usage limit until 9:40 PM, so
Claude Opus 5.5 (High)." A model that runs out partway moves the task to the
tier's next model on the same backend before the next backup ("Continuing this
task on the next Deep model"). A limit on the whole backend, such as Copilot's
shared premium requests, skips straight to the next backup.

**Edit the map** under **Model tiers** in Mac Settings, or in the browser/Mac
Remote's **Model Settings** (all tabs): pick a backend, then for each tier
choose up to five models in order, each with its effort; **Reset** goes back to
Cantrip's defaults. Copilot's token prices show next to each model. Paired
clients use `GET/POST /api/v1/model-tiers`; see
[Remote control](remote-control.md#model-tiers). The map is saved with the
other settings and in `~/.cantriprc` as `modelTiers` (only the cells you
changed).

**Usage by tier.** Each run records its tier, and the usage screens break down
messages, tokens and cost by tier (and by exact model choice) for today and the
last 7 days.

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

Add backups under **Usage limit fallbacks** (Off by default) in Mac Settings or
in the browser/Mac Remote's **Model Settings**: use **Add a backup** as many
times as you like, the arrows to set the order they're tried in, and the remove
button to drop one. Cantrip Agent (iPhone/iPad) and Cantrip Gateway (Mac and
Windows) edit the same list. Each backup is a backend with the model and effort
it runs: on a backend with a model picker (Copilot, Claude Code, Antigravity,
Codex), **Model** and **Effort** menus list that backend's own models and the
efforts each takes, and **Default** means the Mac's own setting for that
backend. A backend can be listed more than once with different models, the
Mac's own backend too ("Antigravity with another model"), for example
Antigravity · Gemini 4 Argon, then Antigravity · Gemini 3.8 Flash, then Claude
Code · Sonnet. A backup can also be pinned to a tier, such as Antigravity ·
Deep, and a backup on its default model runs the same tier as a tab set to one
(see [model tiers](#ask-for-a-model-tier-instead-of-a-model)). The same backend
and model can be listed only once, and the Mac's own backend only with a model
other than its own. A run that moves to a
backup uses its model and effort, and its note names what runs, for example
"Continuing this task with Antigravity · Gemini 3.8 Flash (Medium)". If the
chosen model isn't offered any more, the run uses the default and the note says
so. A backend's choice is remembered when it's removed and added back.
`cantrip config set limitFallbackBackends "agy:gemini-4-argon-high, agy:gemini-3.8-flash-medium, claude:claude-sonnet-5-5:high"`
sets them from a terminal (a bare name keeps that backend's next saved entry).
It's one setting for the whole Mac, so changing it saves right away and applies
to every tab. Those screens also show which backends and models are at their
limit and until when, with **Try every backend again** to clear that early.
When the backend you use reports that its plan's usage limit is reached
(Claude's 5-hour, weekly or weekly Opus/Sonnet limit, Copilot's premium
requests, a Codex 5-hour, weekly or monthly limit, an Antigravity model group's
quota), Cantrip:

1. Shows the error and notes which backup takes over.
2. Continues the same task on the first backup in the list that isn't at its
   limit too, with the original request and the steps already taken, like an
   automatic resume. If that backup then hits its own limit, the task moves on
   to the next one, and so on down the list.
3. Sends new messages from every tab to that backup until the limit resets.
   Cantrip uses the reset time from the error when the backend gives one, and
   tries the original backend again after an hour when it doesn't. Copilot's
   monthly premium-request allowance is skipped until it resets on the 1st
   (00:00 UTC). Quitting Cantrip clears this, so the next message tries the
   original backend first.

**Per-model limits.** Some backends keep a quota per model, so one model
running out doesn't stop the others: Antigravity's model groups (Gemini 4
Argon, the other Gemini models including Auto, and Claude and GPT models share
one) and Claude's weekly Opus and Sonnet limits. When one of those runs out,
only backups running a model in that group or tier are skipped, so a run on
Antigravity · Argon moves to Antigravity · Flash rather than leaving
Antigravity. A shared quota (Copilot's premium requests, Claude's 5-hour and
weekly limits, Codex's limits, or any limit a backend reports without saying
which model) skips every backup on that backend.

Cantrip decides from each backend's own error fields and usage reads, not the
error's wording: Copilot's `session.error` category (`quota` or `rate_limit`,
with codes such as `quota_exceeded` or `user_weekly_rate_limited`), Claude
Code's `rate_limit` or `billing_error` message error and `rejected` rate-limit
event (whose window, such as `seven_day_opus`, names the model tier and gives
the reset time), and Codex's `usageLimitExceeded` or `rateLimitExceeded` error
code, with the reset time from its rate-limit update. Antigravity's errors carry
no code, so its last usage read names the model group that's used up. Matching
known phrases in the message is only the last resort, for CLIs that don't send
a code; the host log notes when a switch relied on it, and such a limit covers
the whole backend. Antigravity's model groups, Claude's windows and Codex are
also marked limited as soon as the Usage Limits screen (or, for Codex, a running
tab) shows a full window, so new messages move before the CLI refuses one.

Each backup uses its own model and effort settings. It doesn't share the
original backend's session unless it's the same backend with another model, so
it works from the conversation Cantrip passes along. Once every backup is at
its limit, the run stops with the error; a backend and model are never tried
again before their limit resets, so a run can't go round in circles. Council
seats and Private Local tabs never switch. Scheduled Cantrip Home tasks skip
Copilot Remote in the list and use the next backup, because Cantrip can't check
that backend's actions one at a time. A full context window ("Context limit
reached") isn't a usage limit and doesn't switch backends.

From Terminal: `cantrip config set limitFallbackBackends "copilot, codex, agy"`
(any of `copilot`, `claude`, `codex`, `agy`, `local`, `copilot-remote`, each
optionally `:model:effort`, in the order to try them), or `off`. `cantrip
config` lists the chain as `limitFallbackEntries`. The older
`limitFallbackBackend` name still sets the chain. Paired clients use `GET/POST
/api/v1/usage-fallback`; see [Remote control](remote-control.md#usage-limit-fallback).

## Serve your backends to other apps (OpenAI-compatible API)

**Mac only, off by default.** Apps and scripts on this Mac can use Cantrip's
backends through an OpenAI-compatible API, so they get the same backend, backup
chain and usage tracking as your tabs. Turn on **OpenAI-compatible API for apps
on this Mac** in Settings (under Remote control), or run
`cantrip config set openAIEndpointEnabled true`. It listens on
`http://127.0.0.1:11439/v1` (`openAIEndpointPort` changes the port) and only on
this Mac's loopback address.

- `POST /v1/chat/completions` takes the usual OpenAI request (`messages`, `model`,
  `stream`, `max_tokens`, `reasoning_effort`) and answers with a `chat.completion`
  (or `chat.completion.chunk` events when `stream` is true). The answer arrives
  as one chunk; the stream sends keep-alive comments while the model works.
- `GET /v1/models` lists `auto`, the tiers and each backend's tiers and models; `GET /health` shows
  the chain and which backends are at their limit (`copilot_limited_until`
  too, for probes written against Copilot-only servers).

**Model names.** `auto`, an empty or missing `model`, and any name that isn't
a backend (so clients written for another server keep working) use the Mac's backend first, then the backups under
**Usage limit fallbacks**, each with the model and effort chosen there. A
backend name (`copilot`, `claude`, `antigravity`, `local`) or `backend:model`
(for example `copilot:gpt-5.6-sol` or `claude:sonnet`) runs only there, as
picked, and returns 429 when that backend is at its limit. A tier (`fast`,
`standard`, `deep`) runs the same chain at that tier: each backend on its own
models for it, in order, except backups pinned to an exact model. `copilot:deep`
runs only Copilot's deep models. A model at its own limit moves the call to the
tier's next model. `reasoning_effort`
overrides the effort where the model supports it. The reply's `model` names
what answered, such as `claude:claude-opus-5-5`, and the `X-Cantrip-Backend`
header names the backend.

**Which model `auto` uses.** By default, the same model, effort and context
window as your tabs. To run API calls on something else, pick **Model**,
**Effort** and **Context** under the API setting, or set them from Terminal:
`cantrip config set openAIEndpointModel copilot:gpt-5.6-sol openAIEndpointEffort xhigh openAIEndpointContextTier long_context`.
The setting names its backend and applies only when that backend answers.

**Usage limits.** When a backend reports its plan's limit (the same error fields
as in [the fallback section](#fall-back-when-a-backend-hits-its-usage-limit)),
Cantrip marks it, or only that model where the backend keeps per-model limits,
limited for every tab and the API, and the call moves to the next backup. A backend that fails for another reason, or can't take the request,
also hands the call to the next one. When every backend is at its limit, the
API answers 429 with `Retry-After` set to the soonest reset.

**What a call can do.** Each request is one stateless call: no session, no
earlier conversation beyond the messages you send, no tools, no MCP servers and
no files. Copilot runs `copilot -p` with no tools and an isolated config, and
Claude Code runs `claude -p` with `--tools ""` and no MCP servers. Antigravity
has no tool-free mode, so Cantrip's guardrail hook refuses every tool it asks
for. Images (base64 `data:` URLs in user messages) go to Copilot as
attachments and to Claude Code as image blocks. Antigravity can't read them
without its file tools, so image requests skip it. Codex can't turn its shell
off and Copilot Remote has no one-shot mode, so the API skips both. At most
four calls run at once; the rest wait.

**Who used it.** Name each app in its base URL, for example
`http://127.0.0.1:11439/consumer/my-script/v1`, or send an `X-Cantrip-Consumer`
header. The usage screen's **API endpoint** section and `cantrip api` show each
consumer's calls today and over the last 7 days: which backends answered,
Copilot premium requests, tokens, and calls refused at limits or failed. The
calls also count toward each backend's totals.

**Access.** Apps on this Mac need no key, and the `Authorization` header that
OpenAI clients send is ignored. A request that came through a proxy, such as
Tailscale Serve (it adds `Tailscale-User-Login` or `X-Forwarded-For`), must send
the API key as `Authorization: Bearer KEY`. Without a key, proxied requests are
refused. Make one with **Make key** in Settings (copied once to the clipboard)
or `cantrip api key new` (printed once); it's kept in the Keychain.

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
