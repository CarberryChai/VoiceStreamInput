APP_NAME := VoiceStreamInput
APP_BUNDLE := .build/app/$(APP_NAME).app
BIN_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null)
BIN_PATH := $(BIN_DIR)/$(APP_NAME)
SIGN_IDENTITY ?=

.PHONY: build run install clean

build:
	swift build -c release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(BIN_PATH) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	chmod +x $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@IDENTITY="$(SIGN_IDENTITY)"; \
	if [ -z "$$IDENTITY" ]; then \
		IDENTITY="$$(security find-identity -v -p codesigning 2>/dev/null | awk -F '\"' '/Apple Development:/ { print $$2; exit }')"; \
	fi; \
	if [ -n "$$IDENTITY" ]; then \
		codesign --force --deep --sign "$$IDENTITY" $(APP_BUNDLE); \
	else \
		codesign --force --deep --sign - $(APP_BUNDLE); \
	fi

run: build
	open $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app

clean:
	rm -rf .build
