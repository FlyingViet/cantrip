[User Guide](README.md) / Extensions and skills

# Add dashboards, tools, and your own commands

**Platform: macOS**, except where linked to the Windows instructions.

| Feature | Use it for |
|---|---|
| Extension/plugin | A dashboard, an approved data command, or tools packaged in a folder |
| MCP server | A process that exposes tools an AI backend can call |
| Skill | An executable script you run by typing `/name` |
| Backend command | A slash command, custom command or skill your agent CLI already has |

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

## Use your agent's own slash commands and skills

Type `/` in any tab or Cantrip Home composer, on the Mac, in Cantrip Agent, the
browser Remote, Gateway Mac or the Windows app. Cantrip lists the commands
that the tab's backend reports in the tab's folder, with a short description:

| Backend | What Cantrip lists | How it asks |
|---|---|---|
| Copilot | Built-in commands that run outside the terminal, your personal and project skills (`.github/skills`, `.claude/skills`, `.agents/skills`, `.claude/commands`), and skills Copilot only uses automatically (shown dimmed) | A short-lived Copilot session in the folder: `commands.list` and `skills.list`, MCP servers off, deleted afterwards |
| Claude Code | Built-in commands that work in SDK mode, personal and project skills and commands, bundled skills | The stream-json `initialize` handshake the Agent SDK uses; no prompt is sent |
| Codex | Your user, repository and system skills. Codex's own built-ins only exist in its terminal app | `codex app-server` `skills/list` |
| Copilot Remote | What the ACP server announces (`available_commands_update`) | After the tab connects |

Your `~/.config/cantrip/commands` scripts are listed too, labeled **Cantrip**.

1. Type `/` and then a few letters. The list narrows as you type: names first,
   then aliases, then words in the description.
2. On a keyboard, use **Up** and **Down**, **Tab** to insert, **Return** to
   choose, **Escape** to hide the list. On iPhone, tap a row.
3. A command that needs no input runs at once. One that takes input (for
   example `/plan` or a skill) is inserted so you can type the rest.

**Expected result:** the backend acts on it. Copilot output such as `/usage`
or `/env` appears as the reply; `/plan`, `/review`, `/research` and skills
start a normal agent turn. Codex skills are inserted as `$name`, the way Codex
invokes a skill.

Cantrip discovers the list on the Mac when you first type `/` in a folder and
keeps it until a skill or command folder, the CLI or the tab's folder
changes. Nothing about your skills is stored in Cantrip.

Some commands are dimmed with the reason instead of running:

- Copilot `/allow-all`, `/permissions` and `/sandbox`: Cantrip's approval
  settings decide what the agent may do, and Cantrip Home's policy depends on
  that.
- Copilot `/remote`, `/every`, `/after` and `/cwd`: Cantrip already provides
  remote access, stops idle runtimes (scheduled prompts would stop with it)
  and sets each tab's folder. Ask Cantrip Home to schedule a task instead.
- Claude `/color`, and `/fast` when Claude reports it is off for SDK sessions.

Two map to Cantrip's own controls: Copilot `/model` opens the tab's model
settings (or send `/model <model> [effort]`), and Claude `/clear` is
**Start Fresh**. Commands that only exist in a terminal, such as `/help` or
`/exit`, are not listed. Text such as `/Users/me/notes.txt` is never treated as
a command, and pressing **Escape** sends whatever you typed unchanged.

If Claude Code is signed out, only its local commands such as `/context` run
until you sign in with `claude auth login`. If Codex isn't installed, the list
says so.

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
