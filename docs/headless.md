[User Guide](README.md) / Headless host

# Run Cantrip without windows (headless)

**Platform: macOS today; Linux is in progress.** A headless host runs Cantrip's
sessions, Remote control, Cantrip Home and the `cantrip` CLI with no panel, menu
bar icon or hotkey. Use it on a cloud Mac, a Mac you reach over remote desktop or
SSH, or any Mac nobody sits at, then drive it from Cantrip Agent, Cantrip Gateway
Mac or the browser Remote.

The menu bar app and the headless host use the same sessions, settings and pairing
token, but only one can run at a time.

## Set up

1. Build Cantrip and put the CLI on your PATH: from the cloned repo run
   `./install.sh`, then `make app`.
2. Install and sign in to the agent CLI the host will use, for example
   `npm install -g @github/copilot`, then run `copilot` once and sign in.
3. Pick the backend: `cantrip config set backend copilot` (or `claude`,
   `codex`, `agy`, `local`).
4. Start the host: `cantrip daemon start`. It runs now and at every login, and
   launchd restarts it after a crash. In tmux, screen or a container, use
   `cantrip daemon run` instead. Agent CLIs and shells the host starts keep
   that terminal's PATH order; Cantrip adds `~/.local/bin`, `/opt/homebrew/bin`
   and `/usr/local/bin` only when they're missing, ahead of the system folders.
5. Check everything with `cantrip doctor`.

## Pair a device

Run `cantrip pair`. It prints a QR code, a `cantripagent://pair` link and the
values to type in by hand. Scan the code with the iPhone camera (or open the link
on the device) and Cantrip Agent opens its pairing form filled in; confirm to save.
The QR code and link contain the token, so show them only on your own screen and
don't paste or screenshot them anywhere else.

How the device reaches the host:

| Route | When | What to do |
|---|---|---|
| Local network | Same Wi-Fi or LAN | Nothing: the app finds the host by its token. |
| Tailscale | Anywhere on your tailnet | `tailscale serve --bg 8765` on the host; `cantrip pair` then includes its `https://…ts.net` address. |
| HTTPS forward | Codespaces-style port forwarding or your own proxy | Forward port 8765 over HTTPS and run `cantrip pair --url https://…`. |
| Direct address | Another network that can reach the host's IP | `cantrip pair --direct` (or `--direct HOST:PORT`). |

The HTTP API only listens on 127.0.0.1, so it's reachable through Tailscale Serve
or a forward, never directly. The direct and local-network routes use the
encrypted TLS-PSK listener.

`cantrip pair --rotate` replaces the token; devices paired before must pair again.

## Commands

| Command | Does |
|---|---|
| `cantrip daemon start` / `stop` / `restart` | Install and run the launchd service / stop it and remove it from login / restart it (installs a staged update) |
| `cantrip daemon run` | Run in the current terminal until Ctrl-C |
| `cantrip daemon logs [-f]` | Show the host log |
| `cantrip status [--json]` | Mode, build, tabs and Remote state |
| `cantrip pair [--url URL] [--direct [HOST:PORT]] [--name NAME] [--rotate] [--no-qr] [--json]` | Pairing QR code, link and details |
| `cantrip config` / `get KEY` / `set KEY VALUE …` | Read and change settings |
| `cantrip doctor` | Check the host, Remote, the backend CLI and Tailscale |
| `cantrip cleanup [--dry-run] [--list] [--json]` | Remove unused agent sessions and worktrees now ([details](updating-and-troubleshooting.md#free-up-disk-space)) |
| `cantrip tab list` / `read ID` / `ask ID "question"` / `reply ASK_ID` | Look into other tabs ([details](sessions-and-council.md#look-into-other-tabs)) |

Settings use the same names as `~/.cantriprc`. Common ones: `backend`,
`copilotModel`, `copilotEffort`, `allowActions`, `remoteControlPort`,
`remoteLANPort` (0 = any free port), `cantripHomeEnabled`, `memoryEnabled`,
`memoryPath`, `storageUpkeepEnabled`, `storageSessionRetentionDays` (3–365,
default 14). Run `cantrip config` for the full list.

## Good to know

- **Pairing token:** kept in the Keychain. When a headless host can't use the
  Keychain (an SSH-only Mac, where the login Keychain stays locked), it uses
  `~/Library/Application Support/Cantrip/remote-token` instead, readable only by
  you. Once that file exists, the app uses it too.
- **Local control:** the CLI talks to the host over `~/.cache/Cantrip/cantrip.sock`,
  which only your user can open.
- **Not available headless:** View Mac and screen context need someone logged in
  at the screen with Screen Recording allowed; voice and Mac notifications are
  off. macOS permission prompts can't be answered remotely, so grant them at the
  Mac first if a task needs them.
- **Updates:** `make app` stages a new build; `cantrip daemon restart` installs it.
- **Switching back to the app:** `cantrip daemon stop`, then open Cantrip. If the
  service is running, the app explains that and quits.
- **Troubleshooting:** `cantrip doctor`, `cantrip daemon logs`, and launchd's
  output in `~/Library/Logs/Cantrip-daemon.log`.
