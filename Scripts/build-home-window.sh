#!/bin/bash
# Builds the Home window plug-in (Cantrip's Window interface) from Clients/CantripGatewayMac (which
# compiles Clients/CantripIOS) into .build/home-window. Optional: without Xcode, xcodegen or those
# folders it explains why and exits 0, and Cantrip builds with the panel only.
# CANTRIP_SKIP_HOME_WINDOW=1 skips it.
# With CANTRIP_BUILD_ROOT set (a build disk, such as a NAS), its DerivedData goes there, one folder per
# checkout; when that folder can't be written it builds locally. SwiftPM checkouts stay in .build,
# cloned copy-on-write from the main checkout's so a worktree doesn't fetch them again.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="${HOME_WINDOW_SOURCE:-Clients/CantripGatewayMac}"
OUT=".build/home-window"
skip() { echo "Home window: skipped ($1). Cantrip builds with the panel only." >&2; rm -rf "$OUT/CantripHomeWindow.bundle"; exit 0; }

[ "${CANTRIP_SKIP_HOME_WINDOW:-0}" = 1 ] && skip "CANTRIP_SKIP_HOME_WINDOW=1"
[ -f "$SRC/project.yml" ] || skip "no CantripGatewayMac source at $SRC"
[ -f "$SRC/../CantripIOS/project.yml" ] || skip "no CantripIOS source next to $SRC"
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
# The package state records absolute artifact paths. A cloned cache, or one that moved out of
# DerivedData, can point at folders that were since pruned, and the build then can't find them.
# Point each at this cache's own copy when it has one.
if [ -f "$PACKAGES/workspace-state.json" ]; then
    /usr/bin/python3 - "$PACKAGES" <<'PY' || true
import json, os, sys
spm = os.path.abspath(sys.argv[1])
path = os.path.join(spm, "workspace-state.json")
state = json.load(open(path))
changed = False
for artifact in state.get("object", {}).get("artifacts", []):
    old = artifact.get("path", "")
    if "/artifacts/" not in old:
        continue
    new = os.path.join(spm, "artifacts", old.split("/artifacts/", 1)[1])
    if new != old and os.path.exists(new):
        artifact["path"] = new
        changed = True
if changed:
    with open(path + ".tmp", "w") as out:
        json.dump(state, out, indent=2)
    os.replace(path + ".tmp", path)
PY
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
