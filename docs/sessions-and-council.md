[User Guide](README.md) / Sessions and council

# Manage conversations and compare models

**Platform: macOS.** Session tabs, durable recovery, and council mode are not
yet available in the Windows app.

## Start a separate task

1. Press **Command+T** to create a local session.
2. Use the **folder** button to choose its working directory.
3. Enter the task.
4. Open another tab to work on something else while the first task runs.

Each tab has its own conversation and terminal. Backend/model settings are
shared; do not rely on switching tabs to restore a different configured model.

**Command+1** selects the pinned **Remote** tab. **Command+2** selects the
first local session, followed by **Command+3** through **Command+9** for later
local sessions. Click tabs when more are open.

Drag a session tab onto another to move it, or use **Move Tab Left/Right** in
its right-click menu. The Remote tab stays pinned first. The order survives
restarts without switching conversations or interrupting work, and syncs to
Cantrip Remote and Cantrip Agent. Dragging a tab label does not move the
launcher window; dragging the window background still does.

With sections (see [Group tabs into sections](remote-control.md#group-tabs-into-sections)),
the strip shows each section as a pill before its tabs; ⌘2-⌘9 follow that
order. Click a pill to collapse it (busy tabs stay), drag it onto another to
reorder, or drop a tab on it to file the tab. Right-click a pill for Rename,
New Tab Here, Move Section Left/Right, Delete (asks first if it has tabs; its
tabs move back to Tabs and stay open), New Section and Edit Sections. The
folder button after **+** makes an empty section. **Move to Section** in a
tab's right-click menu files it under one.

## Start over or return to an older session

Right-click a local session tab for **Rename Tab** or **Lock Tab**. Names can
contain up to 80 characters; leaving the name blank restores the automatic
label. Names and locks survive restarts, including for empty tabs, and custom
names appear in History.

A locked tab shows a lock instead of its close button. **Command+W**,
**Command+N**, and remote close/reset requests cannot close it or clear its
conversation. Choose **Unlock Tab** first. Locking does not stop work, prevent
new messages, or disable Stop, Resume, or queue removal. It is protection
against accidental deletion, not an access-control password.

Private tabs retain their name and lock only in memory; enabling private mode
still scrubs saved data, and private tabs are never exposed remotely.

| Goal | Action |
|---|---|
| Start a new task while keeping the current conversation | **Command+T** |
| Reset the conversation in the current local tab | **Command+N** |
| Close a local tab | Its **x** or **Command+W**; a normal session is archived |
| Reopen an archived session | Click **History**, then **Open** beside the session |
| Find recent archived sessions | Open the **Sessions** button's menu |

Use a new tab, rather than resetting, if you want to preserve an ongoing
conversation. Closing a tab cancels its active run and archives its transcript;
it is not a way to keep a job running in the background. Switch tabs or hide
the panel instead. Closing is not the same as deleting a session permanently.
The History view's delete control is permanent; private sessions are not
archived for later recovery.

### Start fresh but keep the history

When a tab keeps failing because of something earlier in its conversation,
right-click it and choose **Start Fresh** (also next to **Model Settings** in
Mac/browser Remote and Cantrip Agent). The tab keeps its name, folder, model
settings, lock and every visible message. A divider, *Started fresh — earlier
messages aren't sent to the model*, marks the point: the next prompt starts a
new model session with none of the earlier turns, and later context recaps
only include turns below the divider. Earlier messages stay readable. It works
on locked tabs, but not while the tab is running, has queued messages or a
running shell command. Cantrip Home keeps its own conversation and has no
Start Fresh.

If the same model error ends two attempts in a row (for example a model
declining, then `400 The requested model is not supported`), the error row
offers **Start Fresh** and **Change Model**.

## Send instructions while the agent is busy

| Goal | Mac shortcut | What happens |
|---|---|---|
| Send naturally | Type a message, then **Return** | Auto decides from the message and current task |
| Always do this next | Choose **Queue**, then **Return** | Adds it to the queue without classification |
| Stop this approach and do something else | Type new instructions, then **Command+Return** | Interrupts and redirects the active run |
| Add information without interrupting | **Option+Return** with local Copilot or Claude Code | Sends context without stopping the current task |
| Cancel without sending a new prompt | Click **Stop** | Cancels the active run |

Check the visible queue before walking away. Remove unwanted queued items
with their remove control. Hiding the panel does not cancel the task.
Manual delivery choices apply to one message, then return to **Auto**.
Inject uses local Copilot's native `session.send` immediate mode or Claude's
streaming input. Other backends (including Copilot Remote/ACP), council runs,
and sessions still preparing their context queue the message instead.

Copilot applies steering before its next model request, after any already
committed tool calls. If that opportunity has passed, Copilot processes the
context immediately after the current turn. **Accepted** means Copilot received
the message, not that the model has already consumed it. Queue still means
"do this next"; Redirect and Stop remain explicit interruptions.

Each local Copilot tab keeps its own native SDK session across successful
turns. Node.js and a recent Copilot CLI with a matching bundled SDK/runtime
are required (exercised with CLI 1.0.83). A missing/incompatible runtime is
reported rather than silently replaying the task with another transport.
Changing model, effort, context tier, action policy, subagent setting, or working directory takes
effect on the next request by starting a fresh runtime with recent conversation
context. Stop/reset closes the runtime; checkpoint recovery remains Cantrip's
safety net after an interruption.

Non-private injections are journaled before submission and sent in order.
Acknowledgements and native message IDs are saved. An uncertain delivery stays
visible in the transcript and is not automatically resent. Recovery retains
the added instructions and steps from before the injection; it must still
verify which external actions completed.

### How Auto decides

Idle sessions send immediately, with no router call. During a single-agent
run, a small independent inference reads the new message, current task,
bounded recent conversation, current activity, and pending prompts. It has
no tools, repository exploration, or task-execution permissions.

- Useful context is injected where supported (confidence at least 0.80).
- Clear corrections or replacement tasks redirect (confidence at least 0.95).
- Clear cancellation stops the current task but keeps pending messages on hold.
- Follow-up tasks, questions, ambiguity, and router errors stay queued.

Decisions must cite text from the new message. This is semantic classification,
not keyword matching: "stop the server" while editing documentation is not a
request to cancel the agent. The status line explains the decision or fallback.
Model confidence is not a guarantee; explicit Stop and manual overrides remain
available.

Copilot uses `claude-haiku-4.5` through the authenticated CLI (0.33 premium
requests a call); Claude uses `haiku`. Both run with tools and customizations
disabled, outside the repository. A JSON answer wrapped in a code fence or
followed by an explanation still counts. The Local Model lane uses only its
configured OpenAI-compatible endpoint and model, never a cloud fallback.
Routing can consume provider usage. The inference deadline is 12 seconds (45
for child-tab plans, which are made while the tab works). Codex and Copilot Remote (ACP) currently queue with an
explanation because they do not expose an isolated tool-free router here.
Councils, shell/slash commands, and messages over 6,000 characters also queue
without classification.

Messages enter the durable queue before routing (except in private sessions).
Late results cannot interrupt a newer or completed run. A newer submission
supersedes an unfinished routing decision; the earlier message remains queued.
Cancel/reset/removal invalidates pending decisions. Staged files and selected
text are bound to their submitted message rather than a later draft.

### Parallel requests

When a local Copilot tab is busy and you send something independent of its
current task (a side question, a status check, work in another project), Auto
hands it to the running agent, which starts a background `side-*` subagent and
keeps working. The subagent appears in the monitor like any other, and its
answer is posted in the same chat. If the main task finishes first, the run
stays open and Cantrip wakes the agent to report. Requests that depend on or
touch the same files or state as the current task still queue. This needs
subagents and tools enabled; other backends queue as before.

### Combined queued messages

Before the next queued message runs, the same tool-free router checks which
later queued messages belong with it (refinements, corrections or next steps
for the same task) and runs them together in one turn; unrelated messages keep
their order and run after. The decision is made while the current task is still
working, so the next turn starts without waiting. Each message still appears as
you wrote it, and the run journal claims all of them at once so recovery never
repeats one. Commands (`!`, `/`), councils, Private Local and automated Home
runs stay one at a time.

### Send now

A queued message has a **Send now** action on the Mac (the arrow button on its
row), in Cantrip Agent and in Cantrip Gateway Mac. It delivers the message
without waiting for the current work. A busy Copilot task moves whatever step
it was blocked on (a long command or a synchronous agent) to the background and
keeps background agents running. Commands, councils and backends without live
input redirect instead. See [Send now details](remote-control.md#see-queued-prompts-in-cantrip-agent).

### Child tabs

A queued message that doesn't depend on the current task can run in parallel
in a **child tab**: its own tab, nested under the parent, with its own git
worktree and branch, merged back when it's done.

- **Plans:** while a tab works, the same tool-free router suggests a plan for
  each queued message, shown as a chip on its row: *Independent: can run in a
  child tab*, *Batched: same tab-list code* (it overlaps the current task or
  another queued message, so it runs with it), *Waits: releases run one at a
  time*, or *Runs after the current task*.
- **Auto-fork:** a message sent with **Auto** delivery that the plan rates
  independent starts in a child tab on its own, as soon as routing has left it
  in the queue. Cantrip first checks what it knows for sure: the message's
  likely files (from the plan) must not be ones the parent has uncommitted or
  edited in its recent replies, or that a running child tab expects to change,
  and the parent must work in a git repository. Otherwise it stays queued and
  its chip says why (*Runs after the current task: it also changes
  CantripHome.swift*). An explicit **Queue** still means "after this"; the
  caps and the rules below apply, and a request the router sends to a
  background agent (*parallel*) still goes there. Its card says *Started
  automatically*. Turn it off in Settings (**Start independent queued messages
  in child tabs automatically**).
- **Run in this tab instead:** while a child works, its card can send the
  request back: the child stops, its branch and worktree are deleted, and the
  request goes to the front of the parent's queue (it won't be auto-forked
  again). The card then reads *Moved back to … 's queue*.
- **Start one:** **Run in Child Tab** on a queued row (the branch button on the
  Mac, in Cantrip Agent's and the Gateways' queue sheets, the button in the
  browser). The message leaves the queue and starts at
  once in a new tab after its parent, in the parent's section and with its
  model settings. The parent stays selected. The child gets the request as
  written plus a short brief (its worktree and branch, the parent's latest
  progress, the shared-resource rules), not the parent's history.
- **Worktree:** when the parent works in a git repository (its folder, the
  repository the plan names, or the one its recent commands used), the child
  gets `~/.cache/Cantrip/worktrees/<id>` on `cantrip/child/<title>-<id>`,
  branched from the parent's HEAD and locked so storage cleanup skips it.
  Without a repository the child shares the folder and has nothing to merge.
- **Watch and steer:** open the child from its card or the tab list to watch
  it, send messages or answer its questions. It can't start children of its own
  and can't be moved away from its parent.
- **Merge back:** when the child finishes, Cantrip commits anything it left
  uncommitted, then waits until the parent is idle (never mid-turn, and before
  the parent's next queued message). It checks the merge with
  `git merge-tree` first, which touches nothing, then runs
  `git merge --no-ff` into the parent's branch and removes the worktree and
  branch. A merged child closes; its card still opens the conversation.
- **Conflicts:** nothing is written. The card asks: **Keep both, then run the
  tests (Recommended)** queues a merge request in the parent tab, which resolves
  it and commits; **Keep main's version** or **Keep the child's version** merge
  with that side winning the conflicting lines; **Leave it unmerged** keeps the
  branch for later (**Try Again** or **Discard**). If uncommitted edits in the
  parent's checkout touch the same files, or a merge, rebase, cherry-pick or
  revert is unfinished there, the merge waits and tries again after the
  parent's next turn; Cantrip never aborts work it didn't start. While a merge
  runs (seconds), new messages to the parent wait in its queue.
- **Your work is kept:** a child's worktree is deleted only once everything in
  it is committed and merged (or you choose **Discard**). If Cantrip can't
  commit the child's last changes (a signing prompt, say), the card says so and
  keeps them; commit them, then **Try Again**.
- **The card:** one per child in the parent, updated in place: "Child tab ·
  title", a tag with the request that expands to the request, the child's
  replies and its files with line counts, the summary, and its state (Working,
  Needs your answer, Merged into main · 4 files +169 −9, Merge conflict, …).
- **What the parent's model sees:** only one line per child, once it settles,
  added to the parent's next message: its title, request, state, summary and
  files. The card and the child's conversation are display-only.
- **Guardrails:** at most 2 child tabs per tab and 3 overall. Children run
  with the attended guardrail. Simulator runs (`xcodebuild test`, `simctl`)
  take turns across children and wait for any other Simulator build or test on
  the Mac. Restarting or deploying Cantrip, TestFlight uploads, releases and
  device installs are refused in a child; it says so in its Summary and the
  parent runs them after the merge. Home, Private Local and Private tabs can't
  start child tabs.

Records live in `~/.cache/Cantrip/child-tabs.json`; after a relaunch, running
children resume like any tab and finished ones merge at the parent's next idle
point.

### Background waiters

After starting a long external build, TestFlight upload, download, or similar
job, the agent can hand passive monitoring to a dedicated watcher and continue
independent work. The watcher stays visible in the subagent monitor; when it
finishes, Cantrip wakes the same run and continues from where it paused instead
of making you send another message. Once the agent's own turn ends, only
background work remains, and new messages go straight to the agent instead of
waiting for the watcher.

## Recover after a crash or interruption

When Cantrip reopens after a quit, crash or update, each tab picks up where it
stopped: the run it was in the middle of resumes from where it left off, then
the messages queued behind it are sent in order. Tabs start a few seconds apart.
If a run is cut off by relaunches twice in a row, Cantrip stops resuming it on
its own and offers **Resume from where it left off** instead.

A dropped network doesn't fail the task either. A run that fails while the Mac
is offline, or with a connection error such as a DNS failure, waits until the
network has been back for a few seconds, then continues the same task. Queued
messages wait too instead of failing one by one. Messages you send meanwhile
queue behind the interrupted task; use **Redirect** to replace it. After six
connection retries in one run, Cantrip reports the failure as usual.

To check on recovered work:

1. Read the recovery message and restored partial output.
2. If offered, select **Resume from where it left off**.
3. Check what already completed before repeating commands with side effects.

Cantrip records normal runs in an append-only journal and can restore partial
work. Resume is not a guarantee that an external command can continue at the
exact CPU instruction where it stopped. Private sessions do not have this
durable recovery.

Journal events are immutable snapshots submitted to an ordered background writer;
streamed-event encoding, file writes, and `fsync` no longer run on MainActor.
The writer synchronizes at durable boundaries and at least once per second
while processing unsynchronized output. Backend starts, completion notifications,
automatic queue advancement, and successful Remote mutation replies wait for the
relevant writes. **Saving run...** means completion is waiting for storage,
not that the agent is still working. Stop/redirect remains immediate, and a late
disk callback cannot finish a newer run.

Write/encoding/synchronization errors stop further writes to that journal,
surface a visible run-history error, suppress success notification and automatic
queue advancement, and make affected Remote mutations report uncertainty rather
than success. The CLI also waits for durable terminal events before `done`.
Unacknowledged output still queued in memory can be lost in a crash; replay
retains complete records and repairs a truncated tail before appending again.
Normal exit drains pending journal writes. Opening/restoring journals and
privacy deletion retain synchronous ordering barriers; deletion cannot be undone
by an older queued write. This change does not move every other app persistence
operation off MainActor.

For a text timeline in Terminal:

```sh
cantrip runs
```

Then run `cantrip runs` followed by a session or run ID from the list.

## Ask several models with council mode

**Before you start:** configure and authenticate each backend you plan to use.
Each advisor call and the final synthesis can consume provider usage.

1. Choose the backend/model you want to produce the final answer in Settings.
   This is the **chair**.
2. Open the toolbar's **Council mode** menu, the group-of-people icon.
3. Under **Add a seat**, choose a backend and model. Repeat until there are
   at least two seats; the limit is eight.
4. Enable **Council mode**.
5. Set **Convene for** to **Planning & review only** for normal use. Choose
   **Every message** if you want a council on every prompt.
6. Ask a planning/review question, such as `Compare these two approaches and
   recommend one. Do not edit files.`

**Expected result:** advisor answers appear in separate panes, then the chair
produces a joint verdict. With **Planning & review only**, implementation
requests can go directly to a single worker instead.

Advisors use read-only modes, but the chair still follows your action
permissions. Turn council mode off when you no longer want extra model calls.
Click a seat in **Seats (click to remove)** to remove it.
