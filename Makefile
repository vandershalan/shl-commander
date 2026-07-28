PROJECT := ShlCommander.xcodeproj
SCHEME  := ShlCommander
CONFIG  ?= Debug
DERIVED := build
DEST    := platform=macOS,arch=arm64
APP     := $(DERIVED)/Build/Products/$(CONFIG)/shl-commander.app
RESULTS := $(DERIVED)/TestResults.xcresult

# -quiet keeps warnings and errors, drops the per-file command echo.
XCB := xcodebuild -quiet -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
       -destination '$(DEST)' -derivedDataPath $(DERIVED)

.PHONY: gen build test run clean release icon

gen:
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

build: $(PROJECT)
	$(XCB) build

# -quiet also swallows the test results, so the counts come back out of the result bundle.
test: $(PROJECT)
	rm -rf $(RESULTS)
	$(XCB) -resultBundlePath $(RESULTS) test
	@xcrun xcresulttool get test-results summary --path $(RESULTS) --compact \
	  | python3 -c 'import json,sys; d=json.load(sys.stdin); \
	    print("%s: %d passed, %d failed, %d skipped" % (d["result"], d["passedTests"], d["failedTests"], d["skippedTests"])); \
	    sys.exit(1 if d["failedTests"] or not d["passedTests"] else 0)'

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED) $(PROJECT)

# Ad-hoc signing and the hardened runtime are mutually exclusive, so --options runtime is
# deliberately absent; Xcode disables it for ad-hoc builds anyway.
release:
	$(MAKE) CONFIG=Release build
	rm -rf /Applications/shl-commander.app
	cp -R build/Build/Products/Release/shl-commander.app /Applications/
	codesign --force --deep --sign - \
	  --entitlements Resources/ShlCommander.entitlements \
	  /Applications/shl-commander.app
	@codesign --verify --deep --strict /Applications/shl-commander.app && echo "signature OK"
	@echo ""
	@echo "Installed to /Applications/shl-commander.app"
	@echo "Grant Full Disk Access to this copy: System Settings > Privacy & Security."

# Redraws Resources/AppIcon.icns. Only needed when the artwork changes.
icon:
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	swiftc -o build/make-icon Tools/make-icon.swift
	./build/make-icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
