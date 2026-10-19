#!/bin/bash
# Builds a notarized, stapled DMG of Cantrip Gateway Mac and publishes it as a GitHub release.
#
#   Scripts/release.sh 1.0.1            # build, notarize, publish v1.0.1
#   PUBLISH=0 Scripts/release.sh 1.0.1  # build and notarize only
#   NOTARIZE=0 PUBLISH=0 SIGN_IDENTITY="Apple Development" EXPORT_METHOD=development \
#       Scripts/release.sh 0.0.0        # local dry run without a Developer ID certificate
#
# Needs a "Developer ID Application" certificate in the keychain and notarytool credentials
# saved once with:
#   xcrun notarytool store-credentials cantrip-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version, e.g. 1.0.1>}"
TEAM="${TEAM:-9M3XNFG4J7}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
EXPORT_METHOD="${EXPORT_METHOD:-developer-id}"
NOTARY_PROFILE="${NOTARY_PROFILE:-cantrip-notary}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"
APP_NAME="Cantrip Gateway Mac"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="build/Distribution/$VERSION"
ARCHIVE="$OUT/CantripGatewayMac.xcarchive"
DMG="$OUT/CantripGatewayMac-$VERSION.dmg"

say() { printf '\n==> %s\n' "$*"; }

if [ "$PUBLISH" = 1 ]; then
    [ -z "$(git status --porcelain --ignore-submodules=none)" ] \
        || { echo "Commit or stash changes before publishing a release." >&2; exit 1; }
    git fetch -q --tags origin
    ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
        || { echo "Tag v$VERSION already exists." >&2; exit 1; }
fi

if [ -n "${RELEASE_KEYCHAIN:-}" ]; then
    security unlock-keychain -p "$(cat "${RELEASE_KEYCHAIN_PASSWORD_FILE:?}")" "$RELEASE_KEYCHAIN"
fi
security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY" \
    || { echo "No \"$SIGN_IDENTITY\" signing certificate in the keychain." >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
make project >/dev/null

say "Archiving $APP_NAME $VERSION ($BUILD_NUMBER)"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
xcodebuild -quiet -project CantripGatewayMac.xcodeproj -scheme CantripGatewayMac \
    -destination 'generic/platform=macOS' -clonedSourcePackagesDirPath .spm \
    -derivedDataPath build/Distribution/DerivedData -configuration Release \
    -archivePath "$ARCHIVE" archive \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS=--timestamp

say "Exporting ($EXPORT_METHOD)"
OPTIONS="$OUT/ExportOptions.plist"
cp Scripts/ExportOptions.plist "$OPTIONS"
plutil -replace method -string "$EXPORT_METHOD" "$OPTIONS"
plutil -replace signingCertificate -string "$SIGN_IDENTITY" "$OPTIONS"
plutil -insert teamID -string "$TEAM" "$OPTIONS"
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OPTIONS"
APP="$OUT/export/$APP_NAME.app"
codesign --verify --deep --strict "$APP"

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
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
    say "Notarizing the disk image"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    spctl --assess --type execute -v "$APP"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"

if [ "$PUBLISH" = 1 ]; then
    say "Publishing v$VERSION"
    git tag -a "v$VERSION" -m "Cantrip Gateway Mac $VERSION"
    git push -q origin "v$VERSION"
    gh release create "v$VERSION" "$DMG" --verify-tag --title "Cantrip Gateway Mac $VERSION" \
        --notes "Download **CantripGatewayMac-$VERSION.dmg**, open it and drag Cantrip Gateway Mac to Applications. Signed with Developer ID and notarized by Apple. Requires macOS 26 and Cantrip on a Mac to pair with (see the README)."
fi
say "Done: $DMG"
