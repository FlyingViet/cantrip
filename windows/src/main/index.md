# Main Process Index

| File | Purpose |
|------|---------|
| `main.ts` | App lifecycle, launcher window, tray, shortcut, and IPC |
| `appCatalog.ts` | Windows Start Menu discovery and safe app launching |
| `backends.ts` | AI CLI detection, process streaming, shell runs, and cancellation |
| `backendHealth.ts` | Backend install/sign-in/quota checks, cache, alerts, routing skip, and sign-in flows |
| `updateManager.ts` | GitHub Releases update checks, downloads, and restart-to-install |
| `plugins.ts` | Plugin discovery, approvals, sandbox panels, data sources, MCP merge, and reload |
| `homeWindow.ts` | The read-only Cantrip Home window and its sender-checked IPC |
| `home/pairing.ts` | `cantrip pair` link parsing and validation (from Cantrip Gateway for Windows) |
| `home/transport.ts` | GETs to the Mac over TLS-PSK (LAN) or HTTPS (Tailscale) |
| `home/router.ts` | Route order and fallback between the Mac's addresses |
| `home/store.ts` | The pairing, its token encrypted with safeStorage (DPAPI) |
| `home/service.ts` | Pairing check and the allow-listed Home reads |
