PROJECT := ShlCommander.xcodeproj
SCHEME  := ShlCommander
CONFIG  ?= Debug
DERIVED := build
DEST    := platform=macOS,arch=arm64
APP     := $(DERIVED)/Build/Products/$(CONFIG)/shl-commander.app

# -quiet keeps warnings and errors, drops the per-file command echo.
XCB := xcodebuild -quiet -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
       -destination '$(DEST)' -derivedDataPath $(DERIVED)

.PHONY: gen build test run clean release

gen:
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

build: $(PROJECT)
	$(XCB) build

test: $(PROJECT)
	$(XCB) test

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) $(PROJECT)

release:
	$(MAKE) CONFIG=Release build
	rm -rf /Applications/shl-commander.app
	cp -R build/Build/Products/Release/shl-commander.app /Applications/
	codesign --force --deep --options runtime --sign - /Applications/shl-commander.app
	@echo "Installed to /Applications/shl-commander.app"
