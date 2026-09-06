[User Guide](README.md) / Updates and troubleshooting

# Update Cantrip or fix a problem

Start with the symptom below. Avoid reinstalling, deleting caches, or resetting
permissions before checking the specific error.

## Update on Mac

**Finish or stop important work first.** Updating rebuilds and relaunches
Cantrip, interrupting its running process and Remote connections.

1. Look for **New update** or **Rebuild needed** in the toolbar.
2. Click it and watch the pull/build output in the transcript.
3. Wait for the build to finish and the app to relaunch.
4. Press **Option+Space** to reopen it. Reconnect Remote clients if needed.

**New update** means the remote repository is ahead. **Rebuild needed**
means your checkout is newer/different than the running app.
Pulling source or running `make build` alone does not replace and relaunch the
app bundle.

For a manual update, use Terminal, not a Cantrip task that you need to keep
alive. The following assumes the standard installation path:

```sh
cd ~/Coding/Cantrip
git status --short
```

If this shows changes, preserve/reconcile your work before updating; do not
discard it just to make the command succeed. With a clean checkout:

```sh
git pull --ff-only
make run
```

`make run` builds the app bundle, quits the old app, and opens the new one.
If a pull or build fails, stop at that error instead of assuming you are
running the new version.

The in-app updater attempts to stash tracked local changes and restore them.
If it reports a restore conflict, inspect `git status` and `git stash list`
and reconcile the changes before proceeding. Do not delete the stash blindly.

## Update on Windows

Open **Settings > Updates**, choose **Check for updates**, then **Download**
when a release is offered, and **Restart to update** when ready.
The installed app needs the updater included in version 0.2.0 or later.
Older installations can use the current installer from
[GitHub Releases](https://github.com/FlyingViet/cantrip/releases).

## The panel does not appear

**Mac:** check for the Cantrip sparkle in the menu bar. Use its
**Toggle (Option+Space)** item. If the app is not running:

```sh
open ~/Coding/Cantrip/Cantrip.app
```

If the menu works but the shortcut does not, check for another app using
Option+Space. If neither works, read the log using the command below.

**Windows:** if Alt+Space is taken by PowerToys Run or another launcher,
Cantrip reports the conflict and uses **Ctrl+Space**. Release the conflicting
shortcut, then click **Retry Alt+Space** in Cantrip or its tray menu.

## The backend is missing or not authenticated

1. Open Terminal or your backend's supported shell.
2. Run your selected CLI directly: `claude`, `copilot`, or `codex`.
3. If the command is missing, install that backend using
   [the backend guide](backends.md).
4. Complete the CLI's sign-in and confirm it can answer.
5. Return to Cantrip and choose that same backend.

On Mac, if it works in Terminal but is not detected in Cantrip, use
`command -v` to find its executable and fill in the backend path in Settings.
Do not paste a login token into the path or model field.

## A model, effort, or context tier is rejected

Return to **Default** where offered and retry a short text question. Use only
model IDs and options supported by your installed CLI and account.
For Copilot, the model refresh control can rediscover available choices.
Provider quota and entitlement errors cannot be fixed by selecting a larger
context window.

## The agent answers but will not run tools

Check [action permissions](privacy-and-memory.md#let-an-agent-make-changes).
Safe mode can deny commands or edits rather than prompting for approval
inside this non-interactive workflow. Enable only the permissions needed for
the task; do not treat every tool failure as a reason to allow everything.

## The local model cannot connect

1. Confirm the model server is running.
2. Check **Base URL** includes the correct host, port, and `/v1`.
3. Check **Model** exactly matches an ID exposed by that server.
4. Supply its API key only if required.
5. Try the server's own client or `/v1/models` endpoint.

`localhost` and `127.0.0.1` mean the machine running Cantrip. If your server
is on another computer, use that computer's reachable, appropriately secured
endpoint. If text works but tools do not, confirm compatible tool calling.

## An image, selection, or screen capture is missing

For local Mac attachments, look for the staged chip before sending and choose
Claude, Copilot, or Codex rather than Local Model. For automatic screen
context, check both the toolbar toggle and macOS Screen Recording permission,
then relaunch if required. Hide/reopen Cantrip to get a fresh screenshot.

For AgentGateway, both apps must support uploads. Follow
[the exact picker and host requirements](remote-control.md#send-a-photo-or-screenshot-from-agentgateway).
Updating the source without relaunching the built host will not add image
support to a running old app.

## A request seems stuck

1. Open **Progress** and **Terminal** to see whether a tool is still working.
2. Click **Stop** if you want to cancel. The menu bar also has
   **Stop Current Request**.
3. Inspect completed work before resubmitting a command that changes things.
4. After a crash, use the offered resume control rather than blindly starting
   the whole task again.

**Escape** and **Hide Panel & Overlays** only dismiss UI. Cantrip also has a
15-minute inactivity watchdog; a quiet backend may eventually be canceled.

## Remote will not connect

Work through these in order:

1. On the host, confirm Cantrip is running, the user is signed in, the Mac
   is awake, and **Remote control daemon** is enabled without an error.
2. Recopy the current **pairing token**. Regenerating it invalidates all
   previous pairings.
3. For LAN: put both devices on the same reachable network, allow Local
   Network access, and check host firewall rules. Guest/client isolation and
   blocked Bonjour discovery can prevent connection even on similar Wi-Fi
   names.
4. For fallback: confirm Tailscale is connected on both devices, run
   `tailscale serve status` on the host, and compare its HTTPS origin and
   loopback port with the saved settings.
5. Confirm the session is not private. Select an open session or create one.
6. Update and relaunch the host if the client reports incompatible data or
   missing image support.

Do not fix a connection problem by switching to public HTTP, exposing the
loopback port to the internet, or enabling Tailscale Funnel.

## Permissions are requested again after a rebuild

Changing the app's signing identity can invalidate macOS grants. From your
Cantrip checkout, inspect the signature:

```sh
codesign -dvv Cantrip.app 2>&1 | grep -E 'Signature=|Authority=|TeamIdentifier='
```

If it reports an ad-hoc signature rather than a stable certificate, run
`make cert`, resolve any certificate/trust error, then rebuild with `make run`
after finishing active work. Review Cantrip's permissions again in System
Settings. Avoid resetting all permissions as a first troubleshooting step.

## Find diagnostics for a bug report

On Mac:

```sh
tail -n 80 ~/Library/Logs/Cantrip.log
cantrip runs
```

Include your OS version, backend, the exact error, the relevant build identity
from the startup log, and steps to reproduce. Redact pairing tokens, API keys,
private prompts, personal paths, and image content before sharing logs or
screenshots. Do not publish an entire memory vault or run journal.
