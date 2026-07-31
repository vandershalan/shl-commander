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

# macOS keys a privacy (TCC) grant to the app's "designated requirement". Signed ad-hoc, that
# requirement is a cdhash — a hash of the binary — so every rebuild looks like a different app
# and every folder permission has to be granted again. Signed with a real identity it becomes
# identifier + certificate, which survives rebuilds and keeps the grant.
#
# The first identity the keychain offers is used; override with `make release SIGN_IDENTITY=...`.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
                   | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)

.PHONY: gen build test run clean release icon identity

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

# Reports which identity will be used, and what that means for privacy prompts.
identity:
	@if [ -n '$(SIGN_IDENTITY)' ]; then \
	  echo "Signing identity: $(SIGN_IDENTITY)"; \
	  echo "Privacy grants will survive rebuilds."; \
	else \
	  echo "Signing identity: none found — falling back to ad-hoc."; \
	  echo "Privacy grants will be lost on every rebuild."; \
	  echo "Create one in Keychain Access: Certificate Assistant > Create a Certificate,"; \
	  echo "type 'Code Signing', self-signed. Any name will do."; \
	fi
	@security find-identity -v -p codesigning 2>/dev/null | head -5

# --options runtime is deliberately absent: the hardened runtime buys nothing here and cannot
# be combined with ad-hoc signing, which is the fallback path.
release:
	$(MAKE) CONFIG=Release build
	rm -rf /Applications/shl-commander.app
	cp -R build/Build/Products/Release/shl-commander.app /Applications/
	@if [ -n '$(SIGN_IDENTITY)' ] && codesign --force --deep \
	     --sign '$(SIGN_IDENTITY)' \
	     --entitlements Resources/ShlCommander.entitlements \
	     /Applications/shl-commander.app 2>/dev/null; then \
	  echo "Signed as: $(SIGN_IDENTITY)"; \
	else \
	  echo "Signing ad-hoc (no usable identity: an expired certificate signs nothing)."; \
	  echo "Privacy permissions will need granting again after each rebuild — see 'make identity'."; \
	  codesign --force --deep --sign - \
	    --entitlements Resources/ShlCommander.entitlements \
	    /Applications/shl-commander.app; \
	fi
	@codesign --verify --deep --strict /Applications/shl-commander.app && echo "signature OK"
	@echo ""
	@echo "Installed to /Applications/shl-commander.app"
	@codesign -d -r- /Applications/shl-commander.app 2>&1 | sed -n 's/^# designated => /Identity: /p'
	@codesign -d -r- /Applications/shl-commander.app 2>&1 | grep -q 'cdhash' \
	  && echo "This identity is tied to this exact build, so privacy grants will not persist." \
	  || echo "This identity is stable, so privacy grants persist across rebuilds."

# Redraws Resources/AppIcon.icns. Only needed when the artwork changes.
icon:
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	swiftc -o build/make-icon Tools/make-icon.swift
	./build/make-icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
