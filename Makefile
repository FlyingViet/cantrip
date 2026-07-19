APP_NAME = Cantrip
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
# Historical cert name kept stable so existing permission grants survive.
CERT_NAME = AgentSpotlight Dev

.PHONY: all build cert icon app run clean

all: app

build:
	swift build -c release

# Auto-create the signing certificate if it's missing (first install).
cert:
	@security find-identity -v -p codesigning 2>/dev/null | grep -q "$(CERT_NAME)" \
		|| sh Scripts/make-cert.sh "$(CERT_NAME)"

icon:
	@sh Scripts/make-icns.sh

app: build cert icon
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/ || true
	@IDENT=$$(security find-identity -v -p codesigning 2>/dev/null | grep -q "$(CERT_NAME)" && echo "$(CERT_NAME)" || echo "-"); \
	codesign --force --deep --sign "$$IDENT" $(APP_BUNDLE); \
	if [ "$$IDENT" = "-" ]; then \
		echo "WARNING: ad-hoc signed — cert creation failed, permissions will reset each build (see Scripts/make-cert.sh)."; \
	fi
	@echo "Built $(APP_BUNDLE). Run with: open $(APP_BUNDLE)"

run: app
	-pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5
	open $(APP_BUNDLE)

clean:
	rm -rf .build $(APP_BUNDLE)
