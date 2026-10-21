[User Guide](README.md) / Extensions and skills

# Add dashboards, tools, and your own commands

**Platform: macOS**, except where linked to the Windows instructions.

| Feature | Use it for |
|---|---|
| Extension/plugin | A dashboard, an approved data command, or tools packaged in a folder |
| MCP server | A process that exposes tools an AI backend can call |
| Skill | An executable script you run by typing `/name` |

Install only code you trust. A plugin's approval card is not a guarantee that
its code is safe.

## Install an existing plugin

1. Open Cantrip's **Extensions** menu, the puzzle-piece icon.
2. Click **Open Plugins Folder**. On Mac this is
   `~/.config/cantrip/plugins/`.
3. Copy the plugin's complete folder into it. The folder must directly contain
   `manifest.json`, not another wrapper folder.
4. Return to Extensions and click **Rescan**.
5. Enable the plugin. Read the approval card, including commands and requested
   capabilities.
6. If you trust those declarations and the plugin code, click
   **Approve & Enable**.
7. Open its dashboard from Extensions if it provides one.

**Expected result:** its dashboard opens in a side pane, or its tools become
available to a supported backend on the next model process. If tools do not
appear in an existing conversation, start a fresh session.

The repository includes a working example. With the standard Mac checkout,
and only if you have not already installed a folder with this name:

```sh
mkdir -p ~/.config/cantrip/plugins
cp -R ~/Coding/Cantrip/Examples/plugins/hello-dashboard \
  ~/.config/cantrip/plugins/hello-dashboard
```

Then follow steps 4-7. Inspect the example before approving it.

## Update, disable, or remove a plugin

Installed files live-reload; **Rescan** is the manual fallback. A change to
`manifest.json` invalidates approval, so review it again before enabling.
Native Cantrip host changes, unlike plugin-file changes, require rebuilding
and relaunching the app.

To stop a plugin, disable it in Extensions. To uninstall it, disable it and
remove only its own folder from the plugins directory. An already-running
backend process may need a new session before its tool list reflects the
change.

Dashboard pages have network access. Data commands and MCP servers execute as
your user. Do not put secrets in dashboard JavaScript or public plugin files.

## Add your own slash command

1. Open `~/.config/cantrip/commands/` in your editor.
2. Create `project-status.sh` containing:

```sh
#!/bin/sh
# description: Show the current project folder and Git status
set -eu
printf '## Project status\n\n'
printf 'Folder: %s\n\n' "$CANTRIP_WORKDIR"
git -C "$CANTRIP_WORKDIR" status --short
```

3. In Terminal, make it executable:

```sh
chmod +x ~/.config/cantrip/commands/project-status.sh
```

4. Choose a Git project with Cantrip's **folder** button.
5. Type `/project-status` and press **Return**. If it does not appear at once,
   wait a few seconds and type `/` again.

**Expected result:** the script prints the project folder and Git status in
the panel. Scripts receive arguments as `$@` and the session folder as
`$CANTRIP_WORKDIR`. Their output is displayed as Markdown.

These are executable scripts, not prompts. Review a skill before running it;
the AI action switch does not prevent an explicitly invoked skill from acting.

## Add MCP tools

For most users, prefer a trusted plugin that declares its MCP server.
Cantrip injects plugin MCP configuration into Claude Code and Codex and can
connect local models through its own MCP client. Copilot's tools must be
registered in the Copilot CLI's own configuration instead.

For a Copilot MCP server that uses OAuth, sign in once from Terminal with
`copilot`, then `/mcp auth <server>`. Cantrip's Copilot sessions reuse the
token that the CLI saved in the macOS Keychain. Tools appear in the next
Copilot session Cantrip starts.

### Start a large MCP server only when it's used

Each Copilot tab starts its own copy of every stdio MCP server, so a server
that needs a few hundred MB costs that much per open tab and per Cantrip Home
job, even when nothing calls it. `Scripts/mcp-on-demand` stands in for such a
server. It answers the connection handshake and the tool list from a cache
saved the last time the server ran (about 9 MB of memory), and starts the real
server the first time a tool is called. That call waits about a second longer;
later calls go straight through.

Put it in front of the server's command in `~/.copilot/mcp-config.json`:

```json
"rea": {
  "type": "stdio",
  "command": "/opt/homebrew/bin/python3",
  "args": ["/Users/you/Coding/Cantrip/Scripts/mcp-on-demand", "--",
           "/opt/homebrew/opt/node@22/bin/node", "/path/to/rea.mjs", "mcp"],
  "tools": ["*"]
}
```

The first session after a change records the cache by starting the server at
once. The cache, in `~/.cache/Cantrip/mcp-on-demand/`, is keyed by the
server's command, files and package version, so an update records a new one.
When a started server's tool list differs from the cache, the cache is updated
and the session is told its tools changed. The server stops when its tab's
Copilot runtime does. Add `--log <file>` before `--` to see which requests
were answered from the cache. Avoid it for servers whose tools change while
they run or that must do work at startup; they need to start with the session.

For manifests, tool configuration, and dashboard APIs, use the
[plugin developer reference](../PLUGINS.md). Windows uses the same manifest
format but a different host; follow [Windows plugins](../windows/PLUGINS.md).
