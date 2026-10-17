#!/bin/bash
# Removes old build folders left behind by Cantrip updates. Runs after every `make app`
# (Update and Restart, and agent deploys), so space is freed whenever Cantrip is updated.
#
# Only removes things that are rebuilt on demand and that nothing is using:
#   - Cantrip's own .build: layouts from an older SwiftPM build system, old test binaries.
#   - Xcode DerivedData for Cantrip Agent (Hermes), Cantrip Gateway Mac and Cantrip whose
#     project checkout (usually a deleted worktree) is gone, or package-only caches untouched
#     for a day.
#   - /tmp/hermes-* and /tmp/cantrip-* build/test folders older than a day.
#   - Cantrip Gateway Mac zips beyond the newest two.
# Current build caches (Gateway build/, .spm package clones, live DerivedData) are kept.
# Skips anything a running process names. Never fails the build.
#
# Usage: prune-build-folders.sh [--dry-run]. Set CANTRIP_KEEP_BUILDS=1 to skip.
# Paths can be overridden for tests: CANTRIP_PRUNE_REPO, CANTRIP_PRUNE_DERIVED_DATA,
# CANTRIP_PRUNE_TMP, CANTRIP_PRUNE_ZIPS, CANTRIP_PRUNE_MIN_AGE_MINUTES.
set -u

[ "${CANTRIP_KEEP_BUILDS:-0}" = 1 ] && exit 0
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

REPO="${CANTRIP_PRUNE_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DERIVED="${CANTRIP_PRUNE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
TMPROOT="${CANTRIP_PRUNE_TMP:-/tmp}"
ZIPS="${CANTRIP_PRUNE_ZIPS:-$HOME/.cache/Cantrip/gateway-mac}"
MIN_AGE="${CANTRIP_PRUNE_MIN_AGE_MINUTES:-1440}"
KEEP_ZIPS=2

freed_kb=0
removed=0
PROCESSES=$(ps -axo command= 2>/dev/null)

# True when a running process's command line names this path (a build or test using it).
# /tmp is a symlink to /private/tmp, so either spelling counts.
in_use() {
    local path="$1" alias=""
    case "$path" in
        /tmp/*) alias="/private$path" ;;
        /private/tmp/*) alias="${path#/private}" ;;
    esac
    printf '%s\n' "$PROCESSES" | grep -F -q -- "$path" && return 0
    [ -n "$alias" ] && printf '%s\n' "$PROCESSES" | grep -F -q -- "$alias"
}

# True when nothing inside the folder changed in the last MIN_AGE minutes.
untouched() {
    [ -z "$(find "$1" -maxdepth 3 -mmin "-$MIN_AGE" -print -quit 2>/dev/null)" ]
}

remove() {
    local path="$1" why="$2" kb
    [ -e "$path" ] || return 0
    if in_use "$path"; then
        echo "  kept $path (in use)"
        return 0
    fi
    kb=$(du -sk "$path" 2>/dev/null | cut -f1)
    if [ "$DRY_RUN" = 1 ]; then
        echo "  would remove $path ($why, $((${kb:-0} / 1024)) MB)"
    elif rm -rf "$path" 2>/dev/null && [ ! -e "$path" ]; then
        echo "  removed $path ($why, $((${kb:-0} / 1024)) MB)"
    else
        echo "  could not remove $path"
        return 0
    fi
    freed_kb=$((freed_kb + ${kb:-0}))
    removed=$((removed + 1))
}

# 1. Cantrip's .build: SwiftPM's newer build system writes to .build/out. Folders from the
# older native layout (<arch>-apple-macosx, apple) are dead once every configuration uses it.
BUILD="$REPO/.build"
if [ -d "$BUILD" ]; then
    # One marker per configuration, e.g. "swiftbuild" (no trailing newline).
    layouts=0 legacy=0
    for marker in "$BUILD"/.buildSystem_*; do
        [ -f "$marker" ] || continue
        layouts=$((layouts + 1))
        [ "$(tr -d '[:space:]' < "$marker")" = swiftbuild ] || legacy=1
    done
    if [ "$layouts" -gt 0 ] && [ "$legacy" = 0 ]; then
        for dir in "$BUILD"/*-apple-macosx "$BUILD"/apple; do
            [ -d "$dir" ] && remove "$dir" "older SwiftPM build layout"
        done
    fi
    [ -d "$BUILD/test-bins" ] && untouched "$BUILD/test-bins" && remove "$BUILD/test-bins" "old test binaries"
fi

# 2. Xcode DerivedData for the Cantrip apps whose checkout no longer exists.
if [ -d "$DERIVED" ]; then
    for dir in "$DERIVED"/Hermes-* "$DERIVED"/CantripGatewayMac-* "$DERIVED"/Cantrip-*; do
        [ -d "$dir" ] || continue
        workspace=$(plutil -extract WorkspacePath raw "$dir/info.plist" 2>/dev/null)
        if [ -n "$workspace" ]; then
            [ -e "$workspace" ] || remove "$dir" "project checkout is gone"
        elif untouched "$dir"; then
            remove "$dir" "package cache with no project, unused for a day"
        fi
    done
fi

# 3. Build and test folders agents leave in /tmp (DerivedData, QA homes, test runners).
if [ -d "$TMPROOT" ]; then
    for dir in "$TMPROOT"/hermes-* "$TMPROOT"/cantrip-*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        untouched "$dir" && remove "$dir" "temporary build folder older than a day"
    done
fi

# 4. Gateway Mac zips: keep the newest two (the installed build and the one before it).
if [ -d "$ZIPS" ]; then
    count=0
    while IFS= read -r zip; do
        [ -n "$zip" ] || continue
        count=$((count + 1))
        [ "$count" -le "$KEEP_ZIPS" ] && continue
        remove "$ZIPS/$zip" "older Gateway Mac build"
    done <<EOF
$(ls -t "$ZIPS" 2>/dev/null | grep -E '^CantripGatewayMac-.*\.zip$')
EOF
fi

if [ "$removed" -gt 0 ]; then
    verb=$([ "$DRY_RUN" = 1 ] && echo "Would free" || echo "Freed")
    awk -v kb="$freed_kb" -v n="$removed" -v verb="$verb" \
        'BEGIN { printf "%s %.1f GB from %d old build folder%s.\n", verb, kb / 1048576, n, (n == 1 ? "" : "s") }'
fi
exit 0
