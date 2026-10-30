#!/bin/bash
# Builds the Home window plug-in (Cantrip's Window interface) from the CantripGatewayMac submodule
# into .build/home-window. Optional: without Xcode, xcodegen or the submodule it explains why and
# exits 0, and Cantrip builds with the panel only. CANTRIP_SKIP_HOME_WINDOW=1 skips it.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="${HOME_WINDOW_SOURCE:-External/CantripGatewayMac}"
OUT=".build/home-window"
skip() { echo "Home window: skipped ($1). Cantrip builds with the panel only." >&2; rm -rf "$OUT/CantripHomeWindow.bundle"; exit 0; }

[ "${CANTRIP_SKIP_HOME_WINDOW:-0}" = 1 ] && skip "CANTRIP_SKIP_HOME_WINDOW=1"
# Follow the pinned commit (a pull or Update & Rebuild may have moved it); offline keeps what's there.
if [ -f .gitmodules ] && grep -q "$SRC" .gitmodules; then
    git submodule update --init --recursive "$SRC" >/dev/null 2>&1 || true
fi
[ -f "$SRC/project.yml" ] || skip "no CantripGatewayMac source at $SRC"
[ -f "$SRC/Hermes/project.yml" ] || git -C "$SRC" submodule update --init >/dev/null 2>&1 || true
[ -f "$SRC/Hermes/project.yml" ] || skip "the Hermes submodule in $SRC is missing"
command -v xcodegen >/dev/null 2>&1 || skip "xcodegen isn't installed (brew install xcodegen)"
xcodebuild -version >/dev/null 2>&1 || skip "full Xcode isn't installed (the Command Line Tools can't build it)"
sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)
[ "${sdk%%.*}" -ge 26 ] 2>/dev/null || skip "the macOS 26 SDK is needed (found $sdk)"

echo "Home window: building from $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown))…"
log="$OUT/build.log"
mkdir -p "$OUT"
if ! (cd "$SRC" && xcodegen generate --quiet) >"$log" 2>&1; then
    skip "xcodegen failed, see $log"
fi
if ! xcodebuild -project "$SRC/CantripGatewayMac.xcodeproj" -scheme CantripHomeWindow -configuration Release \
        -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all build >>"$log" 2>&1; then
    skip "the Xcode build failed, see $log"
fi
rm -rf "$OUT/CantripHomeWindow.bundle"
ditto "$OUT/DerivedData/Build/Products/Release/CantripHomeWindow.bundle" "$OUT/CantripHomeWindow.bundle"
echo "Home window: built $OUT/CantripHomeWindow.bundle"
