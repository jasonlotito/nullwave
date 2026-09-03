.PHONY: build test app run clean

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

clean:
	swift package clean
	rm -rf "dist/Nullwave.app"
