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
    "title": "Home",
    "capabilities": ["dailyBriefing"]
  },
  "dataSources": {
    "status": {
      "command": "bin/status",
      "args": ["--json"],
      "timeoutSeconds": 15
    }
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
cantrip.openURL("http://homeassistant.local:8123"); // opens an HTTP(S) page
                                                   // in the default browser
const calendar = await cantrip.requestData("dailyBriefing.calendar");
const results = await cantrip.requestData("media", {
  action: "search",
  query: "Arrival"
});
await cantrip.runAction("openLog");
```

Everything else is ordinary web platform: `fetch()` works against local
and remote endpoints (pages are loaded with file-URL CORS relaxed), and
in-page state is yours to manage. There is deliberately no shell or
filesystem access from the page — if you need real tools, declare an MCP
server and let the model call it, or `cantrip.sendPrompt(...)` and let
the agent do the work with its own permission gates.

Plugins that need local or authenticated data can declare `dataSources`.
`cantrip.requestData("status")` runs the matching command with the plugin
folder as its working directory and resolves with the JSON object written
to stdout. An optional JSON object passed as the second argument is written
to the command's standard input (capped at 64 KB), which lets one approved
command safely handle searches and mutations without exposing credentials
to panel JavaScript. Relative commands must stay inside the plugin folder,
commands must be executable, timeouts are capped at 60 seconds, and output
is capped at 1 MB. Keep credentials in the command's server-side environment
or a protected local file, never in panel JavaScript. Each command line is
shown on the approval card.

Native panel APIs are promise-based and denied unless the manifest declares
the matching capability. Built-in capabilities are `cantripStatus`,
`cantripActions`, and `dailyBriefing`; they expose only Cantrip's fixed status,
maintenance commands, and read-only local briefing sources. Daily Briefing
uses Contacts to return only recent messages from known contacts. Its
`.calendar`, `.mail`, and `.messages` requests resolve independently and use a
short cache; append `.refresh` to bypass it. Capabilities are listed on the
approval card, and changing them invalidates approval.

## Install, approval, and lifecycle

- Drop the folder in `~/.config/cantrip/plugins/` (the Extensions popover
  has an **Open Plugins Folder** button), then hit **Rescan & Reload**.
- Cantrip watches installed plugin files and reloads changed panels
  automatically. **Rescan & Reload** is the manual fallback and also discovers
  newly added or removed plugin folders; neither path requires restarting
  Cantrip.
- Only changes to Cantrip's native Swift plugin host or bridge require a
  rebuild and relaunch.
- Flipping a plugin on the first time shows an approval card listing
  exactly what the manifest declares — the panel file and every MCP
  server command line. Nothing runs before you approve.
- Approval is bound to the manifest's SHA-256. Any edit to manifest.json
  (new server, changed command) flips the plugin back to
  "needs approval" and it goes inert until you re-review it.
- MCP changes apply to the *next* model process: the merged config at
  `~/.config/cantrip/plugin-mcp.json` is regenerated on every toggle,
  and backends read it when they spawn. Local-model MCP connections are
  invalidated and reconnected on the next request.
- Server names are sanitized to `[A-Za-z0-9_-]`; if two plugins declare
  the same server name, the later one (alphabetical by plugin name) is
  auto-prefixed with its plugin id.

## Security model

Plugins are code you chose to install, running with meaningful reach:
panel pages have unrestricted network access (CORS is relaxed so
dashboards can talk to local devices that don't send CORS headers, which
also means a page may be able to read local files and send them over the
network), and panel data commands and MCP servers are real processes running
as your user. Treat
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
session. For development, symlink it into the plugin directory so edits in
the checkout are live, then enable it in the Extensions popover:

```bash
mkdir -p ~/.config/cantrip/plugins
ln -s "$PWD/Examples/plugins/hello-dashboard" \
  ~/.config/cantrip/plugins/hello-dashboard
```
