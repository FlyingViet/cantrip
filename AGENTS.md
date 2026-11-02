# Cantrip Monorepo

## Platforms

- macOS reference app: Swift sources in `Sources/Cantrip/`
- Windows app: Electron + TypeScript in `windows/`
- Cantrip Agent (iPhone/iPad/Watch; Xcode project, scheme and module `Hermes`): `Clients/CantripIOS/`
- Cantrip Gateway Mac (compiles `Clients/CantripIOS` for macOS; also builds the host's Home window
  plug-in): `Clients/CantripGatewayMac/`; Cantrip Gateway for Windows: `Clients/CantripGatewayMac/windows/`
- Each client keeps its own build system and AGENTS.md; read the client's AGENTS.md before editing it.
  A change that spans clients is one commit.
- Shared plugin example: `Examples/plugins/hello-dashboard/`

## macOS commands

- `make build`
- `make test`
- `./install.sh`

Requires macOS 14+ and Xcode Command Line Tools.

## Windows commands

Run from `windows/`:

- `npm ci`
- `npm test`
- `npm run typecheck`
- `npm run build`
- `npm run package:win`

Requires Windows 10/11 and Node.js 20.19+.

## Client commands

- Cantrip Gateway Mac, from `Clients/CantripGatewayMac/`: `make test`, `make build`, `make install`
- Cantrip Agent, from `Clients/CantripIOS/`: `xcodegen generate`, then `xcodebuild test -scheme Hermes`
  on a simulator. Shared code changes also need Gateway Mac's `make test`.
- Cantrip Gateway for Windows, from `Clients/CantripGatewayMac/windows/`: `npm ci`, `npm run typecheck`,
  `npm test`, `npm run build`

Release tags: `vX.Y` / `vX.Y.Z` host, `windows-vX.Y.Z` Cantrip for Windows, `gateway-mac-vX.Y.Z`
Gateway Mac (its release also carries the Gateway Windows installer). iOS ships through
`ios-testflight.yml`.

## Conventions

- Keep platform-specific OS integrations in their platform directory.
- Keep the plugin manifest schema compatible across platforms.
- Never weaken renderer/plugin sandboxing or expose Node APIs to web content.
- Validate all privileged IPC in the platform host process.
- Update the relevant platform README and `windows/PARITY.md` when behavior changes.
- Before adding an AI backend or changing how one integrates, read and follow
  `BACKEND-ONBOARDING.md`, and keep its known-gaps table current.
