#!/bin/bash
# Builds the Home window plug-in (Cantrip's Window interface) from the CantripGatewayMac submodule
# into .build/home-window. Optional: without Xcode, xcodegen or the submodule it explains why and
# exits 0, and Cantrip builds with the panel only. CANTRIP_SKIP_HOME_WINDOW=1 skips it.
# With CANTRIP_BUILD_ROOT set (a build disk, such as a NAS), its DerivedData goes there, one folder per
# checkout; when that folder can't be written it builds locally. SwiftPM checkouts stay in .build,
# cloned copy-on-write from the main checkout's so a worktree doesn't fetch them again.
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

DERIVED="$OUT/DerivedData"
if [ -n "${CANTRIP_BUILD_ROOT:-}" ]; then
    # Only below an existing root: creating it would put a local folder where the disk mounts.
    remote="$CANTRIP_BUILD_ROOT/CantripHomeWindow/$(basename "$PWD")-$(printf %s "$PWD" | shasum | cut -c1-8)"
    if [ -d "$CANTRIP_BUILD_ROOT" ] && mkdir -p "$remote" 2>/dev/null && [ -w "$remote" ]; then
        DERIVED="$remote/DerivedData"
    else
        echo "Home window: $CANTRIP_BUILD_ROOT isn't available, building in $DERIVED instead." >&2
    fi
fi
PACKAGES="$OUT/spm"
if [ ! -e "$PACKAGES" ]; then
    # The main checkout's, or this checkout's from before they moved out of DerivedData.
    main="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    for seed in "${main%/.git}/$PACKAGES" "$OUT/DerivedData/SourcePackages"; do
        [ -d "$seed/checkouts" ] || continue
        rm -rf "$PACKAGES.tmp"
        cp -c -R "$seed" "$PACKAGES.tmp" 2>/dev/null && mv "$PACKAGES.tmp" "$PACKAGES" && break
    done
    rm -rf "$PACKAGES.tmp"
fi
if ! (cd "$SRC" && xcodegen generate --quiet) >"$log" 2>&1; then
    skip "xcodegen failed, see $log"
fi
if ! xcodebuild -project "$SRC/CantripGatewayMac.xcodeproj" -scheme CantripHomeWindow -configuration Release \
        -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES" CODE_SIGNING_ALLOWED=NO \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all build >>"$log" 2>&1; then
    skip "the Xcode build failed, see $log"
fi
rm -rf "$OUT/CantripHomeWindow.bundle"
ditto "$DERIVED/Build/Products/Release/CantripHomeWindow.bundle" "$OUT/CantripHomeWindow.bundle"
echo "Home window: built $OUT/CantripHomeWindow.bundle"
