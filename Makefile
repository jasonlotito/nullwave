.PHONY: build test app signed-app release install-cli run xcode-build xcode-test clean

DEVELOPER_IDENTITY ?= Developer ID Application: Jason Lotito (47UF97CY9G)
NOTARY_PROFILE ?= nullwave-notary
NULLWAVE_APP ?= /Applications/Nullwave.app
CLI_INSTALL_DIR ?= /usr/local/bin

build: app

test:
	mkdir -p .build/ModuleCache .build/swiftpm-cache
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/ModuleCache" swift test --disable-sandbox --cache-path "$(CURDIR)/.build/swiftpm-cache"

app:
	./scripts/build-app.sh

signed-app:
	SIGNING_IDENTITY="$(DEVELOPER_IDENTITY)" ./scripts/build-app.sh

release:
	SIGNING_IDENTITY="$(DEVELOPER_IDENTITY)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ./scripts/release.sh "$(VERSION)"

install-cli:
	test -x "$(NULLWAVE_APP)/Contents/MacOS/nullwavectl"
	sudo mkdir -p "$(CLI_INSTALL_DIR)"
	sudo ln -sfn "$(NULLWAVE_APP)/Contents/MacOS/nullwavectl" "$(CLI_INSTALL_DIR)/nullwavectl"
	@echo "Installed: $(CLI_INSTALL_DIR)/nullwavectl"

run: app
	open "dist/Nullwave.app"

xcode-build:
	xcodebuild -project Nullwave.xcodeproj -scheme Nullwave -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

xcode-test:
	xcodebuild -project Nullwave.xcodeproj -scheme Nullwave -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test

clean:
	swift package clean
	rm -rf "dist/Nullwave.app"
