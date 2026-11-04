APP_NAME = Cantrip
BUILD_FLAGS = -c release --arch arm64 --arch x86_64
BUILD_DIR = $(shell swift build $(BUILD_FLAGS) --show-bin-path)
APP_BUNDLE = $(APP_NAME).app
APP_STAGING = .$(APP_NAME).app.staging
APP_BACKUP = .$(APP_NAME).app.previous
# A build made while Cantrip runs waits here; the next launch installs it.
APP_PENDING = .$(APP_NAME).app.pending
# Historical cert name is preferred so existing permission grants survive.
CERT_NAME = AgentSpotlight Dev

.PHONY: all build home-window test test-prune prune-builds test-architectures test-tool-path test-process-runner test-iso-date test-cantrip-paths test-context test-features test-copilot-parser test-package-tracking test-recovery test-run-journal test-message-deletion test-remote-images test-mac-context test-github-auth test-remote-routing test-message-routing test-session-tabs test-settings-manifest test-maintenance test-release-updater test-github-builds test-mcp-on-demand test-consolidation test-voice-vocabulary test-backend-commands test-web-slash test-storage-upkeep test-build-caches test-simulator-pool test-browser-preview test-browser-preview-live test-rich-cards test-agent-policy test-skills test-secrets test-environments cert artwork icon app run clean

all: app

build:
	swift build $(BUILD_FLAGS)

test: test-prune test-architectures test-tool-path test-process-runner test-iso-date test-cantrip-paths test-context test-features test-copilot-parser test-package-tracking test-recovery test-background-engine test-release-updater test-run-journal test-message-deletion test-remote-images test-mac-context test-github-auth test-remote-routing test-message-routing test-session-tabs test-github-builds test-mcp-on-demand test-consolidation test-voice-vocabulary test-backend-commands test-web-slash test-storage-upkeep test-build-caches test-simulator-pool test-browser-preview test-rich-cards test-agent-policy test-skills test-secrets test-environments

test-agent-policy:
	@BIN="/tmp/cantrip-agent-policy-tests-$$$$"; HOME_DIR="$$(mktemp -d)"; \
	trap 'rm -rf "$$BIN" "$$HOME_DIR"' EXIT; \
	swiftc Sources/Cantrip/ShellCommandText.swift Sources/Cantrip/AgentActionRequest.swift Sources/Cantrip/AgentPolicy.swift Sources/Cantrip/AgentPolicySetup.swift Tests/AgentPolicyTests/ImportTests.swift Tests/AgentPolicyTests/main.swift -o "$$BIN" && HOME="$$HOME_DIR" CFFIXED_USER_HOME="$$HOME_DIR" "$$BIN"

test-architectures:
	@bash Tests/ArchitectureTests/run.sh

test-tool-path:
	@BIN="/tmp/cantrip-tool-path-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ToolPath.swift Sources/Cantrip/ToolLocator.swift Sources/Cantrip/ProcessRunner.swift Tests/ToolPathTests/main.swift -o "$$BIN" && "$$BIN"

test-process-runner:
	@BIN="/tmp/cantrip-process-runner-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ProcessRunner.swift Tests/ProcessRunnerTests/main.swift -o "$$BIN" && "$$BIN"

test-iso-date:
	@BIN="/tmp/cantrip-iso-date-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ISODate.swift Tests/ISODateTests/main.swift -o "$$BIN" && "$$BIN"

test-cantrip-paths:
	@BIN="/tmp/cantrip-paths-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/CantripPaths.swift Sources/Cantrip/CantripInstall.swift Sources/Cantrip/TabDefaults.swift Tests/CantripPathsTests/main.swift -o "$$BIN" && "$$BIN"

test-github-builds:
	@BIN="/tmp/cantrip-github-build-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/GitHubBuildMonitor.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ToolLocator.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/ISODate.swift Tests/GitHubBuildTests/main.swift -o "$$BIN" && "$$BIN"

test-session-tabs:
	@BIN="/tmp/cantrip-session-tab-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc -parse-as-library $(filter-out Sources/Cantrip/main.swift,$(wildcard Sources/Cantrip/*.swift Sources/Cantrip/Backends/*.swift)) Tests/SessionTabTests/*.swift -o "$$BIN" && "$$BIN"

# The settings manifest alone (it's also part of test-session-tabs).
test-settings-manifest:
	@BIN="/tmp/cantrip-settings-manifest-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc -parse-as-library $(filter-out Sources/Cantrip/main.swift,$(wildcard Sources/Cantrip/*.swift Sources/Cantrip/Backends/*.swift)) Tests/SessionTabTests/*.swift -o "$$BIN" && CANTRIP_TAB_TEST_ONLY=settings "$$BIN"

# Paired-device maintenance (check, update, rebuild, restart) for source and release installs.
test-maintenance:
	@BIN="/tmp/cantrip-maintenance-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -f "$$BIN"; rm -rf "$$H"' EXIT; \
	swiftc -parse-as-library $(filter-out Sources/Cantrip/main.swift,$(wildcard Sources/Cantrip/*.swift Sources/Cantrip/Backends/*.swift)) Tests/SessionTabTests/*.swift -o "$$BIN" && \
	HOME="$$H" CFFIXED_USER_HOME="$$H" CANTRIP_TAB_TEST_HOME="$$H" CANTRIP_TAB_TEST_ONLY=maintenance "$$BIN"

test-message-routing:
	@BIN="/tmp/cantrip-message-routing-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/MessageRouting.swift Sources/Cantrip/MessageRouter.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/QueueGrouping.swift Sources/Cantrip/ConversationContext.swift Sources/Cantrip/MCPApps.swift Sources/Cantrip/Backends/Backend.swift Sources/Cantrip/Backends/CopilotJSONStreamParser.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Tests/MessageRoutingTests/main.swift -o "$$BIN" && "$$BIN"

test-mac-context:
	@BIN="/tmp/cantrip-mac-context-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/RemoteMacContext.swift Tests/MacContextTests/main.swift -o "$$BIN" && "$$BIN"

test-github-auth:
	@BIN="/tmp/cantrip-github-auth-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/GitHubAuthStatus.swift Tests/GitHubAuthTests/main.swift -o "$$BIN" && "$$BIN"

test-remote-routing:
	@BIN="/tmp/cantrip-remote-routing-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/HTTPRequest.swift Sources/Cantrip/HTTPCompression.swift Sources/Cantrip/RemoteLANProtocol.swift Sources/Cantrip/RemoteRouteClient.swift Sources/Cantrip/RemoteLANClient.swift Tests/RemoteRoutingTests/main.swift -o "$$BIN" && "$$BIN"

test-browser-preview:
	@BIN="/tmp/cantrip-browser-preview-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/BrowserPreview.swift Tests/BrowserPreviewTests/main.swift -o "$$BIN" && "$$BIN"

# Not part of `make test`: drives a throwaway headed Chrome and screenshots its window (needs a
# logged-in display and Screen Recording).
test-browser-preview-live:
	@BIN="/tmp/cantrip-browser-preview-live-$$$$"; HOME_DIR="$$(mktemp -d)"; \
	trap 'rm -rf "$$BIN" "$$HOME_DIR"' EXIT; \
	swiftc Sources/Cantrip/BrowserPreview.swift Tests/BrowserPreviewLiveTests/main.swift -o "$$BIN" && CFFIXED_USER_HOME="$$HOME_DIR" "$$BIN"

test-rich-cards:
	@BIN="/tmp/cantrip-rich-card-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -f "$$BIN"; rm -rf "$$H"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/CantripPaths.swift Sources/Cantrip/RichCards.swift Sources/Cantrip/WeatherCards.swift Tests/RichCardTests/*.swift -o "$$BIN" && CFFIXED_USER_HOME="$$H" "$$BIN"

test-remote-images:
	@BIN="/tmp/cantrip-remote-image-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/RemoteImageAttachments.swift Sources/Cantrip/RemoteGeneratedImages.swift Sources/Cantrip/SessionOutputFolders.swift Sources/Cantrip/CantripPaths.swift Tests/RemoteImageTests/main.swift -o "$$BIN" && "$$BIN"

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

test-copilot-parser:
	@BIN="/tmp/cantrip-copilot-parser-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ConversationContext.swift Sources/Cantrip/MCPApps.swift Sources/Cantrip/PromptUsage.swift Sources/Cantrip/Backends/Backend.swift Sources/Cantrip/Backends/CopilotJSONStreamParser.swift Sources/Cantrip/ISODate.swift Tests/CopilotJSONStreamParserTests/*.swift -o "$$BIN"; \
	"$$BIN"

test-package-tracking:
	@BIN="/tmp/cantrip-package-tracking-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/PackageTracking.swift Sources/Cantrip/ISODate.swift Tests/PackageTrackingTests/main.swift -o "$$BIN"; \
	"$$BIN"

# Release installs' updater: GitHub's release, checksums, and only Cantrip's notarized build is staged.
# CANTRIP_RELEASE_DMG=path/Cantrip-X.Y.Z.dmg also checks a real release image.
test-release-updater:
	@BIN="/tmp/cantrip-release-updater-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -f "$$BIN"; rm -rf "$$H"' EXIT; \
	swiftc Sources/Cantrip/ReleaseUpdater.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/CrashRecovery.swift Sources/Cantrip/PendingUpdate.swift Sources/Cantrip/CantripInstall.swift Sources/Cantrip/CantripVersion.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/HostLock.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/ReleaseUpdaterTests/main.swift -o "$$BIN" && \
	CFFIXED_USER_HOME="$$H" "$$BIN"

test-recovery:
	@BIN="/tmp/cantrip-recovery-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/CrashRecovery.swift Sources/Cantrip/PendingUpdate.swift Sources/Cantrip/CantripInstall.swift Sources/Cantrip/CantripVersion.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/HostLock.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/CrashRecoveryTests/*.swift -o "$$BIN"; \
	"$$BIN"

# The background engine's notification outbox and its login agent's plist.
test-background-engine:
	@BIN="/tmp/cantrip-background-engine-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -rf "$$BIN" "$$H"' EXIT; \
	swiftc Sources/Cantrip/MacNotices.swift Sources/Cantrip/HostLock.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/BackgroundEngineTests/main.swift -o "$$BIN" && \
	HOME="$$H" CFFIXED_USER_HOME="$$H" "$$BIN" && \
	bash Tests/BackgroundEngineTests/agent-plist.sh

test-consolidation:
	@BIN="/tmp/cantrip-consolidation-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/ConsolidationPolicy.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Tests/ConsolidationTests/main.swift -o "$$BIN" && "$$BIN"

# Fixtures (SQLite databases, a memory folder) are written under .build and removed afterwards.
test-voice-vocabulary:
	@mkdir -p .build; BIN=".build/cantrip-voice-vocabulary-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/VoiceVocabulary.swift Sources/Cantrip/VoiceVocabularySources.swift Tests/VoiceVocabularyTests/main.swift -o "$$BIN" && VOICE_VOCABULARY_TEST_DIR="$(CURDIR)/.build" "$$BIN"

# Fake CLIs and a temp project under $$TMPDIR; CANTRIP_COMMANDS_LIVE_TEST=1 also asks the real CLIs.
test-backend-commands:
	@BIN="/tmp/cantrip-backend-command-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/BackendCommands.swift Sources/Cantrip/BackendCommandDiscovery.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/CopilotRuntime.swift Tests/BackendCommandTests/main.swift -o "$$BIN" && "$$BIN"

# Temp git repositories and session folders under $$TMPDIR, removed afterwards.
test-storage-upkeep:
	@BIN="/tmp/cantrip-storage-upkeep-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/StorageUpkeep.swift Sources/Cantrip/BuildCaches.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/SimulatorPool.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/StorageUpkeepTests/main.swift -o "$$BIN" && "$$BIN"

# A fake simctl and a temporary state folder; no real simulator is touched.
test-build-caches:
	@BIN="/tmp/cantrip-build-cache-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/BuildCaches.swift Sources/Cantrip/StorageUpkeep.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/SimulatorPool.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/BuildCacheTests/main.swift -o "$$BIN" && "$$BIN"

test-simulator-pool:
	@BIN="/tmp/cantrip-simulator-pool-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/SimulatorPool.swift Sources/Cantrip/StorageUpkeep.swift Sources/Cantrip/BuildCaches.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Tests/SimulatorPoolTests/main.swift -o "$$BIN" && "$$BIN"

# Fake skills and repositories in a temporary home (the binary re-runs itself there); no network.
test-skills:
	@BIN="/tmp/cantrip-skills-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/SecretScan.swift Sources/Cantrip/SkillsLibrary.swift Sources/Cantrip/FolderInstructions.swift Sources/Cantrip/PrivateFile.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/CantripPaths.swift Tests/SkillsTests/main.swift -o "$$BIN" && "$$BIN"

# Delete message: memory log, backend transcript and Cantrip log scrubbing (temporary home).
test-message-deletion:
	@BIN="/tmp/cantrip-message-deletion-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -f "$$BIN"; rm -rf "$$H"' EXIT; \
	swiftc Sources/Cantrip/MessageDeletion.swift Sources/Cantrip/Log.swift Sources/Cantrip/SecretMasking.swift Tests/MessageDeletionTests/main.swift -o "$$BIN" && \
	CFFIXED_USER_HOME="$$H" "$$BIN"

test-run-journal:
	@BIN="/tmp/cantrip-run-journal-tests-$$$$"; \
	trap 'rm -f "$$BIN"' EXIT; \
	swiftc Sources/Cantrip/RunJournal.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/CantripPaths.swift Tests/RunJournalTests/main.swift -o "$$BIN"; \
	"$$BIN"

# Auto-create the signing certificate if it's missing (first install).
cert:
	@security find-identity -v -p codesigning 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]+\)' \
		|| sh Scripts/make-cert.sh "$(CERT_NAME)"

artwork:
	swift Scripts/generate-artwork.swift
	@sh Scripts/make-icns.sh

icon:
	@sh Scripts/make-icns.sh

# The Window interface's plug-in (optional; see Scripts/build-home-window.sh).
home-window:
	@bash Scripts/build-home-window.sh

app: build cert icon home-window
	@set -eu; \
	APP="$(APP_BUNDLE)"; STAGING="$(APP_STAGING)"; BACKUP="$(APP_BACKUP)"; PENDING="$(APP_PENDING)"; \
	cleanup() { \
		status=$$?; trap - EXIT HUP INT TERM; rm -rf "$$STAGING"; \
		if [ ! -e "$$APP" ] && [ -e "$$BACKUP" ]; then mv "$$BACKUP" "$$APP"; fi; \
		exit $$status; \
	}; \
	trap cleanup EXIT HUP INT TERM; \
	if [ ! -e "$$APP" ] && [ -e "$$BACKUP" ]; then mv "$$BACKUP" "$$APP"; fi; \
	rm -rf "$$STAGING" "$$BACKUP"; \
	BUILD_DIR="$(BUILD_DIR)" APP_NAME="$(APP_NAME)" bash Scripts/assemble-app.sh "$$STAGING"; \
	BUILD_ID=$$(plutil -extract CantripBuildIdentity raw "$$STAGING/Contents/Info.plist"); \
	BUILD_DATE=$$(plutil -extract CantripBuildDate raw "$$STAGING/Contents/Info.plist"); \
	IDENT=$$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' \
		'/"$(CERT_NAME)"/ { print $$2; found=1; exit } /^[[:space:]]*[0-9]+\)/ && first == "" { first=$$2 } END { if (!found && first != "") print first }'); \
	[ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --deep --sign "$$IDENT" "$$STAGING"; \
	codesign --verify --deep --strict "$$STAGING"; \
	if [ "$$IDENT" = "-" ]; then \
		echo "WARNING: ad-hoc signed — cert creation failed, permissions will reset each build (see Scripts/make-cert.sh)."; \
	fi; \
	if [ "$${CANTRIP_INSTALL_NOW:-0}" != 1 ] && [ -e "$$APP/Contents/MacOS/$(APP_NAME)" ] \
		&& /usr/sbin/lsof -t -- "$$APP/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1; then \
		rm -rf "$$PENDING"; \
		mv "$$STAGING" "$$PENDING"; \
		trap - EXIT HUP INT TERM; \
		echo "Built $$PENDING ($$BUILD_ID at $$BUILD_DATE)."; \
		echo "Cantrip is running, so $$APP was left untouched to keep its macOS permissions valid."; \
		echo "Quit and reopen Cantrip to install this build."; \
		exit 0; \
	fi; \
	if [ -e "$$APP" ]; then mv "$$APP" "$$BACKUP"; fi; \
	mv "$$STAGING" "$$APP"; \
	rm -rf "$$BACKUP" "$$PENDING"; \
	trap - EXIT HUP INT TERM; \
	echo "Built $$APP ($$BUILD_ID at $$BUILD_DATE). Run with: open $$APP"
	@# Every update (Update and Restart, agent deploys) also clears old build folders.
	@bash Scripts/prune-build-folders.sh || true

# Lists what an update would clear: make prune-builds ARGS=--dry-run
prune-builds:
	@bash Scripts/prune-build-folders.sh $(ARGS)

test-prune:
	@bash Tests/PruneBuildTests/run.sh

# The secrets broker's import, sync, run and masking, in a temporary home with a fake `bw` and keychain.
test-secrets:
	@BIN="/tmp/cantrip-secret-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -rf "$$BIN" "$$H"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/Secrets.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/SecretKeychain.swift Sources/Cantrip/SecretVault.swift Sources/Cantrip/SecretCLI.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ToolLocator.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Sources/Cantrip/PrivateFile.swift Tests/SecretBrokerTests/main.swift -o "$$BIN" && \
	HOME="$$H" CFFIXED_USER_HOME="$$H" CANTRIP_TAB_TEST_HOME="$$H" "$$BIN"

# Environment profiles: matching, Xcode/Node resolution and real zsh/bash startup files, in a temporary home.
test-environments:
	@BIN="/tmp/cantrip-environment-tests-$$$$"; H="$$(mktemp -d)"; \
	trap 'rm -rf "$$BIN" "$$H"' EXIT; \
	swiftc -parse-as-library Sources/Cantrip/EnvironmentProfiles.swift Sources/Cantrip/EnvironmentCLI.swift Sources/Cantrip/Secrets.swift Sources/Cantrip/SecretMasking.swift Sources/Cantrip/SecretKeychain.swift Sources/Cantrip/SecretVault.swift Sources/Cantrip/SecretCLI.swift Sources/Cantrip/ProcessRunner.swift Sources/Cantrip/ToolLocator.swift Sources/Cantrip/ToolPath.swift Sources/Cantrip/ISODate.swift Sources/Cantrip/CantripPaths.swift Sources/Cantrip/PrivateFile.swift Tests/EnvironmentProfileTests/main.swift -o "$$BIN" && \
	HOME="$$H" CFFIXED_USER_HOME="$$H" CANTRIP_TAB_TEST_HOME="$$H" "$$BIN"

test-mcp-on-demand:
	@python3 Tests/MCPOnDemandTests/test_mcp_on_demand.py

# Runs the browser Remote's slash-command matching and caching code straight from webAppTemplate.
test-web-slash:
	@node Tests/WebSlashCommandTests/run.mjs

run: app
	-/usr/bin/osascript -e 'tell application id "com.brian.agentspotlight" to quit' 2>/dev/null
	@sleep 0.5
	@open -n $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE) $(APP_STAGING) $(APP_BACKUP) $(APP_PENDING)
