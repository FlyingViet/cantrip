# AGENTS.md — Cantrip Agent (iOS client)

Native SwiftUI iPhone, iPad and Apple Watch client for Cantrip on the Mac: Cantrip Home, every
project tab, voice and chat. This is `Clients/CantripIOS` in the Cantrip monorepo; see
`README.md` for pairing, features and setup. The Xcode project, app scheme and target, test
targets and Swift module keep the app's original internal name, `Hermes`.

## Build / run
- `xcodegen generate`, then build or test with
  `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all`
  so SwiftPM can use its scoped bare-repository cache.
- The `.xcodeproj` is generated (git-ignored); regenerate after editing `project.yml`.
- Unit tests: `xcodebuild test -scheme Hermes` on an iOS simulator. The `HermesUITests` scheme
  runs real-touch checks against DEBUG-only fixture screens.
- The iOS app embeds the Apple Watch app; build or test it alone with the `CantripWatch` scheme
  on a watchOS simulator.
- iOS 26+, universal (`TARGETED_DEVICE_FAMILY "1,2"`). Set your own bundle id +
  signing team in `project.yml` before building to a device.
- Use the selected Xcode SDK without raising the iOS 26 deployment target.
  Duo-specific simulation/reserved-region APIs require Xcode/iOS 27.1.
- TestFlight builds come from `.github/workflows/ios-testflight.yml` at the repo root.

## How it connects
- Talks to Cantrip's authenticated REST API under `/api/v1/` on the paired Mac
  (`CantripRemoteAPI` in `Sources/CantripRemote.swift`), sending the pairing token as a
  bearer token. Nothing is hardcoded: each user pairs with their own Mac.
- Routes, in order: the saved Tailscale Serve HTTPS URL; the local network, found with Bonjour
  (`_cantrip-remote._tcp`); an optional direct `host:port`. The local-network and direct routes
  run the same HTTP inside TLS 1.2 with a pre-shared key from the pairing token
  (`CantripLANProtocol`). Plain HTTP is accepted only on loopback.
- The Mac owns every tab, queue and run, so closing iOS never stops work. The app polls
  (1.5 s while the visible tab works, 5 s otherwise) and reloads on foreground.
- Before a send or other change, an authenticated read confirms the route and the needed host
  capability; the write then goes once on that route. Writes are never replayed automatically.
- New features are gated by capability flags in session snapshots (`supports…`); an older Mac
  shows an update notice instead of failing.
- `cantrip pair` links (`cantripagent://pair?…`) are parsed by `CantripPairingLink` in
  `Sources/CantripPairing.swift`.

## Voice
- Fully on-device: FluidAudio Parakeet EOU 120M (320 ms model) is the default
  STT engine; `SFSpeechRecognizer` with `requiresOnDeviceRecognition` is the
  fallback. TTS remains Qwen or `AVSpeechSynthesizer`.
- The AVAudioEngine tap deep-copies buffers into one bounded serial consumer.
  A generation token prevents EOU/timer/cancellation races from submitting an
  utterance twice. Parakeet and Qwen release memory before switching engines.

## Mac-side prerequisite
Cantrip must be running on the Mac with Remote control on. A client feature that needs a new
endpoint or capability flag needs the matching host change in `Sources/Cantrip/`; a change that
spans the host and this app is one commit.

## Conventions
- Keep SwiftUI `body` lean (extract subviews) — the type-checker chokes on long chains.
- `ChatNavigationView` keeps one navigation stack on iPhone (including Duo);
  iPad uses adaptive split navigation, with a sidebar at regular width and a
  drawer when compact. Never switch stack types based on folding or window width.
  Keep drafts, voice, and run ownership outside size-dependent branches.
- `ChatDisplayObserver` reads window-local vertical-bar traits, the hinge (`onHingeChange`) and
  the window's own bounds (never the keyboard-shortened content).
  `ChatHeader` moves actions into the native vertical toolbar
  wherever the system has one. On an unfolded iPhone Duo (vertical bar + hinge not closed, either
  orientation: `ChatDisplayTraits.isUnfoldedDuo`) that bar is the app's rail: a sidebar toggle at
  the top, then Model Settings and Settings. The toggle shows `CantripDuoSidebar` beside the same
  stack; its open state is saved (`cantrip.duoSidebar.open`), so folding, rotation and the keyboard
  never change it. When the window can't keep the chat 400 pt wide beside it (split screen, or
  unfolded upright) the sidebar slides over the dimmed chat instead (`ChatNavigationView.overlaysSidebar`),
  with its own unsaved open state that starts closed; a tap outside, the toggle or a pick closes it.
  Folded, the Tabs button toggles the tab drawer (the vertical bar stays tappable above it). On a
  Duo, in every pose and with the sidebar open or closed, Home's sections are at
  the bottom of the right-side rail (the system's tab bar in the vertical bar, or
  `CantripDuoRailSections` in the app rail upright), never a bottom bar. Upright, the app rail keeps its
  actions low, just above the sections (or at the bottom in a tab), within thumb reach; other iPhones use
  `CantripHomeCompactTabBar`. Home puts Tabs, Settings and the menu at the top of the vertical bar when
  folded (`sharesVerticalBarWithTabBar`); unfolded, the toggle replaces Tabs. A project tab on the Duo
  (folded or not) has no "‹ Home": the left-edge swipe and the Tabs button (folded; unfolded, the
  sidebar toggle) bring out the tab picker, with Home pinned first (`usesDuoTabPicker`). Other
  iPhones keep "‹ Home" and the swipe back to Home. Do not infer Duo from dimensions or device
  names. `AGENTGATEWAY_DUO_SDK` is selected by SDK in `project.yml`, not by the
  Swift compiler version; keep both SDK and iOS availability guards.
- Paired Macs live in `ServerProfiles`; each pairing token is stored separately in Keychain
  (this device only). Settings uses blank pairing drafts, never live bindings to active
  credentials.
- Settings is one map on every client (`Sources/Settings`, compiled by Gateway Mac too): a status
  card, then `SettingsPage` (Macs, Models, Tools & sign-ins, Home & tabs, Memory, Voice,
  Location, Notifications, Appearance, About & Updates). Pages are written once; sheets that double as pages take
  `embedded: true` (`CantripSheetStack`). Stack on iPhone, side by side on an unfolded Duo and the
  Mac; the only new key is `cantrip.settings.lastPage`. Keep existing `@AppStorage` keys: settings
  saved by the previous version must keep their values (`SettingsMapTests`). Each page shows its
  scope (`SettingsScopeLabel`).
- The chat menu holds only the open tab's actions (`CantripTabActions` sections); app-wide items
  belong in Settings or the Tabs drawer (its footer has the Settings gear).
- The alert `installationID` is bound to the device by a this-device-only Keychain
  marker. A transferred/restored install gets a fresh ID (its alerts become pending
  until re-paired). Removing a server whose token is missing clears only local
  alert state; it never unregisters on the Mac.
- Code for the retired gateway integration (`HermesClient`, the `copilot`/`local` lanes,
  `ServerSettingsSections`) only appears on installs that saved a gateway before it was retired;
  don't build on it.
- Cantrip Gateway Mac (`../CantripGatewayMac`) compiles `Sources/` and
  `Shared/` for macOS, so Home logic stays identical.
  Keep UIKit, ActivityKit and AVAudioSession use behind `#if os(iOS)` (imports
  behind `#if canImport(UIKit)`); Gateway Mac supplies AppKit equivalents in its
  `Sources/Platform`.
  After changing shared code, run `make test` there before pushing.
- The Apple Watch app (`CantripWatch` target, `Watch/`, tests in `WatchTests/`) is kept out of
  `Sources/` and `Shared/` so Gateway Mac never compiles it. It records m4a (AAC mono 16 kHz) for
  the Mac to transcribe (watchOS has no Speech framework), speaks replies with
  `AVSpeechSynthesizer`, and signs every request with its own P-256 key (Secure Enclave; software
  only in the simulator) per the `cantrip-device-v1` scheme in `CantripWatchProtocol.swift`. Routes:
  the iPhone's Tailscale URL, then the Mac's optional internet URL. Setup goes through
  `Sources/CantripWatchLink.swift` (iOS only, `#if os(iOS) && canImport(WatchConnectivity)`), which
  registers the watch's public key with the selected Mac using the pairing token. DEBUG builds read
  `CANTRIP_WATCH_QA` (base64 JSON, see `WatchQA.swift`) to run in the simulator without an iPhone.
  watchOS `URLSession` ignores custom `URLProtocol`s, so client tests inject a transport.
- Never animate `Text` size per frame (Canvas/TimelineView): every new size is a fresh
  glyph rasterization that macOS keeps, so memory grows without bound. Animate shapes, or
  fill a glyph outline (`CantripMascotRenderer.GlyphOutline`) at the frame's size.
