#!/bin/bash
# Writes the launchd plist of Cantrip's background engine ("Keep agents running when Cantrip quits",
# Sources/Cantrip/BackgroundEngine.swift), which the app registers with SMAppService from
# Contents/Library/LaunchAgents/<bundle id>.engine.plist. Scripts/assemble-app.sh runs it.
#
#   Scripts/engine-agent-plist.sh <bundle identifier> <executable name> <output plist>
set -euo pipefail

ID="${1:?usage: engine-agent-plist.sh <bundle identifier> <executable name> <output plist>}"
EXECUTABLE="${2:?executable name}"
OUT="${3:?output plist}"
[[ "$ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "engine-agent-plist: unexpected bundle identifier: $ID" >&2; exit 1; }
[[ "$EXECUTABLE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "engine-agent-plist: unexpected executable: $EXECUTABLE" >&2; exit 1; }

# KeepAlive restarts it after a crash; a clean exit (stopped, or another Cantrip holds the host
# lock: --supervised) stays down. Interactive keeps agents' builds from being throttled.
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$ID.engine</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/$EXECUTABLE</string>
	<key>ProgramArguments</key>
	<array>
		<string>Contents/MacOS/$EXECUTABLE</string>
		<string>--headless</string>
		<string>--engine</string>
		<string>--supervised</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$ID</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint -s "$OUT"
