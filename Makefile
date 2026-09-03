.PHONY: build test app run xcode-build xcode-test clean

build:
	mkdir -p .build/ModuleCache .build/swiftpm-cache
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/ModuleCache" swift build --disable-sandbox --cache-path "$(CURDIR)/.build/swiftpm-cache"

test:
	mkdir -p .build/ModuleCache .build/swiftpm-cache
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/ModuleCache" swift test --disable-sandbox --cache-path "$(CURDIR)/.build/swiftpm-cache"

app:
	./scripts/build-app.sh

run: app
	open "dist/Nullwave.app"

xcode-build:
	xcodebuild -project Nullwave.xcodeproj -scheme Nullwave -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

xcode-test:
	xcodebuild -project Nullwave.xcodeproj -scheme Nullwave -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test

clean:
	swift package clean
	rm -rf "dist/Nullwave.app"
