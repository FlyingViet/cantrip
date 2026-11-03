#!/bin/bash
# Assembles an unsigned Cantrip.app at the given path from `make build` and `make home-window`
# output: the binary, Info.plist stamped with the build identity and date, the icon, the helper
# scripts (CantripInstall.bundledScripts) and the Home window plug-in when it was built.
# `make app` signs it with the development identity; Scripts/release-mac.sh with Developer ID.
#
#   BUILD_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path) \
#       Scripts/assemble-app.sh path/to/Cantrip.app
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:?usage: Scripts/assemble-app.sh <path to Cantrip.app>}"
BIN_DIR="${BUILD_DIR:?set BUILD_DIR to swift build --show-bin-path}"
APP_NAME="${APP_NAME:-Cantrip}"
SCRIPTS=(cantrip cantrip-mcp mcp-on-demand messages-send mail-refresh)

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources/bin"
cp "$BIN_DIR/$APP_NAME" "$DEST/Contents/MacOS/"
cp Resources/Info.plist "$DEST/Contents/"

BUILD_ID=$(git describe --always --dirty --match 'v[0-9]*' 2>/dev/null || echo unknown)
case "$BUILD_ID" in *-dirty)
    BUILD_ID="$BUILD_ID-$(git diff HEAD 2>/dev/null | cksum | cut -d' ' -f1)";;
esac
plutil -replace CantripBuildIdentity -string "$BUILD_ID" "$DEST/Contents/Info.plist"
plutil -replace CantripBuildDate -string "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$DEST/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$DEST/Contents/Resources/"; fi
for script in "${SCRIPTS[@]}"; do cp -p "Scripts/$script" "$DEST/Contents/Resources/bin/"; done
if [ -d .build/home-window/CantripHomeWindow.bundle ]; then
    mkdir -p "$DEST/Contents/PlugIns"
    ditto .build/home-window/CantripHomeWindow.bundle "$DEST/Contents/PlugIns/CantripHomeWindow.bundle"
fi
bash Scripts/verify-macos-architectures.sh "$DEST"
