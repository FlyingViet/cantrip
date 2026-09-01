# Cantrip Plugins on Windows

Windows plugins use the same manifest shape as macOS Cantrip. Install each
plugin as a folder under:

```text
%APPDATA%\cantrip\plugins\<plugin-id>\
```

Every plugin requires `manifest.json`. Dashboard assets, scripts, and other
plugin-owned files remain inside that folder.

## Install the example

Open **Settings → Plugins**, click **Example**, expand the declaration list,
and approve the exact manifest hash before enabling or opening the dashboard.
Source users can instead copy `..\Examples\plugins\hello-dashboard` into the
plugin folder.

## Manifest

```json
{
  "name": "Example",
  "version": "1.0.0",
  "description": "Optional description",
  "panel": {
    "html": "panel.html",
    "title": "Example dashboard",
    "capabilities": ["cantripStatus", "cantripActions"]
  },
  "dataSources": {
    "today": {
      "command": "scripts/today.ps1",
      "args": ["--json"],
      "timeoutSeconds": 10
    }
  },
  "mcpServers": {
    "search": {
      "command": "node",
      "args": ["mcp-server.js"],
      "env": { "MODE": "local" }
    }
  }
}
```

Only `name` is required. Unknown fields are ignored for forward compatibility.

## Approval model

- The app hashes the raw `manifest.json` bytes with SHA-256.
- Approval is stored against that exact hash.
- Any byte change invalidates approval and makes the plugin inert.
- Enabled state is separate from approval; a plugin must have both to be active.
- Revoking approval also disables and closes the plugin.
- Panels, data-source commands, and MCP servers do not run before approval.
- The approval UI shows the panel, native capabilities, and complete declared
  command lines.

## Dashboard bridge

Approved dashboards receive:

```js
window.cantrip.sendPrompt("Summarize this project");
window.cantrip.log("Dashboard loaded");
window.cantrip.openURL("https://example.com");

const status = await window.cantrip.requestData("cantripStatus");
const data = await window.cantrip.requestData("today", { date: "2026-08-31" });
await window.cantrip.runAction("update");
```

### Built-in capabilities

| Capability | Access |
|---|---|
| `cantripStatus` | App version, backend availability, and update state |
| `cantripActions` | Fixed actions only: update, relaunch, open repository/log; source builds report build unavailable |
| `dailyBriefing` | Reserved for compatibility; not available on Windows yet |

`sendPrompt`, bounded logging, and validated HTTP(S) URL opening are always
available to an approved active dashboard. URL credentials, `file:`,
`javascript:`, and other schemes are rejected.

## Data sources

- Relative commands must resolve inside the plugin folder after symlink/junction
  resolution. Absolute commands are allowed but shown verbatim before approval.
- `.ps1` runs with non-interactive PowerShell; `.cmd`/`.bat` use `cmd.exe`;
  native executables run directly. The app never uses `shell: true`.
- Optional input must be a JSON object and is capped at 64 KB.
- Output must be a JSON object and is capped at 1 MB.
- Timeout is clamped to 1–60 seconds.

## Dashboard isolation

- Each plugin gets a separate, non-persistent Electron session.
- `sandbox` and `contextIsolation` are enabled; Node integration is disabled.
- Assets are served only through a scoped `cantrip-plugin://<id>/` protocol.
- Path traversal and symlink/junction escapes are rejected.
- A 256-bit per-window token plus dedicated `webContents` mapping authenticates
  bridge calls. The token is not exposed to page JavaScript.
- The preload is not injected into subframes; iframe bridge access is absent.
- A CSP allows plugin-owned scripts/styles and HTTP(S)/WebSocket dashboard
  connections while blocking arbitrary local-file access.

Plugins are trusted after explicit approval: dashboards can use the network,
and declared data/MCP processes run with the user’s permissions.

## MCP

Active plugin servers merge into:

```text
%APPDATA%\cantrip\plugin-mcp.json
```

Colliding names are preserved with a plugin-id prefix. Claude receives the
standard `--mcp-config` file; Codex receives escaped `mcp_servers.*` config
overrides. Copilot automatic MCP injection and the local-model MCP client remain
future parity work.

## Reloading

The plugins directory is watched recursively on Windows. Content edits reload
the dashboard; manifest edits invalidate approval and close privileged panels.
**Rescan** is always available as a deterministic fallback.
