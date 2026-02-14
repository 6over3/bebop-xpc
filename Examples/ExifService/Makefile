LABEL       := com.bebop.example.exif
INSTALL_DIR := /usr/local/bin
PLIST_DIR   := $(HOME)/Library/LaunchAgents
PLIST       := $(LABEL).plist
BINARY      := ExifServiceExample
PKG_ROOT    := $(shell cd ../.. && pwd)
BIN_PATH    = $(shell swift build --package-path "$(PKG_ROOT)" --product $(BINARY) -c release --show-bin-path)

.PHONY: build install uninstall status

build:
	swift build --package-path "$(PKG_ROOT)" --product $(BINARY) -c release

install: build
	-launchctl bootout gui/$$(id -u) "$(PLIST_DIR)/$(PLIST)" 2>/dev/null
	sudo cp "$(BIN_PATH)/$(BINARY)" "$(INSTALL_DIR)/$(BINARY)"
	cp $(PLIST) "$(PLIST_DIR)/$(PLIST)"
	launchctl bootstrap gui/$$(id -u) "$(PLIST_DIR)/$(PLIST)"
	@echo "Installed. Run: $(BINARY) <image-path>"

uninstall:
	-launchctl bootout gui/$$(id -u) "$(PLIST_DIR)/$(PLIST)" 2>/dev/null
	sudo rm -f "$(INSTALL_DIR)/$(BINARY)"
	rm -f "$(PLIST_DIR)/$(PLIST)"
	@echo "Uninstalled."

status:
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null || echo "Service not loaded."
