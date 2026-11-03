#!/bin/bash
# The background engine's login agent plist (Scripts/engine-agent-plist.sh), as launchd reads it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

PLIST="$DIR/com.example.cantrip.engine.plist"
bash Scripts/engine-agent-plist.sh com.example.cantrip Cantrip "$PLIST"
get() { plutil -extract "$1" raw "$PLIST"; }
[ "$(get Label)" = com.example.cantrip.engine ] || fail "label is <bundle id>.engine (BackgroundEngine.label)"
[ "$(get BundleProgram)" = Contents/MacOS/Cantrip ] || fail "runs the app's own binary"
[ "$(get ProgramArguments.1) $(get ProgramArguments.2) $(get ProgramArguments.3)" = "--headless --engine --supervised" ] \
    || fail "headless engine under a supervisor"
[ "$(get AssociatedBundleIdentifiers.0)" = com.example.cantrip ] || fail "shown under the app in Login Items"
[ "$(get RunAtLoad)" = true ] || fail "starts at login"
[ "$(get KeepAlive.SuccessfulExit)" = false ] || fail "restarts after a crash, not a clean stop"
[ "$(get ProcessType)" = Interactive ] || fail "not throttled"
if bash Scripts/engine-agent-plist.sh 'com.example"><string>x' Cantrip "$DIR/bad.plist" 2>/dev/null; then
    fail "refuses a bundle identifier that would break the plist"
fi
echo "Background engine agent plist tests passed"
