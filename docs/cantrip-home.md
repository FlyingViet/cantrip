[User Guide](README.md) / Cantrip Home

# Cantrip Home

Cantrip Home is an optional, permanent session that runs your Mac from one
conversation. It powers the focused **Chat / Tasks / Artifacts** mode in
[Cantrip Agent](https://github.com/FlyingViet/Hermes) (iPhone/iPad) and
[Cantrip Gateway Mac](https://github.com/FlyingViet/CantripGatewayMac), and is
the pinned first tab in the browser remote. It stays hidden from the ordinary
Mac and Remote tab lists.

Enable it under **Mac Settings > Remote control**. Home uses the same backend,
per-session model controls, tools, attachments, input requests and history as
[Cantrip Remote](remote-control.md). Cantrip must remain running for scheduled
work.

## Answer in Home or hand off to a project tab

Home decides from each message's intent: references, questions and status
checks about a project are answered in Home, while requests to change a project
are handed to the open tab that owns it as a nested task. Home matches tabs by
meaning, using each tab's title, the repositories its conversation works in and
its latest requests, and a busy tab queues the handoff instead of being
interrupted.

Home shows one card per handoff. It starts under Home's reply with the tab's
live status. When the tab needs the user's answer, finishes, fails or is
stopped, Cantrip posts the handoff's result card into Home's chat and the
earlier card is hidden. The result card shows the tab's question, outcome or
error and a link to the tab (Cantrip Agent, Cantrip Gateway Mac and the browser
remote). Later states, including working again after an answer, update that
card in place. It never interrupts a Home reply, and its tab text is shown as
data that Home's model never reads back as its own words.

When a handoff's brief has a "Done when:" line, Cantrip checks the tab's
finished work against it before posting the result. Work the tab can still do
goes back to it as a queued message, at most twice; the card is posted only
once the check passes or the send-backs run out. The card then says whether
Done when was met, and names what's still missing or what needs the user. If
the check can't run or isn't confident, the card says "Done when not
confirmed" instead of claiming the work is finished.

When replies from different threads interleave (a background agent finishing
while you've moved on, or a handoff's result card), Home draws them like inline
replies in Messages: each reply from another thread quotes the prompt it
belongs to, joined to it by a curved line that runs on past the replies right
after it in the same thread, and that prompt says "N Replies".
Either opens the whole thread over the blurred chat. See
[Thread tags in Cantrip Home](remote-control.md#thread-tags-in-cantrip-home).

To answer what a tab or child tab is doing, or why it did something, Home reads
the tab's recent conversation itself (`tab read <tab ID>`, read-only) instead
of guessing or searching source code. Each open tab in Home's data carries its
ID, whose child tab it is, and its newest child tabs with their states. When
only the tab itself can answer, Home can ask it (`tab ask`): the question runs
as a turn in that tab and the reply comes back to Home as an *Answer from …*
card. Change work still goes through handoffs. Private, Private Local and
Home's own background conversations are never readable. See
[Look into other tabs](sessions-and-council.md#look-into-other-tabs).

## Tasks and schedules

Tasks can be one-time, interval or weekday automations, or structured
workspaces such as trackers. A one-time task removes itself after its run
succeeds, and its result stays in Background. A failed or stopped run, or a
one-time task with a workspace, keeps the task so it can be retried or its
records kept. A weekday task can run at several local times a
day in its own time zone, with DST handled. After sleep or a quit, an overdue
task runs once rather than once per missed time, and a task never runs twice at
the same time. Touch and hold a task to drag it into a new order; the order is
saved on the Mac.

A task can list other tasks in `runsAfter` (for example a morning briefing that
reviews the trackers): it starts after their runs due at or before it finish,
or 30 minutes after its own time at the latest.

A task runs on Home's model unless it has its own `model` (and optionally
`effort`), set by asking Home, for example to move a simple tracker to a cheaper
model. The ID must be one the model picker offers; `""` returns the task to
Home's model. Home's effort and context window carry over when the task's model
supports them. If the model isn't available when a run starts, that run uses
Home's model and its summary says so. The Tasks screen shows a task's model, and
each run records the model it used.

Local maintenance can queue a change for an existing task by writing a JSON
file into `~/.cache/Cantrip/home/task-edits/`. It is applied once that task is
idle:

```json
{"version":1,"taskID":"…","schedule":{…}}
```

An edit can carry `schedule`, `"runsAfter":["…"]`,
`"runsAfterTimeoutMinutes":45`, `"model":"…"`, `"effort":"…"` and/or a
replacement workspace `"list":{…}`.
Schedule-only edits also work in `~/.cache/Cantrip/home/schedule-edits/`.

### Workspaces

Workspace tasks use a validated declarative schema for native list, detail and
edit screens; their records can be updated conversationally or through the
mobile UI. A workspace list can be grouped by a choice field
(`list.groupField`, optionally `list.groups`) into collapsible sections with
live record counts on Cantrip Agent, Cantrip Gateway Mac and the browser
remote's Tasks panel:

```json
"groups": [{"title":"In progress","values":["Interviewing",…],"collapsed":false}]
```

Records keep their saved order within each section, values no group lists fall
under Other, and each client remembers which sections the user collapsed.

## Background runs

Each due run and local ingestion incident runs in its own hidden, single-use
session with a fresh model context, so unrelated jobs run in parallel (3 at
once by default; change it under **Mac Settings > Remote control**) and never
add turns to Home chat or wait for it. Jobs that write the same task workspace
or concern the same failing job run one after another, and a repeated trigger
folds into the run already queued or running.

An incident in a repository that an open tab clearly owns (by title, folder or
the repositories it works in) is handed to that tab's queue instead, using
Home's handoff cards and a notification; an incident whose file is already
resolved is skipped. Hidden runs follow the same handoff rules for change work
they discover. Concurrent jobs refresh Apple Mail through
`Scripts/mail-refresh`, which shares one refresh between them.

Results appear in the Background list (with per-run Stop), task run summaries,
workspaces and completion notifications (which open the run's report in Home's
background log); finished sessions are removed and their transcripts kept in
that log. A run whose reply ends with a section that begins on its own line
with `Summary:` uses that section (from the last such label, up to 1,200
characters, line breaks kept) as its summary, and its first two lines as the
notification; other runs keep the start of the reply.

After a quit, interrupted tasks run once more and an interrupted incident is
retried once. Home can still discuss or rerun any of them on request.

### What a scheduled-task run receives

A scheduled-task run's message is built for prompt caching:

1. A static protocol that is the same for every task and run. It covers the
   rules, the `cantrip-task-records` and `cantrip-artifact` formats, a short
   handoff route and a read command for records.
2. Persistent memory: core files, the notes list and the maintenance rule.
3. The task's saved instructions.
4. What changes per run: its own workspace schema and records, plus those of
   tasks it lists in `runsAfter` or names by UUID, each with its last run;
   then run notes, time and location, and retrieved memory snippets.

Long record lists show the first records in full (about 12,000 characters
per run), then an index of IDs and titles. The run can print every record
with a standalone `python3 -c` command that reads `tasks.json`.

Scheduled-task runs don't get the open-tab list, other tasks' records or the
task-creation schema. They read the open tabs and active handoffs from
`~/.cache/Cantrip/home/tabs.txt` only when they hand off a fix, and can read a
tab's conversation with `tab read` (never `tab ask`).

Their Copilot sessions start only the MCP servers scheduled tasks use: `homelab`
and GitHub's built-in server, or the list in the `cantripHomeTaskMCPServers`
default. They also leave out built-in tools scheduled tasks don't call
(subagents, `sql`, skills, code search and workflows). MCP tools load on demand
through tool search.

Incident runs keep the full protocol and every tool. In October 2026 this cut
the bills monitor's first message from about 119,500 to about 34,000
characters, and its first call from about 77,600 to under 33,000 input tokens.
Tool definitions fell from 9,357 tokens to about 3,600.

### What a Home chat message carries

On Copilot, Home's static protocol (rules, block formats, handoff and background
guidance) lives in the session's system instructions. It's sent once per
session and survives compaction. Each message carries only that turn's data:

- the time zone and model IDs
- a one-line index of every task
- the schema and records of the workspaces the message mentions (by title,
  record title or UUID)
- the open tabs (with their child tabs), recent handoffs and recent background
  results; the static protocol says how to read a tab's conversation on demand

Home can print any task's records with the same `python3 -c` read command.
Other backends, and council mode, still get the full protocol with every
message. In October 2026 a Home message dropped from about 117,000 to about
21,000 characters, memory included.

## Rules, safety and approvals

Home's rules and safety checks are enforced by Cantrip, not by the model's CLI,
so they hold whichever backend runs Home. Cantrip validates every task, record,
handoff and artifact block (tolerating common JSON slips). When a block is
invalid, or a task or handoff prompt leans on the conversation instead of
standing alone, it asks the same model once, inside the same reply, for a
corrected block. Handoffs are briefs (goal, context, constraints, done-when)
that Cantrip turns into a standalone tab prompt with the user's own message.

Before each tool runs in Home (Copilot, Claude Code or a local
OpenAI-compatible model), Cantrip blocks catastrophic commands: administrator
commands, erasing disks or the home folder, piping downloads into a shell,
stopping Cantrip, and writing Home's own state files, under every approval
mode.

Otherwise Home follows the approval mode chosen for its backend. With **Act on
my behalf** on (or Claude's **Allow everything**), Copilot and Claude Code runs,
including scheduled tasks and incident investigations, approve tools and
commands automatically. With a stricter mode, tools ask as usual, and in
unattended background runs sending messages or email, pushing, deploying,
deleting files outside temporary folders and Artifacts, and system changes wait
for approval through a push-notified input request; unanswered after 10
minutes, the step is skipped.

Those requests are answered in place: in Cantrip Agent's Home Background list
(the push opens it on that run; Tasks shows **Respond**) and in a header panel
in browser and Mac Remote, never by opening the hidden run as a tab. See
[background run input requests](remote-control.md#cantrip-agent-completion-notifications).
Local models keep these pauses whatever the setting. Questions the agent asks
you always reach you.

Background runs can't create or change tasks. Codex and Copilot Remote (ACP)
can run commands Cantrip never sees, so on them background runs fail closed
with an explanation and the Home chat follows the rules on its own.

## Artifacts

Deliverable files the agent saves in Home's guarded artifact folder appear
automatically in Artifacts and can be permanently deleted from the mobile app.
Images and videos show thumbnails (a video's poster frame about one second in,
with its duration), built on the Mac by the paired
`GET /api/v1/home/artifacts/{id}/thumbnail` route (JPEG of at most 600 pixels;
404 for documents, audio or unreadable media).

Sources get the remote-preview guards: regular single-link files below the
artifact folder, every folder opened without following symlinks, 20 MB and
64-megapixel limits, and videos decoded from a private copy with a 15-second
limit. Thumbnails are cached in `~/.cache/Cantrip/home/thumbnails/` until the
file changes or is deleted.

## Builds

Cantrip Agent's **Builds** tab lists the over-the-air install page in
`~/Sites/ota` (written by `ota-publish.py`) through the read-only
`GET /api/v1/home/builds` route: entries grouped by `page_key` (else bundle
id), builds newest first, with install links taken from each build's own
`manifest.plist`, plus `GET /api/v1/home/builds/{bundle id}/{folder}/icon`.
Folders without readable metadata, manifest or `app.ipa` are skipped and
counted; symlinks are never followed. Publishing and removal stay on the Mac.
