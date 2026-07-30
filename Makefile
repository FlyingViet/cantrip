APP_NAME = Cantrip
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
APP_STAGING = .$(APP_NAME).app.staging
APP_BACKUP = .$(APP_NAME).app.previous
# Historical cert name is preferred so existing permission grants survive.
CERT_NAME = AgentSpotlight Dev

.PHONY: all build test test-context test-features test-recovery cert icon app run clean

all: app

build:
	swift build -c release

test: test-context test-features test-recovery

test-context:
	@BIN="/tmp/cantrip-context-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ConversationContext.swift Tests/ContextTests/main.swift -o "$$BIN"; \
	"$$BIN"

test-features:
	@BIN="/tmp/cantrip-feature-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/AppSearch.swift Tests/FeatureTests/main.swift -o "$$BIN"; \
	"$$BIN"

test-recovery:
	@BIN="/tmp/cantrip-recovery-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/CrashRecovery.swift Tests/CrashRecoveryTests/main.swift -o "$$BIN"; \
	"$$BIN"

# Auto-create the signing certificate if it's missing (first install).
cert:
	@security find-identity -v -p codesigning 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]+\)' \
		|| sh Scripts/make-cert.sh "$(CERT_NAME)"

icon:
	@sh Scripts/make-icns.sh

app: build cert icon
	@set -eu; \
	APP="$(APP_BUNDLE)"; STAGING="$(APP_STAGING)"; BACKUP="$(APP_BACKUP)"; \
	cleanup() { \
		status=$$?; trap - EXIT HUP INT TERM; rm -rf "$$STAGING"; \
		if [ ! -e "$$APP" ] && [ -e "$$BACKUP" ]; then mv "$$BACKUP" "$$APP"; fi; \
		exit $$status; \
	}; \
	trap cleanup EXIT HUP INT TERM; \
	if [ ! -e "$$APP" ] && [ -e "$$BACKUP" ]; then mv "$$BACKUP" "$$APP"; fi; \
	rm -rf "$$STAGING" "$$BACKUP"; \
	mkdir -p "$$STAGING/Contents/MacOS" "$$STAGING/Contents/Resources"; \
	cp "$(BUILD_DIR)/$(APP_NAME)" "$$STAGING/Contents/MacOS/"; \
	cp Resources/Info.plist "$$STAGING/Contents/"; \
	BUILD_ID=$$(git describe --always --dirty 2>/dev/null || echo unknown); \
	BUILD_DATE=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	plutil -replace CantripBuildIdentity -string "$$BUILD_ID" "$$STAGING/Contents/Info.plist"; \
	plutil -replace CantripBuildDate -string "$$BUILD_DATE" "$$STAGING/Contents/Info.plist"; \
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$$STAGING/Contents/Resources/"; fi; \
	IDENT=$$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' \
		'/"$(CERT_NAME)"/ { print $$2; found=1; exit } /^[[:space:]]*[0-9]+\)/ && first == "" { first=$$2 } END { if (!found && first != "") print first }'); \
	[ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --deep --sign "$$IDENT" "$$STAGING"; \
	codesign --verify --deep --strict "$$STAGING"; \
	if [ "$$IDENT" = "-" ]; then \
		echo "WARNING: ad-hoc signed — cert creation failed, permissions will reset each build (see Scripts/make-cert.sh)."; \
	fi; \
	if [ -e "$$APP" ]; then mv "$$APP" "$$BACKUP"; fi; \
	mv "$$STAGING" "$$APP"; \
	rm -rf "$$BACKUP"; \
	trap - EXIT HUP INT TERM; \
	echo "Built $$APP ($$BUILD_ID at $$BUILD_DATE). Run with: open $$APP"

run: app
	-/usr/bin/osascript -e 'tell application id "com.brian.agentspotlight" to quit' 2>/dev/null
	@sleep 0.5
	@open -n $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE) $(APP_STAGING) $(APP_BACKUP)
