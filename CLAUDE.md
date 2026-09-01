# Cantrip Monorepo

## Platforms

- macOS reference app: Swift sources in `Sources/Cantrip/`
- Windows app: Electron + TypeScript in `windows/`
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

## Conventions

- Keep platform-specific OS integrations in their platform directory.
- Keep the plugin manifest schema compatible across platforms.
- Never weaken renderer/plugin sandboxing or expose Node APIs to web content.
- Validate all privileged IPC in the platform host process.
- Update the relevant platform README and `windows/PARITY.md` when behavior changes.
