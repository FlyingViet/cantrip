#!/bin/bash
# Scripts/prune-build-folders.sh removes only old, unused build folders.
set -eu
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/Scripts/prune-build-folders.sh"
ROOT=$(mktemp -d /tmp/prune-build-tests.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
old() { find "$@" -exec touch -t 202601010000 {} +; }

REPO="$ROOT/repo" DD="$ROOT/DerivedData" TMPD="$ROOT/tmp" ZIPS="$ROOT/zips"
mkdir -p "$REPO/.build/out/Products/Release" "$REPO/.build/arm64-apple-macosx/release" \
    "$REPO/.build/x86_64-apple-macosx/debug" "$REPO/.build/test-bins" "$DD" "$TMPD" "$ZIPS"
printf swiftbuild > "$REPO/.build/.buildSystem_release"
printf swiftbuild > "$REPO/.build/.buildSystem_debug"
echo bin > "$REPO/.build/out/Products/Release/Cantrip"
echo old > "$REPO/.build/arm64-apple-macosx/release/Cantrip"
echo old > "$REPO/.build/test-bins/cantrip-session-tab-tests"
old "$REPO/.build/test-bins"

# DerivedData: a live checkout, deleted worktrees, an old and a fresh package-only cache,
# and another app's folder that is never ours to touch.
mkdir -p "$ROOT/live/Hermes.xcodeproj"
for name in Hermes-live Hermes-gone CantripGatewayMac-gone Hermes-pkgold Hermes-pkgnew OtherApp-gone; do
    mkdir -p "$DD/$name/Logs" "$DD/$name/SourcePackages"
done
plutil -create xml1 "$DD/Hermes-live/info.plist"
plutil -insert WorkspacePath -string "$ROOT/live/Hermes.xcodeproj" "$DD/Hermes-live/info.plist"
for name in Hermes-gone CantripGatewayMac-gone OtherApp-gone; do
    plutil -create xml1 "$DD/$name/info.plist"
    plutil -insert WorkspacePath -string "$ROOT/deleted-worktree/$name.xcodeproj" "$DD/$name/info.plist"
done
old "$DD/Hermes-pkgold"

# Temp: an old build folder, a fresh one, an old one a running process names, another name.
mkdir -p "$TMPD/hermes-old-dd/Build" "$TMPD/cantrip-fresh-home" "$TMPD/hermes-busy-dd" "$TMPD/firered-build"
old "$TMPD/hermes-old-dd" "$TMPD/hermes-busy-dd" "$TMPD/firered-build"

for sha in a1 b2 c3 d4; do echo zip > "$ZIPS/CantripGatewayMac-$sha.zip"; done
echo shot > "$ZIPS/sidebar.png"
touch -t 202601010001 "$ZIPS/CantripGatewayMac-a1.zip"
touch -t 202601020000 "$ZIPS/CantripGatewayMac-b2.zip"
touch -t 202601030000 "$ZIPS/CantripGatewayMac-c3.zip"
touch -t 202601040000 "$ZIPS/CantripGatewayMac-d4.zip"

run() {
    CANTRIP_PRUNE_REPO="$REPO" CANTRIP_PRUNE_DERIVED_DATA="$DD" CANTRIP_PRUNE_TMP="$TMPD" \
        CANTRIP_PRUNE_ZIPS="$ZIPS" bash "$SCRIPT" "$@"
}

# A process using a folder keeps it, even when it looks old.
bash -c 'sleep 300; :' "$TMPD/hermes-busy-dd" &
BUSY=$!; disown $BUSY
trap 'kill $BUSY 2>/dev/null; rm -rf "$ROOT"' EXIT

out=$(run --dry-run)
[ -d "$REPO/.build/arm64-apple-macosx" ] && [ -d "$DD/Hermes-gone" ] || fail "dry run removed something"
echo "$out" | grep -q "Would free" || fail "dry run should summarize: $out"

out=$(run)
for gone in "$REPO/.build/arm64-apple-macosx" "$REPO/.build/x86_64-apple-macosx" "$REPO/.build/test-bins" \
    "$DD/Hermes-gone" "$DD/CantripGatewayMac-gone" "$DD/Hermes-pkgold" "$TMPD/hermes-old-dd" \
    "$ZIPS/CantripGatewayMac-a1.zip" "$ZIPS/CantripGatewayMac-b2.zip"; do
    [ ! -e "$gone" ] || fail "should remove $gone"
done
for kept in "$REPO/.build/out/Products/Release/Cantrip" "$REPO/.build/.buildSystem_release" \
    "$DD/Hermes-live" "$DD/Hermes-pkgnew" "$DD/OtherApp-gone" "$TMPD/cantrip-fresh-home" \
    "$TMPD/hermes-busy-dd" "$TMPD/firered-build" "$ZIPS/CantripGatewayMac-c3.zip" \
    "$ZIPS/CantripGatewayMac-d4.zip" "$ZIPS/sidebar.png"; do
    [ -e "$kept" ] || fail "should keep $kept"
done
echo "$out" | grep -q "kept $TMPD/hermes-busy-dd (in use)" || fail "busy folder should be reported: $out"
echo "$out" | grep -q "^Freed .* GB from 9 old build folders\.$" || fail "summary: $out"

# A configuration still on the older layout keeps its folders; opting out does nothing.
mkdir -p "$REPO/.build/arm64-apple-macosx/release"
printf native > "$REPO/.build/.buildSystem_debug"
run > /dev/null
[ -d "$REPO/.build/arm64-apple-macosx" ] || fail "keep the layout a native-build configuration uses"
mkdir -p "$DD/Hermes-gone2"
plutil -create xml1 "$DD/Hermes-gone2/info.plist"
plutil -insert WorkspacePath -string "$ROOT/nowhere.xcodeproj" "$DD/Hermes-gone2/info.plist"
CANTRIP_KEEP_BUILDS=1 run > /dev/null
[ -d "$DD/Hermes-gone2" ] || fail "CANTRIP_KEEP_BUILDS=1 should skip pruning"

echo "Prune build folders: old layouts, orphaned DerivedData, stale temp folders and old zips removed; live, in-use and other folders kept"
