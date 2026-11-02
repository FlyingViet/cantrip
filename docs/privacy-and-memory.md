[User Guide](README.md) / Permissions, privacy, and memory

# Control what Cantrip can do, see, and remember

**Platform: macOS.** Windows has separate
[action and screen-sharing controls](windows.md).

## Let an agent make changes

**Act on my behalf** is off by default. Enabling it allows unattended actions
such as shell commands, file edits, and sending messages, except what the
[agent policy](#set-what-agents-may-do) blocks or asks about. For Codex, it
removes the sandbox but still sends each action to Cantrip's policy. Treat this
as granting powerful access to your user account, not merely unlocking better
answers.

1. Select the intended project with the **folder** button.
2. Open the **gear** and review your backend's permissions.
3. Enable **Act on my behalf** only for work you trust the agent to perform.
4. Specify limits in the request and review the resulting changes.
5. Turn the option off when you no longer need unattended actions.

Cantrip Home and its scheduled tasks follow the same choice on Copilot and
Claude Code: with **Act on my behalf** on (or Claude's **Allow everything**),
background runs approve tools and commands without pausing for you. Cantrip
still refuses its blocked commands (administrator commands, erasing disks or
the home folder, piping downloads into a shell, stopping Cantrip, and writing
Home's own state) under every setting. It judges what a command actually does:
words inside heredocs, quoted text or notes being written don't count, and
relative paths are checked in the folder a `cd` moves to. Deletes Cantrip
can't resolve (a script's `rm "$f"` or `rm -rf "$OUT/dist"`) and input typed into
a running task are approved too. The one exception is a recursive delete
through a variable that could reach the home folder or a system folder if the
variable is empty or holds the home folder (`rm -rf "$DIR"`, `"$DIR/"`,
`"$DIR/Documents"`, `~user`, `..`): that still waits for you. Local models keep
Home's approval pauses.

Turning off that one switch is not a universal lock:
Claude's **Permissions** may independently allow edits/everything, and
Copilot's **Allow all tools** also grants unattended tool use. For
least-privileged chat, use Claude **Safe**, leave Copilot **Allow all tools**
off, and leave **Act on my behalf** off.

Explicit `!` commands, terminal commands, skills, and approved plugin processes
are separate execution paths. The working directory is not a filesystem
sandbox, and a prompt such as "do not edit files" is not an OS access control.

## Set what agents may do

Cantrip keeps one agent policy for every tab, child tab and Cantrip Home run,
on every backend (Claude Code, Copilot, Codex, Antigravity, Copilot Remote and
local models). Each rule **allows**, **asks** about or **denies** a tool call.
Deny beats ask and ask beats allow, so switching backends or falling back to a
backup never changes what an agent may do. Anything no rule covers runs when
**Act on my behalf** is on and asks when it's off.

Cantrip checks each call on the Mac before the backend runs it, also with **Act
on my behalf** on. A denied call shows as a failed step named "Blocked by
Cantrip policy" with the rule's reason, and the agent is told not to try
another way. An ask rule shows the usual approval card on every paired client;
approving lets the same action repeat for the rest of that reply.

Open **Settings › Agent policy** on the Mac, or **Agent Policy** in a tab's
menu in the browser/Mac Remote, to turn rules on or off, change their effect,
remove them or add one. The rules live in
`~/Library/Application Support/Cantrip/policy.json` (Settings › **Open File**).
A rule matches any of these, limited by optional `hours` (`"21:45-22:50"`),
`repos` (a folder or origin repository name) and `unlessGitAuthor`:

- `commands`: words a command starts with (`"git push"`), with globs, `re:` for
  a regular expression, or `@cantrip-restart`. Cantrip reads commands inside
  `bash -c`, `eval`, heredocs fed to a shell, and after `cd`, `sudo`, `timeout`
  and `xcrun`.
- `paths` with `access` (`write`, `delete`, `read` or `any`); `$WORKTREE` (the
  tab's folder), `$PROJECT` (its git repository), `$TMP` and `~` expand.
- `deletesOutside`: deletes whose targets fall outside these folders.
- `mcp` (`server/tool` globs), optionally only tools whose names contain one of
  `verbs` (`send`, `delete`); `tools` (such as `WebFetch`); `kinds` (`shell`,
  `write`, `read`, `url`, `mcp`).
- `privacyScan` on a `git push` rule adds a scan of the outgoing commits (email
  addresses, private network addresses, tailnet names and your `privateTerms`)
  to the approval card.

`projects` holds per-folder overrides (extra rules, and Mac-wide rules turned
off there) in the same file, so nothing is written into your repositories. A
new Mac starts with: deny administrator commands, deny deletes outside the
tab's folder, project and temporary folders, deny creating, cloning, erasing
or deleting simulators (lease one with `cantrip sim acquire`), and ask before
publishing releases, changing production data, and sending messages, email or
posts.

The first time it runs, Cantrip imports each CLI's own rules (Claude Code's
`permissions`, Copilot's remembered approvals, Codex's rules files), after
copying each file to `~/Library/Application Support/Cantrip/policy-backups`,
so nothing that ran without a prompt starts asking. Settings lists imported
allow rules that a stricter rule overrides; the stricter rule wins until you
narrow or turn it off. Cantrip also writes the policy's deny rules back into
each CLI for Terminal use: Claude Code's `permissions.deny` and
`~/.codex/rules/cantrip.rules` get the rules they can express, and Copilot
(`~/.copilot/hooks/cantrip-policy.json`) and Antigravity (its existing hook)
ask Cantrip's app for deny rules, allowing the call if Cantrip can't answer.
Turn **Check every tab against the policy** off to go back to each backend's
own rules; Cantrip Home and child tabs keep Home's rules either way.

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

Paired devices have their own **Share location** setting, off by default: while
it's on, each message from that device carries its approximate location (about
1 km unless Precise) for that one prompt, and while it's off the model is told to
use the Mac's location and say so. A device's location is never saved to memory,
the conversation, the run journal or Cantrip's log. See
[Use the device's location](remote-control.md#use-the-devices-location).

Weather cards come from Open-Meteo, which receives only the forecast's
coordinates rounded to about 1 km, with no cookies or account. A card saved with
its reply keeps the place name it shows (such as "Seattle, WA") and whose
location it was, never coordinates. See
[Weather cards](remote-control.md#weather-cards).

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
| Contacts | Daily Briefing senders, and contact names in Cantrip Agent's [dictation vocabulary](remote-control.md#dictation-vocabulary-for-cantrip-agent) (which also reads Messages and call history only if Full Disk Access is already on) | Phone numbers and email addresses appear without names |
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

## Keep memory in one place

Cantrip Memory is the only durable memory. The CLIs' own memories stay off in every
tab, child tab, Home task and helper call Cantrip starts, so a fact never lands in a
store that skips these rules or that only one backend reads:

| Backend | Its own memory | How Cantrip keeps it off |
|---|---|---|
| Claude Code | Auto-memory under `~/.claude/projects/*/memory` | `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` for every process Cantrip starts |
| Copilot | Copilot Memory, kept by GitHub | Each session starts with `memory: { enabled: false }`; `copilot -p` helper calls have it off by default |
| Codex | Generated memories in `~/.codex` | `features.memories`, `memories.generate_memories` and `memories.use_memories` set to false at launch |
| Antigravity | No setting or command turns memory on or off | None needed: no conversation has used a memory step, and facts don't carry between conversations |

For the same behaviour when you run a CLI in Terminal, set `autoMemoryEnabled` and
`autoDreamEnabled` to `false` in `~/.claude/settings.json`, add `[features] memories = false`
and `[memories] generate_memories = false` and `use_memories = false` to
`~/.codex/config.toml`, and turn off Copilot Memory in your GitHub Copilot settings.

## Background memory upkeep

While **Memory vault** is on, Cantrip tidies the vault about once a day in the
background. A headless agent reads the last three days of `sessions/` logs,
updates `MEMORY.md` and `USER.md` within their caps, merges overlapping notes,
and deletes session logs older than 30 days.

- **Which agent:** Claude Code with its Haiku model. If the Claude Code CLI is
  missing or can't sign in, the GitHub Copilot CLI runs it instead, with the
  newest Haiku model it offers.
- **Permissions:** the same for both. With **Allow actions** on, the agent
  can use any tool. Otherwise it can only edit files: no commands, so old
  session logs stay until you allow actions.
- **When:** a check runs 15 seconds after launch and every 15 minutes after
  that. A run is due 20 hours after the last successful one. A failed run
  doesn't count. It retries after 30 minutes, and the wait doubles after each
  further failure, up to 12 hours. A run still going after 30 minutes is
  stopped and counted as a failure.
- **Failures:** Cantrip Home's **Tasks** shows a warning with the error and
  the next retry until a run succeeds. Each attempt is also logged in
  `Cantrip.log` as a `consolidator:` line.

## Hand secrets to scripts, jobs and MCP servers

Cantrip can broker the API keys, tokens and passwords your scripts use, so
they don't sit in plain files and never pass through a model.

- **Bitwarden is the source of truth.** Keep each secret as an item in one
  Bitwarden folder, **Cantrip Secrets**: a secure note whose custom fields are
  environment variables (hidden fields for secrets, text fields for addresses
  and user names), or whose note text is a file such as a key or a service
  account JSON. Binary files are stored as base64 text with a
  `cantrip-encoding` field set to `base64`. Attachments and Sends aren't used.
- **The macOS Keychain is the runtime copy.** **Settings > Secrets > Unlock &
  Sync**, `cantrip secret sync`, or **Secrets** in a paired device's tab menu
  opens a Bitwarden password dialog on the Mac. Cantrip unlocks the vault with
  it, copies the folder into the Keychain, and locks the vault again. The
  password and the session key are never stored. Scheduled jobs keep working
  while the vault is locked. The Bitwarden CLI (`bw`) must be installed and
  logged in once (`bw login`).
- **Commands get values by name:**

  ```sh
  cantrip secret list                                # names and field names only
  cantrip secret run example -- ./sync.sh            # every field of "example" as variables
  cantrip secret run TOKEN=example.API_TOKEN -- sh -c 'curl -H "Authorization: Bearer $TOKEN" https://service.example/api'
  cantrip secret run --file KEY_FILE=example-key -- ./sign.sh   # key at the path in $KEY_FILE
  cantrip secret run --env-file ENV=example -- bash -c '. "$ENV"; ./job.sh'
  ```

  `--file` hands over a pipe that can be read once; add `--temp-files` for a
  tool that reads its file twice. `--env-file` is always a private file, since
  the macOS shell can't source a pipe. Both are deleted when the command exits.
  `secret run` reads the Keychain itself, so it works while Cantrip restarts,
  and it masks every secret value in the command's output as
  `[secret:NAME.FIELD]`.
- **LaunchAgents and MCP servers** use the same wrapper: put
  `cantrip secret run NAME -- ` in front of the job's or server's command.
- **Moving existing files in:** `cantrip secret import FOLDER` previews which
  item each file becomes (names only). `--apply` creates the items through
  `bw`, syncs, and compares every file with the Keychain copy by hash;
  `cantrip secret verify FOLDER` repeats that comparison. Certificates, signing
  requests and provisioning profiles aren't secret and stay files.
- **Values stay out of logs and clients:** Cantrip masks the values in its own
  log and run journals. Settings, the browser Remote and `cantrip secret list`
  show only names, field names and the last sync. Cantrip Home can't read
  Cantrip's Keychain items with `security`.

## Know where data lives

| Location | Contents |
|---|---|
| Configured memory folder | Core notes, procedures, and memory session logs |
| `~/.cache/Cantrip/` | Session/cache artifacts, including local image captures |
| `~/.cache/Cantrip/runs/` | Durable journals for non-private runs |
| `~/.cache/Cantrip/remote-attachments/` | Retained images uploaded by Remote clients |
| `~/.cache/Cantrip/session-output-folders.json` | Which Copilot CLI session folders each tab used |
| `~/.cache/Cantrip/storage-upkeep.log` | Session folders and worktrees the daily cleanup removed ([Free up disk space](updating-and-troubleshooting.md#free-up-disk-space)) |
| `~/Library/Logs/Cantrip.log` | Diagnostic log; past 10 MB it moves to `Cantrip.log.1`, keeping three older logs (`.1` to `.3`) |
| `~/.cache/Cantrip/secrets/index.json` | Names of the brokered secrets and their fields, and the last sync (never values) |
| macOS Keychain | Remote host/client pairing credentials, MCP sign-ins, and the copy of the Bitwarden **Cantrip Secrets** folder |

To remove one exchange from all of these (and from the backend's transcripts),
use **Delete Message…** ([Sessions](sessions-and-council.md#delete-a-message)).
Closing a tab or disabling Remote does not delete all of this data. Removing
images can break queued/resumed tasks and historical image references. Review
specific files before deleting them; do not broadly clear the cache while
work is active.
