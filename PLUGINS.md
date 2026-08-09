# Cantrip Plugins

Cantrip supports user-written plugins in two layers:

1. **UI panels** — an HTML/JS dashboard rendered in a side pane of the
   launcher (toggled from the puzzle-piece **Extensions** button in the
   toolbar). Good for home-automation dashboards, status boards, quick
   controls — anything you'd want to glance at or click next to the
   transcript.
2. **MCP servers** — standard [Model Context Protocol](https://modelcontextprotocol.io)
   servers whose tools become available to the models. One declaration
   works across backends:
   - **Claude Code**: passed via `--mcp-config` at process start.
   - **Codex**: passed as `-c mcp_servers.*` TOML config overrides.
   - **Local model (OpenAI-compatible)**: connected by Cantrip's built-in
     MCP client and exposed as function tools.
   - **Copilot**: the Copilot CLI has no config-injection flag; register
     servers with it directly (`copilot mcp add NAME -- COMMAND ARGS...`,
     stored in `~/.copilot/mcp-config.json`).

A plugin can ship either layer or both.

## Anatomy

One plugin = one folder in `~/.config/cantrip/plugins/`:

```
~/.config/cantrip/plugins/
  my-plugin/            ← folder name is the plugin id
    manifest.json       ← required
    index.html          ← your dashboard (if you declare a panel)
    ...anything else your plugin needs
```

### manifest.json

```json
{
  "name": "Home Dashboard",
  "version": "1.0",
  "description": "Lights, temperature, and quick scenes for the house.",
  "panel": {
    "html": "index.html",
    "title": "Home"
  },
  "mcpServers": {
    "homeassistant": {
      "command": "npx",
      "args": ["-y", "some-hass-mcp"],
      "env": { "HASS_TOKEN": "..." }
    }
  }
}
```

Every field except `name` is optional. `panel.html` is resolved relative
to the plugin folder and must stay inside it. Unknown fields are ignored,
so you can keep your own metadata in the manifest.

## The `window.cantrip` bridge

Panel pages get a small API injected before your scripts run:

```js
cantrip.sendPrompt("dim the living room lights");  // submits a query to the
                                                   // active Cantrip session
cantrip.log("refresh took 120ms");                 // writes to Cantrip.log
```

Everything else is ordinary web platform: `fetch()` works against local
and remote endpoints (pages are loaded with file-URL CORS relaxed), and
in-page state is yours to manage. There is deliberately no shell or
filesystem access from the page — if you need real tools, declare an MCP
server and let the model call it, or `cantrip.sendPrompt(...)` and let
the agent do the work with its own permission gates.

## Install, approval, and lifecycle

- Drop the folder in `~/.config/cantrip/plugins/` (the Extensions popover
  has an **Open Plugins Folder** button), then hit **Rescan**.
- Flipping a plugin on the first time shows an approval card listing
  exactly what the manifest declares — the panel file and every MCP
  server command line. Nothing runs before you approve.
- Approval is bound to the manifest's SHA-256. Any edit to manifest.json
  (new server, changed command) flips the plugin back to
  "needs approval" and it goes inert until you re-review it.
- MCP changes apply to the *next* model process: the merged config at
  `~/.config/cantrip/plugin-mcp.json` is regenerated on every toggle,
  and backends read it when they spawn. The local-model backend loads
  MCP servers once per app run, so toggles there apply after a Cantrip
  restart.
- Server names are sanitized to `[A-Za-z0-9_-]`; if two plugins declare
  the same server name, the later one (alphabetical by plugin name) is
  auto-prefixed with its plugin id.

## Security model

Plugins are code you chose to install, running with meaningful reach:
panel pages have unrestricted network access (CORS is relaxed so
dashboards can talk to local devices that don't send CORS headers, which
also means a page may be able to read local files and send them over the
network), and MCP servers are real processes running as your user. Treat
installing a plugin like installing any app. The approval card shows the
exact MCP command lines so you can eyeball them — read them, especially
for plugins you didn't write.

What Cantrip does enforce: nothing runs before approval, approval dies
with any manifest edit, the `window.cantrip` bridge only answers the
plugin's own page (an embedded remote iframe never gets it), and the
panel entry file must live inside the plugin folder. `Reset Panel Size`
does not touch plugins; disable one in the popover, or delete its folder
to remove it.

## Starter example

`Examples/plugins/hello-dashboard/` in this repo is a working panel
plugin: a clock, a fetch demo, and a button that sends a prompt to the
session. Copy it into `~/.config/cantrip/plugins/`, enable it in the
Extensions popover, and edit from there:

```bash
cp -r Examples/plugins/hello-dashboard ~/.config/cantrip/plugins/
```
