[User Guide](README.md) / Everyday tasks

# Everyday tasks

**Platform: macOS.** For Windows controls and limitations, see
[the Windows guide](windows.md).

## Open or switch to an app

1. Press **Option+Space**.
2. Type an app name, such as `safari`, or `open chrome`.
3. Check the app suggestion, then press **Return**.

**Expected result:** the selected app opens, or comes to the front if it is
already running. To ask the AI about that text instead, use
**Command+Return** when no run is active.

## Calculate or convert a value

Type `142*8.5`, `10 km to miles`, or `72 f to c`.
The instant answer appears without an AI request.

## Find and open a file

1. Type part of the filename.
2. Look for file results below the input.
3. Click a result to open it, or use its **Reveal in Finder** control.

Results come from Spotlight. An unindexed file may not appear; use Finder
to locate it instead. To ask about a file's contents, attach it using
[these steps](files-and-screen-context.md#attach-a-file-or-image).

## Work in a project folder

1. Open a new session with **Command+T**.
2. Click the toolbar's **folder** button.
3. Select your project folder.
4. Hover the folder button to check the session's full working-directory path.
5. Enter your request.

If the folder is a Git repository, **Git quick actions** become available.
They include **Summarize repo status**, **Commit message from staged diff**,
**Review uncommitted changes**, and **Review branch vs default**. These submit
prompts to the agent; inspect the result rather than assuming a Git operation
has occurred.

## Run an exact shell command

Type `!pwd` and press **Return** to print the current session's directory.
The `!` prefix runs a shell command directly instead of asking the AI.

For a persistent shell:

1. Click **Terminal**, the toolbar's `>`-in-a-square icon.
2. Type a command at the shell prompt and press **Return**.
3. Use **Up/Down** for command history and **Control+C** to interrupt.

Manual shell state, such as `cd` and environment variables, persists in that
session's terminal. Use the **folder** button when changing the agent's
session working directory; do not assume a terminal `cd` changes the folder
shown in the toolbar.

**Important:** `!` commands, terminal commands, and `/skills` are explicit
execution requests. Turning off agent action permissions does not turn them
into previews.

## Ask Cantrip from Terminal

1. Install Cantrip with `./install.sh` if you have not already done so.
2. Open a new Terminal window so the installer's PATH change is loaded.
3. Change to the folder you want the CLI to use, then run:

```sh
cantrip "Explain what a working directory is."
```

To use a particular backend, or ask about an existing text file:

```sh
cantrip --backend copilot "Explain this error log." < build.log
```

Replace `build.log` with a file you intend to share. Supported backend values
include `claude`, `copilot`, `codex`, and `local`; configure/authenticate the
selected backend first.

**Expected result:** the answer streams to Terminal. The CLI uses your shell's
current directory and its own conversation continuity, not the selected panel
tab. It uses the running app or tries to launch the checkout's `Cantrip.app`.
If `cantrip` is not found, try `~/.local/bin/cantrip` and check your shell PATH.

## Use voice

1. Click the **microphone** beside the input to start a voice conversation.
2. Allow Microphone and Speech Recognition access if macOS asks.
3. Speak your request and pause. Voice mode sends it, speaks the reply, and
   listens for a follow-up.
4. Click the microphone again to stop the voice conversation.

Use the text field if permission is denied or speech is not recognized.
Do not start voice mode near conversations you do not want submitted.

## See what the agent is doing

Click **Progress**, the sidebar icon, to see tool steps. Expand a step to
inspect available input, output, and file changes. **Usage**, the chart icon,
shows available backend usage figures; an unavailable quota is not zero usage.

Copilot shows the account-wide included allowance used/remaining, reset date
(in your local time), additional-usage status, and snapshot freshness. Install
an up-to-date Copilot CLI and Node.js on the Mac and sign in to Copilot.
Token/AI-credit plans show **AI credits used / total**, with used credits calculated
as total minus remaining and additional usage reported separately. Percentages
appear as a secondary usage progress bar. Amounts use the account's reported credit units
directly, with up to two decimal places; positive amounts below `0.01` show
`<0.01`. Missing amounts stay unavailable rather than being estimated from
rounded percentages. Legacy request plans retain request labels.
Refresh is shared with AgentGateway and limited to once a minute. Missing or
failed readings are marked unavailable/stale, never assumed to be zero usage.
Model-specific or short-term throttling can still apply with budget remaining.

File-diff **Revert** controls can discard changes to that file. Review and
back up work before using them; they are not a general undo history.

## Keep the panel visible

Click **Pin** to keep Cantrip visible while you click another app. Click it
again to unpin. Drag the panel edge or a pane divider to resize the workspace.
Settings includes a **Panel opacity** slider.

**Escape** hides the panel and overlays; it does not stop background work.
Use the **Stop** button to cancel a run.

Next: [manage sessions](sessions-and-council.md) or
[learn the shortcuts](keyboard-shortcuts.md).
