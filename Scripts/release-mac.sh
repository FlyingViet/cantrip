#!/bin/bash
# Builds Cantrip.app signed with Developer ID (hardened runtime), notarizes and staples it, wraps it
# in a notarized disk image, and attaches the image and its checksum to the host release vX.Y.Z.
# Release installs update from these assets (ReleaseUpdater): Cantrip-X.Y.Z.dmg + .dmg.sha256.
#
#   Scripts/release-mac.sh 1.1.16             # at tag v1.1.16 (checked out, clean): build, notarize, upload
#   PUBLISH=0 Scripts/release-mac.sh 1.1.16   # build and notarize only
#   NOTARIZE=0 PUBLISH=0 SIGN_IDENTITY="Apple Development" Scripts/release-mac.sh 0.0.0   # local dry run
#
# Needs a "Developer ID Application" certificate and notarytool credentials saved once as
# cantrip-notary (xcrun notarytool store-credentials cantrip-notary --key AuthKey_XXXX.p8 --key-id XXXX
# --issuer <uuid>). A dedicated keychain: RELEASE_KEYCHAIN=… RELEASE_KEYCHAIN_PASSWORD_FILE=…
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release-mac.sh <version, e.g. 1.1.16>}"
TAG="v$VERSION"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-cantrip-notary}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"
OUT=".build/distribution/$VERSION"
APP="$OUT/Cantrip.app"
DMG="$OUT/Cantrip-$VERSION.dmg"

say() { printf '\n==> %s\n' "$*"; }

if [ "$PUBLISH" = 1 ]; then
    [ -z "$(git status --porcelain)" ] || { echo "Commit or stash changes before publishing." >&2; exit 1; }
    [ "$(git describe --exact-match --match 'v[0-9]*' HEAD 2>/dev/null)" = "$TAG" ] \
        || { echo "Check out the tag $TAG first (HEAD is $(git describe --always --match 'v[0-9]*'))." >&2; exit 1; }
    gh release view "$TAG" >/dev/null || { echo "Publish the GitHub release $TAG first." >&2; exit 1; }
    ! gh release view "$TAG" --json assets -q '.assets[].name' | grep -qx "Cantrip-$VERSION.dmg" \
        || { echo "$TAG already has Cantrip-$VERSION.dmg." >&2; exit 1; }
fi

if [ -n "${RELEASE_KEYCHAIN:-}" ]; then
    security unlock-keychain -p "$(cat "${RELEASE_KEYCHAIN_PASSWORD_FILE:?}")" "$RELEASE_KEYCHAIN"
fi
security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY" \
    || { echo "No \"$SIGN_IDENTITY\" signing certificate in the keychain." >&2; exit 1; }

say "Building Cantrip $VERSION (Universal) and the Home window"
make build icon home-window
[ -d .build/home-window/CantripHomeWindow.bundle ] \
    || { echo "The Home window didn't build (see .build/home-window/build.log); releases include it." >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)" bash Scripts/assemble-app.sh "$APP"
IDENTITY=$(plutil -extract CantripBuildIdentity raw "$APP/Contents/Info.plist")
if [ "$PUBLISH" = 1 ] && [ "$IDENTITY" != "$TAG" ]; then
    echo "The build is stamped $IDENTITY, not $TAG." >&2; exit 1
fi

say "Signing ($SIGN_IDENTITY, hardened runtime)"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    "$APP/Contents/PlugIns/CantripHomeWindow.bundle"
codesign --force --options runtime --timestamp --entitlements Resources/Cantrip.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
        | tee "$OUT/notary-$(basename "$1").log"
    grep -q "status: Accepted" "$OUT/notary-$(basename "$1").log" \
        || { echo "Notarization of $1 was not accepted." >&2; exit 1; }
}

if [ "$NOTARIZE" = 1 ]; then
    say "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/app.zip"
    notarize "$OUT/app.zip"
    xcrun stapler staple "$APP"
fi

say "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Cantrip.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cantrip" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
    say "Notarizing the disk image"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    spctl --assess --type execute -v "$APP"
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cat "$DMG.sha256"

if [ "$PUBLISH" = 1 ]; then
    say "Attaching the disk image to $TAG"
    gh release upload "$TAG" "$DMG" "$DMG.sha256"
    rm -rf "$OUT/dmg" "$OUT/app.zip"
fi
say "Done: $DMG"
