[User Guide](README.md) / Permissions, privacy, and memory

# Control what Cantrip can do, see, and remember

**Platform: macOS.** Windows has separate
[action and screen-sharing controls](windows.md).

## Let an agent make changes

**Act on my behalf** is off by default. Enabling it allows unattended actions
such as shell commands, file edits, and sending messages. For Codex, it maps
to bypassing approvals and its sandbox. Treat this as granting powerful
access to your user account, not merely unlocking better answers.

1. Select the intended project with the **folder** button.
2. Open the **gear** and review your backend's permissions.
3. Enable **Act on my behalf** only for work you trust the agent to perform.
4. Specify limits in the request and review the resulting changes.
5. Turn the option off when you no longer need unattended actions.

Turning off that one switch is not a universal lock:
Claude's **Permissions** may independently allow edits/everything, and
Copilot's **Allow all tools** also grants unattended tool use. For
least-privileged chat, use Claude **Safe**, leave Copilot **Allow all tools**
off, and leave **Act on my behalf** off.

Explicit `!` commands, terminal commands, skills, and approved plugin processes
are separate execution paths. The working directory is not a filesystem
sandbox, and a prompt such as "do not edit files" is not an OS access control.

## Choose automatic context

Open Settings and review these switches before asking about sensitive work:

| Setting | Fresh-install default | What it does |
|---|---|---|
| Memory vault | On | Adds core notes and relevant saved context |
| Search my documents' contents as context | On | Adds matching excerpts from Spotlight-indexed documents |
| Share my calendar as context | On | Adds available calendar context for the next 48 hours |
| Share my location as context | On | Adds available location context |
| Screen context (toolbar) | Off | Adds screenshots of your displays to supported backend requests |
| Remote control daemon | Off | Allows authenticated remote session control |
| Act on my behalf | Off | Grants unattended agent actions |

Calendar, location, and screen access also depend on macOS permission.
Turning off automatic context prevents that automatic inclusion on later
prompts; it does not erase data already sent or stop an authorized agent from
reading data through a tool.

## Grant only the macOS permissions you need

Open **System Settings > Privacy & Security**. Names vary slightly by macOS
version; enable Cantrip only for a feature you intend to use.

| Permission | Needed for | If it is unavailable |
|---|---|---|
| Microphone and Speech Recognition | Voice input | Use typed questions |
| Accessibility | Selected-text capture and some UI interactions | Copy/paste text manually |
| Screen Recording / Screen & System Audio Recording | Screen context and screenshot-based guidance | Attach a cropped screenshot yourself |
| Automation, including Calendar | Reading calendar context or controlling another app | Decline and use that app manually |
| Location Services | Location-aware context | Enter a location in the prompt |
| Full Disk Access | Some protected files, such as Messages history | Leave off unless that task needs it |
| Local Network, when requested | Discovering/connecting to a LAN Cantrip host | Check the remote setup and network permissions |

Trigger the feature first if Cantrip has not appeared in a permission list.
Quit and reopen Cantrip when macOS says a change requires it. General text
chat does not require every permission in the table.

## Use private mode

1. Open a **new local session** with **Command+T**.
2. Click the **eye-slash** button before entering sensitive content.
3. Confirm the button/panel turns purple and the tooltip says private mode
   is on.
4. Keep the session private for the rest of that conversation.

Private mode suppresses Cantrip's session transcript/run-journal persistence
and memory-session logging, and instructs the agent to treat memory as
read-only. Private sessions are not exposed to Remote clients.

**Private mode is not an anonymity, no-network, or zero-disk guarantee.**
It does not turn off all automatic context, prevent provider/CLI logs, erase
previous disclosures, or stop file writes by tools. Image/screenshot caches,
existing memory, diagnostic logs, and settings are separate from conversation
history. Memory write restrictions given to an agent are instructions, not a
filesystem sandbox.

If you do not want saved memory included, also turn off **Memory vault**.
Review the other context toggles too. Only a model server you control avoids
sending the model request to a cloud provider; plugins and tools can still use
the network.

## Read or edit your memory

1. Open Settings and find **Memory vault folder** while **Memory vault** is on.
2. Open that folder in Finder or Obsidian. The default is
   `~/Cantrip Memory`.
3. Edit the relevant Markdown file and save it.

| File or folder | Purpose |
|---|---|
| `MEMORY.md` | Environment and conventions; target cap 2,200 characters |
| `USER.md` | Preferences and facts about you; target cap 1,375 characters |
| Other `.md` notes | Procedures and reference material |
| `sessions/` | Saved daily conversation logs |

Keep the two core files concise; consolidate old entries rather than
continually appending. Detailed instructions belong in separate notes.
The caps are consolidation targets, not a reason to assume excess text is
never transmitted.

To stop using the vault, turn **Memory vault** off. This does not delete it.
Back up notes before manually removing or rewriting them.

## Know where data lives

| Location | Contents |
|---|---|
| Configured memory folder | Core notes, procedures, and memory session logs |
| `~/.cache/Cantrip/` | Session/cache artifacts, including local image captures |
| `~/.cache/Cantrip/runs/` | Durable journals for non-private runs |
| `~/.cache/Cantrip/remote-attachments/` | Retained images uploaded by Remote clients |
| `~/Library/Logs/Cantrip.log` | Diagnostic log |
| macOS Keychain | Remote host/client pairing credentials |

Closing a tab or disabling Remote does not delete all of this data. Removing
images can break queued/resumed tasks and historical image references. Review
specific files before deleting them; do not broadly clear the cache while
work is active.
