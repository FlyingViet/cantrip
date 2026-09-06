[User Guide](README.md) / Windows

# Install and use Cantrip on Windows

**You need:** Windows 10/11 x64 and one installed, authenticated CLI backend.
The Windows source workflow requires Node.js 20.19+.
Cantrip for Windows is not yet a full copy of the Mac app.

## Install a release

1. Open [Cantrip Releases](https://github.com/FlyingViet/cantrip/releases).
2. Download the Windows `Cantrip Setup <version>.exe` asset from a release
   that includes one.
3. Run the installer and open Cantrip.
4. Install and sign in to one backend using
   [the backend guide](backends.md#install-and-sign-in-to-a-cloud-backend).
5. Press **Alt+Space**, open the **gear**, and select that backend.
6. Keep **Allow agent actions** off initially.
7. Ask `Explain what a working directory is in two sentences.`

**Expected result:** the answer streams into the panel.
Locally built/unsigned installers may show a SmartScreen warning. Verify the
download's source and publisher before deciding whether to run it; do not
disable Windows security protections globally.

## Run from source instead

Install Git and Node.js 20.19+, then run in PowerShell:

```powershell
git clone https://github.com/FlyingViet/cantrip.git
cd cantrip\windows
npm ci
npm run dev
```

Leave that development command running while using the app. If the checkout
already exists, use it rather than cloning over it.

## Handle a shortcut conflict

If another launcher owns **Alt+Space**, Cantrip reports the conflict and uses
**Ctrl+Space**. Change or disable the other app's shortcut, then use
**Retry Alt+Space** in Cantrip or its tray menu.

## Everyday controls

| Goal | What to do |
|---|---|
| Launch an app | Type its name, select the suggestion, press Enter |
| Force an AI question instead of launching a suggestion | Press **Ctrl+Enter** |
| Calculate/convert | Type `142 * 8.5` or `10 km to miles` |
| Run a PowerShell command directly | Type `!git status` in the intended working directory |
| Change backend/model/effort | Open the **gear** |
| Let the agent make changes | Review and enable **Allow agent actions** in Settings |
| Update an installed release | **Settings > Updates** |

Direct `!` commands are explicit execution requests, not safe-mode previews.
Agent action mode grants autonomous CLI permissions; enable it only for work
you trust.

## Capture your screen

1. Arrange the windows you want to share.
2. Click the **screen-capture** control (the square/screen icon).
3. Review the display previews and remove any you do not want.
4. Add your question, then send it.

Cantrip captures available displays for that request and removes its transient
capture files after completion/cancellation, quit, or startup cleanup after a
crash. This is separate from any retention by your backend/provider.
Clipboard/drop file attachments are not yet implemented on Windows.

## Install plugins

Open the **Extensions** control, then **Settings > Plugins** to open the
plugins folder, rescan, review declarations, approve, and enable a plugin.
Windows dashboards open in a separate sandboxed window, not a Mac-style side
pane. Follow the [Windows plugin guide](../windows/PLUGINS.md).

## What is and is not available

| Available now | Not yet available on Windows |
|---|---|
| App launching, math, conversions | Indexed file search |
| Claude, Copilot, and Codex CLI backends | Local OpenAI-compatible backend |
| Streaming output and cancellation | Persistent session tabs/history and durable run recovery |
| Explicit PowerShell commands | Persistent session terminal |
| Screen context with previews | Clipboard/drop file attachments |
| Approved plugins and some MCP integration | Mac Remote control/image-upload hosting |
| Settings, launch at login, in-app updates | Memory vault, voice, council, tutorial overlays, slash skills, CLI bridge |

For implementation status, see the [parity checklist](../windows/PARITY.md).
For a failure in the core workflow, see
[troubleshooting](updating-and-troubleshooting.md).
