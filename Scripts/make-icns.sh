#!/bin/sh
# Builds Resources/AppIcon.icns from the 1024px master PNG using
# macOS-native tools (sips + iconutil). Runs automatically from make.
set -e
cd "$(dirname "$0")/.."

MASTER="Resources/AppIcon.png"
OUT="Resources/AppIcon.icns"
[ -f "$MASTER" ] || { echo "No $MASTER — skipping icon"; exit 0; }
[ "$OUT" -nt "$MASTER" ] 2>/dev/null && exit 0  # up to date

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$SET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z $double $double "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o "$OUT"
echo "Built $OUT"
