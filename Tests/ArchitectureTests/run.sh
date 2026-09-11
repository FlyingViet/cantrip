#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

scratch=$(mktemp -d -t cantrip-architecture-tests)
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/Bundle With Spaces.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
fixture="Tests/ArchitectureTests/fixture.c"
verifier="Scripts/verify-macos-architectures.sh"

xcrun clang -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 "$fixture" -o "$scratch/universal"
xcrun clang -mmacosx-version-min=14.0 -arch x86_64 "$fixture" -o "$scratch/intel"
xcrun clang -mmacosx-version-min=14.0 -arch arm64 "$fixture" -o "$scratch/arm"
xcrun clang -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 -dynamiclib "$fixture" -o "$scratch/universal.dylib"
xcrun clang -mmacosx-version-min=14.0 -arch x86_64 -dynamiclib "$fixture" -o "$scratch/intel.dylib"
xcrun clang -mmacosx-version-min=27.0 -arch arm64 "$fixture" -o "$scratch/arm27"
xcrun clang -mmacosx-version-min=26.0 -arch x86_64 "$fixture" -o "$scratch/intel26"
xcrun clang -mmacosx-version-min=14.1 -arch arm64 -arch x86_64 -dynamiclib "$fixture" -o "$scratch/newer.dylib"
xcrun clang -mmacosx-version-min=10.13 -arch x86_64 "$fixture" -o "$scratch/legacy-intel"

expect_failure() {
    if bash "$verifier" "$bundle" > "$scratch/result" 2>&1; then
        echo "FAIL: $1 was accepted" >&2
        exit 1
    fi
    if ! grep -Fq "$2" "$scratch/result"; then
        echo "FAIL: $1 did not report the offending component" >&2
        sed -n '1,20p' "$scratch/result" >&2
        exit 1
    fi
}

expect_failure "missing app executable" "Missing executable:"
cp "$scratch/universal" "$bundle/Contents/MacOS/Cantrip"
expect_failure "missing app metadata" "LSMinimumSystemVersion"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
for minimum in 26.0 27.0 14.0.1 invalid; do
    plutil -replace LSMinimumSystemVersion -string "$minimum" "$bundle/Contents/Info.plist"
    expect_failure "unsupported app minimum $minimum" "Incompatible LSMinimumSystemVersion:"
done
plutil -replace LSMinimumSystemVersion -string 13.0 "$bundle/Contents/Info.plist"
expect_failure "app metadata below binary minimum" "Incompatible macOS deployment target:"
plutil -replace LSMinimumSystemVersion -string 14.0.0 "$bundle/Contents/Info.plist"
bash "$verifier" "$bundle"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp "$scratch/universal.dylib" "$bundle/Contents/Frameworks/helper.dylib"
cp "$verifier" "$bundle/Contents/MacOS/script-helper"
ln -s helper.dylib "$bundle/Contents/Frameworks/helper-link"
bash "$verifier" "$bundle"

cp "$scratch/intel" "$bundle/Contents/MacOS/Cantrip"
expect_failure "Intel-only app" "Contents/MacOS/Cantrip"
cp "$scratch/arm" "$bundle/Contents/MacOS/Cantrip"
expect_failure "ARM-only app without Intel support" "Contents/MacOS/Cantrip"
cp "$scratch/universal" "$bundle/Contents/MacOS/Cantrip"

xcrun lipo -create "$scratch/arm27" "$scratch/intel" -output "$bundle/Contents/MacOS/Cantrip"
expect_failure "macOS 27-only ARM slice" "arm64 requires 27.0"
xcrun lipo -create "$scratch/arm" "$scratch/intel26" -output "$bundle/Contents/MacOS/Cantrip"
expect_failure "macOS 26-only Intel slice" "x86_64 requires 26.0"
xcrun lipo -create "$scratch/arm" "$scratch/legacy-intel" -output "$bundle/Contents/MacOS/Cantrip"
bash "$verifier" "$bundle"
xcrun vtool -arch arm64 -set-build-version ios 14.0 27.0 -replace \
    -output "$bundle/Contents/MacOS/Cantrip" "$scratch/universal"
expect_failure "non-macOS platform slice" "Missing or non-macOS deployment metadata:"
cp "$scratch/universal" "$bundle/Contents/MacOS/Cantrip"

cp "$scratch/intel" "$bundle/Contents/MacOS/helper"
expect_failure "Intel-only helper" "Contents/MacOS/helper"
rm "$bundle/Contents/MacOS/helper"
cp "$scratch/intel.dylib" "$bundle/Contents/Frameworks/helper.dylib"
expect_failure "Intel-only library" "Contents/Frameworks/helper"
cp "$scratch/universal.dylib" "$bundle/Contents/Frameworks/helper.dylib"
cp "$scratch/newer.dylib" "$bundle/Contents/Frameworks/newer.dylib"
expect_failure "library requiring a newer minor OS version" "requires 14.1"
rm "$bundle/Contents/Frameworks/newer.dylib"

cp "$scratch/intel.dylib" "$bundle/Contents/Frameworks/native-addon.node"
chmod -x "$bundle/Contents/Frameworks/native-addon.node"
expect_failure "non-executable Intel-only addon" "native-addon.node"
rm "$bundle/Contents/Frameworks/native-addon.node"
ln -s missing.dylib "$bundle/Contents/Frameworks/broken-link"
expect_failure "broken library symlink" "broken-link"
rm "$bundle/Contents/Frameworks/broken-link"
bash "$verifier" "$bundle"

echo "macOS packaging architecture and deployment-target tests passed"
