# Workflow Index

| File | Purpose |
|------|---------|
| `release-windows.yml` | Test and package the Windows app on changes under `windows/`; publish a release for `windows-vX.Y.Z` tags (host `v*` tags don't run it) |
| `gateway-windows.yml` | Typecheck, test and package Cantrip Gateway for Windows on changes under `Clients/CantripGatewayMac/windows/` |
| `ios-testflight.yml` | Manual: archive Cantrip Agent (`Clients/CantripIOS`) on the self-hosted Mac and upload it to TestFlight |
