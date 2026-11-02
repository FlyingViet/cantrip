#!/bin/bash
# Prints where build output goes: a folder for this checkout on $CANTRIP_BUILD_ROOT when that build
# disk (a NAS, say) is mounted and writable, else build/ here. Never fails: it falls back to build/.
cd "$(dirname "$0")/.."
root="${CANTRIP_BUILD_ROOT:-}"
if [ -n "$root" ]; then
    dir="$root/CantripGatewayMac/$(basename "$PWD")-$(printf %s "$PWD" | shasum | cut -c1-8)"
    # Only below an existing root: creating it would put a local folder where the disk mounts.
    if [ -d "$root" ] && mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
        echo "$dir"
        exit 0
    fi
    echo "$root isn't available, so the build goes to build/." >&2
fi
echo build
