#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "Usage: bash Scripts/verify-macos-architectures.sh path/to/Cantrip.app" >&2
    exit 1
fi

bundle="$1"
executable="$bundle/Contents/MacOS/Cantrip"
if [ ! -x "$executable" ]; then
    echo "Missing executable: $executable" >&2
    exit 1
fi

version_at_most() {
    awk -v actual="$1" -v maximum="$2" 'BEGIN {
        pattern = "^[0-9]+([.][0-9]+)?([.][0-9]+)?$"
        if (actual !~ pattern || maximum !~ pattern) exit 1
        split(actual, a, "."); split(maximum, m, ".")
        for (i = 1; i <= 3; i++) {
            if (a[i] + 0 < m[i] + 0) exit 0
            if (a[i] + 0 > m[i] + 0) exit 1
        }
        exit 0
    }'
}

plist="$bundle/Contents/Info.plist"
if ! minimum=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -expect string "$plist"); then
    echo "Missing or invalid LSMinimumSystemVersion: $plist" >&2
    exit 1
fi
# Keep the support floor even when building with a newer SDK.
if ! version_at_most "$minimum" "14.0"; then
    echo "Incompatible LSMinimumSystemVersion: $plist ($minimum; must support macOS 14.0)" >&2
    exit 1
fi

verify_binary() {
    local architectures required build_info deployment
    if ! architectures=$(/usr/bin/lipo -archs "$1"); then
        echo "Cannot read macOS architectures: $1" >&2
        return 1
    fi
    for required in arm64 x86_64; do
        case " $architectures " in
            *" $required "*) ;;
            *)
                echo "Incompatible macOS component: $1 (missing $required)" >&2
                echo "Rebuild or replace it with a Universal (arm64 + x86_64) version." >&2
                return 1
                ;;
        esac
        if ! build_info=$(xcrun vtool -arch "$required" -show-build "$1"); then
            echo "Cannot read macOS deployment target: $1 ($required)" >&2
            return 1
        fi
        # Inspect each slice: an app can be Universal yet require a newer OS.
        if ! deployment=$(awk '
            $1 == "cmd" { command = $2 }
            command == "LC_BUILD_VERSION" && $1 == "platform" {
                platforms++; platform = $2
            }
            command == "LC_BUILD_VERSION" && $1 == "minos" {
                versions++; version = $2
            }
            command == "LC_VERSION_MIN_MACOSX" && $1 == "version" {
                platforms++; platform = "MACOS"; versions++; version = $2
            }
            END {
                if (platforms != 1 || platform != "MACOS" || versions != 1) exit 1
                print version
            }' <<< "$build_info"); then
            echo "Missing or non-macOS deployment metadata: $1 ($required)" >&2
            return 1
        fi
        if ! version_at_most "$deployment" "$minimum"; then
            echo "Incompatible macOS deployment target: $1 ($required requires $deployment; app promises $minimum)" >&2
            return 1
        fi
    done
}

verify_binary "$executable"
manifest=$(mktemp -t cantrip-architectures)
trap 'rm -f "$manifest"' EXIT
# Follow framework symlinks and fail on broken links or traversal errors.
find -L "$bundle" \( -type f -o -type l \) -print0 > "$manifest"
count=0
while IFS= read -r -d '' component; do
    if [ ! -f "$component" ]; then
        echo "Unreadable bundled component: $component" >&2
        exit 1
    fi
    description=$(/usr/bin/file -L -b "$component")
    case "$description" in
        *Mach-O*)
            verify_binary "$component"
            count=$((count + 1))
            ;;
    esac
done < "$manifest"

echo "Universal macOS compatibility check passed ($count Mach-O files; minimum $minimum)."
