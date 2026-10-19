PROJECT := CantripGatewayMac.xcodeproj
SCHEME := CantripGatewayMac
APP := Cantrip Gateway Mac.app
# SwiftPM needs its scoped bare-repository cache.
XCODEBUILD := GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
	-clonedSourcePackagesDirPath .spm
TEAM ?= 9M3XNFG4J7
SIGN_IDENTITY ?= Apple Development

.PHONY: project build test release install dmg

project:
	@test -f Hermes/project.yml || git submodule update --init
	xcodegen generate

build: project
	$(XCODEBUILD) -derivedDataPath build/Debug build

test: project
	$(XCODEBUILD) -derivedDataPath build/Debug -collect-test-diagnostics never test

release: project
	$(XCODEBUILD) -configuration Release -derivedDataPath build/Release \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" DEVELOPMENT_TEAM=$(TEAM) build

# Builds Release, replaces /Applications/Cantrip Gateway Mac.app and reopens it.
install: release
	-osascript -e 'tell application id "com.itzhoang.cantripgateway.mac" to quit'
	sleep 1
	rm -rf "/Applications/$(APP)"
	ditto "build/Release/Build/Products/Release/$(APP)" "/Applications/$(APP)"
	open "/Applications/$(APP)"

# Notarized Developer ID DMG + GitHub release: make dmg VERSION=1.0.1
dmg:
	Scripts/release.sh $(VERSION)
