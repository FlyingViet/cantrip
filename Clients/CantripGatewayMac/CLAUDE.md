# CLAUDE.md — Cantrip Gateway Mac

Native macOS Cantrip Home. See README.md for architecture and usage.

## Build / test
- `make project` (submodule + `xcodegen generate`; the `.xcodeproj` is git-ignored),
  `make test`, `make build`, `make install` (Release → /Applications).
- QA against a real host server without the real pairing token: launch the Debug app
  with `-CantripUITestRemoteURL http://127.0.0.1:<port> -CantripUITestRemoteToken <token>
  -CantripUITestLane home` (same fixture hook as the iOS UI tests).
- Keep Debug builds signed (`make build`/`make test`). An unsigned build's saved
  fixture credential makes the signed test host hit a modal keychain prompt and
  the test runner hangs; `defaults delete com.itzhoang.cantripgateway.mac.debug`
  clears the Debug app's saved servers.

## Rules
- Home logic lives in the `Hermes` submodule (the iOS app). Never fork it here:
  fix shared behavior in Hermes, push it there, then bump the submodule.
- This repo holds only Mac UI and platform stand-ins (`Sources/Platform`). Prefer
  an AppKit stand-in here over editing shared code; when shared code must change,
  use `#if os(iOS)` guards that leave iOS behavior identical.
- The app's module name is `Hermes` so shared tests compile unchanged; add only
  suites that don't render UIKit views to the test target in `project.yml`.
- No Remote tabs: pass `nil` for tab-opening callbacks (`onOpenTab`, `openTab`,
  `openSession`, `openLog`).
- Keep SwiftUI `body` lean and match Cantrip's dark look (WCAG AA contrast).
- Memory: never animate `Text` size per frame (sleeping Pip's "z" grew the app ~17 MB/min
  from cached glyph bitmaps). Check long sessions with `footprint <pid>` over time; idle
  should stay flat (~105-120 MB, ~160 MB with Home history, ~210 MB image-heavy).
