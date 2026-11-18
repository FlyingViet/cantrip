# Code mode

Code mode lets a model chain MCP tool calls in one step. Instead of calling tools one at a
time, with every intermediate result passing through the model, the model writes a short
JavaScript program against a typed API of Cantrip's read-only tools. Cantrip runs it in a
sandbox on the Mac and returns only the program's result.

It is off by default: **Settings > Tools & sign-ins > Code mode** (the same setting on the Mac,
in Cantrip Agent, on Windows and in the browser).

## How a backend reaches it

Code mode is one more MCP server, `cantrip_code`, with two tools:

- `run_tool_script({script, args?})` runs a program and returns its JSON result.
- `tool_api({servers?})` returns the TypeScript declarations of the tools and recipes this run
  may use. `run_tool_script`'s description already holds them when they fit.

Copilot, Claude Code, Codex and Antigravity get the server through their generated MCP configs
(`cantrip-mcp cantrip_code --backend NAME`), so it runs through Cantrip's MCP relay like any
relayed server. The Private Local tab offers `run_tool_script` as one more function when its
read-only tools are on.

Copilot CLI and Claude Code already defer loading tool definitions with tool search. Code mode
is separate from that: it removes round trips, not definitions.

## The program

```js
const found = await personal.mail_search({ sender: "example.com", since: "2026-11-01", limit: 5 });
const mails = await Promise.all(found.messages.map(m => personal.mail_read({ message_id: m.id, max_chars: 800 })));
return mails.map(m => ({ id: m.id, subject: m.subject, body: m.body }));
```

- Each server is a global object (`personal`, `homelab`); each tool is an async function that
  takes the tool's arguments. Names with `-` or other characters use `_` (`kiwi.search_flight`).
- A tool returns its parsed JSON result, or its text when that isn't JSON. A failed or refused
  call throws an `Error` the program can catch.
- `recipes.NAME(args)` runs a saved recipe. `log(...)` adds lines to the reply. `args` holds the
  call's `args`.
- The program's `return` value is the result.

## Sandbox

JavaScriptCore inside Cantrip, with nothing but the tool functions: no file system, network,
processes, timers, `fetch`, `require` or WebAssembly. Limits per program: 120 s, 2 s of uninterrupted compute,
512 MB of extra memory, 40 tool calls (4 at a time), 20,000 characters of source and 12,000
characters of result (Private Local: its tool-result size). An error, a refused call or a limit
returns a message saying what happened and how many calls ran.

## What a program may call

Only read-only tools, chosen by the same rule as Private Local's tools (no write word in the
name, not marked destructive, a read word in the name or a server that declares every tool
read-only). Bitwarden, agent Chrome, forms, Xcode and reverse engineering are never offered.

Every call from a program gets the same checks as a direct call from that run:

- The relay's checks: the server is on, on for this backend and for this tab, and allowed for a
  scheduled task.
- The backend's agent policy (`AgentPolicyGate`), including the Privacy Gate: a cloud run that
  enforce mode keeps from private servers (`excludeMCP`) gets neither their declarations nor
  their calls. A denial, or a rule that asks first, refuses the call. Approving the program
  (or "Act on my behalf") covers the read-only calls no rule decides.
- A caller whose tab can't be found is treated as a cloud run without private servers, unless
  it is Private Local.

## Types

Input types come from each tool's `inputSchema`. Output types come from its `outputSchema` when
it declares one; otherwise from the shapes of results seen so far (key names and types only,
never values). An object with more than 40 keys or keys that aren't plain identifiers becomes a
`Record<string, T>`, so data never turns into a key name. Shapes are kept in
`~/Library/Application Support/Cantrip/code-mode/shapes.json`. A tool with no known shape returns
`unknown`.

## Recipes

A recipe is a named program with typed arguments for a chain that recurs, for example the
Home trackers' "search mail, then read each match". Built-in recipes ship with Cantrip; more can
be added as JSON files in `~/Library/Application Support/Cantrip/code-mode/recipes/`:

```json
{"name": "mail_digest", "description": "…", "params": "{ query?: string; limit?: number }",
 "returns": "{ id: number; subject: string }[]", "tools": ["personal.mail_search", "personal.mail_read"],
 "script": "const found = await personal.mail_search({ …args }); …"}
```

A recipe is offered only when every tool it lists is allowed for the run. It runs inside the
caller's program with the same checks and limits.

## Measuring

Before it's turned on for Home tasks, real Home task runs are replayed with and without code
mode on the self-hosted model (counts only: model turns, tool calls, tokens, time, and the score
against the real run's records). See the Home shadow test.
