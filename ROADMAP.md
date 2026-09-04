# Cantrip Roadmap

Agreed direction, roughly ordered. Items marked ◐ are partially landed.

## 1. ◐ Council advisors read-only; one worker executes in a worktree

**Landed:** advisors are read-only at the backend level (Claude seats run
`--permission-mode plan`, Copilot seats never get `--allow-all-tools`,
Codex seats never bypass the sandbox, local seats get no tools), the
round prompt states the deliberation contract, and execution prompts
route to the single worker (the session's selected backend) when the
council scope is "planning & review".

**Remaining — worker in a dedicated git worktree:**
- On the first execution prompt after a verdict, create
  `git worktree add .cantrip-work/<session-prefix> -b cantrip/<slug>`
  inside repo workdirs, and point the worker's process at the worktree
  path instead of the live checkout.
- Surface a "working in branch cantrip/<slug>" chip; on approval, offer
  merge/rebase back (chair can review the diff first — this is where
  council review of *implementation* naturally plugs in).
- `git worktree remove` on session close/new-conversation; prune stale
  worktrees at launch.
- Non-repo workdirs: fall back to in-place execution (current behavior).

## 2. ✓ Persist runs as append-only events

**Landed:** one versioned JSONL journal per session at
`~/.cache/Cantrip/runs/<session>.jsonl`, with ordered events for single,
council, shell, and skill runs. It records partial output, full tool lifecycle
and diff artifacts, ACP policy approvals, durable queue claims/mutations,
attempts, token/cost usage, interruptions, cancellations, duration, and
terminal summary digests. Boundary events are fsynced; replay tolerates a
truncated final record, reconstructs unfinished messages and activities, and
preserves the queue across crashes. Private sessions never journal. Files are
mode 0600 in a 0700 directory and rotate after 60 days.

`cantrip runs` lists recent runs and
`cantrip runs <session-or-run-id>` prints an event timeline. A native debug
view remains optional rather than part of the durability contract.

## 3. Copilot sessions + granular flags; startup backend health

- **Resume:** Copilot CLI has `--resume SESSION-ID` / `--continue` since
  v1.0.3 (unconfirmed with `-p` — verify once on this machine:
  `copilot -p "remember X" ; copilot -p --resume <id> "what did I say"`).
  If it works headless, capture the session id from the JSON stream's
  session events, persist per Cantrip session like Claude/Codex, and
  delete `ConversationContextBuilder`'s raw-turn reinjection for Copilot.
- **Granular tools:** replace `--allow-all-tools` with scoped
  `--allow-tool` / `--deny-tool` patterns (e.g. `shell(git:*)`,
  `write(...)`) driven by the same policy tiers as the rest of the app —
  this is the Copilot half of the audit's §2.1.
- **Startup health:** at launch (and on settings change), probe each
  backend — binary present (`command -v`), auth state (`claude` exits
  cleanly, `~/.copilot` state exists, codex config present), local server
  `/models` reachable. Unavailable backends render disabled with the
  reason in the picker and the council seat menu, instead of failing at
  first message.

## 4. Unified sensitive-tool registry

A Cantrip-owned registry for every capability that touches the outside
world (messages-send, screen capture, overlay, notifications, future
MCP passthrough):

- Each tool: JSON schema, per-tool authorization tier (ask/allow/deny,
  persisted), timeout, and a health check.
- Every invocation writes an audit record (append-only, joins the run
  journal from item 2).
- Exposed to backends as a single MCP server (`cantrip serve-mcp`) via
  `--mcp-config`, which also becomes the home of the interactive
  permission prompt (audit §2.1/§2.5) — one implementation, every
  backend, phone-style Allow/Deny in the panel.

## Landed recently (for context)

- Resume-after-interruption with auto-retry; graceful in-band interrupt
  (Claude control protocol); streamed thinking display (all backends).
- Copilot model catalog with real context windows + discovered
  effort/context-tier flags.
- Layout-loop damping (long-prompt hang); stale-build detection +
  rebuild chip; `cantrip` CLI launches the exact bundle and flags
  stale builds.
- Council mode: multi-seat (backend, model) deliberation with chair
  verdict, seat side-panes, read-only advisors, plan/review scoping,
  council-tagged history.
