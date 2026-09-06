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
| Do this next | Type a follow-up, then **Return** | Adds it to the queue |
| Stop this approach and do something else | Type new instructions, then **Command+Return** | Interrupts and redirects the active run |
| Add information without interrupting | **Option+Return** with Claude Code | Injects into the current turn |
| Cancel without sending a new prompt | Click **Stop** | Cancels the active run |

Check the visible queue before walking away. Remove unwanted queued items
with their remove control. Hiding the panel does not cancel the task.
Inject is a Claude-specific behavior; use Queue or Redirect with other
backends.

## Recover after a crash or interruption

1. Reopen Cantrip.
2. Read the recovery message and restored partial output.
3. If offered, select **Resume from where it left off**.
4. Check what already completed before repeating commands with side effects.

Cantrip records normal runs in an append-only journal and can restore partial
work. Resume is not a guarantee that an external command can continue at the
exact CPU instruction where it stopped. Private sessions do not have this
durable recovery.

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
