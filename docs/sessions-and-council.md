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
Changing model, effort, context tier, action policy, or working directory takes
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

Copilot uses `gpt-5.4-mini` through the authenticated CLI; Claude uses `haiku`.
Both run with tools and customizations disabled, outside the repository.
The Local Model lane uses only its configured OpenAI-compatible endpoint and
model, never a cloud fallback. Routing can consume provider usage. The inference
deadline is 12 seconds. Codex and Copilot Remote (ACP) currently queue with an
explanation because they do not expose an isolated tool-free router here.
Councils, shell/slash commands, and messages over 6,000 characters also queue
without classification.

Messages enter the durable queue before routing (except in private sessions).
Late results cannot interrupt a newer or completed run. A newer submission
supersedes an unfinished routing decision; the earlier message remains queued.
Cancel/reset/removal invalidates pending decisions. Staged files and selected
text are bound to their submitted message rather than a later draft.

## Recover after a crash or interruption

1. Reopen Cantrip.
2. Read the recovery message and restored partial output.
3. If offered, select **Resume from where it left off**.
4. Check what already completed before repeating commands with side effects.

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
