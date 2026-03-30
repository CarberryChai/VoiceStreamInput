APP_NAME := VoiceStreamInput
APP_BUNDLE := .build/app/$(APP_NAME).app
BIN_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null)
BIN_PATH := $(BIN_DIR)/$(APP_NAME)

.PHONY: build run install clean

build:
	swift build -c release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(BIN_PATH) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	chmod +x $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --deep --sign - $(APP_BUNDLE)

run: build
	open $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app

clean:
	rm -rf .build
