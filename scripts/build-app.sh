#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
mkdir -p .build/ModuleCache .build/swiftpm-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift build --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" -c release

APP_DIR="dist/Nullwave.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/Nullwave "$CONTENTS/MacOS/Nullwave"
cp .build/release/nullwavectl "$CONTENTS/MacOS/nullwavectl"
cp .build/release/nullwavectl dist/nullwavectl
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.png "$CONTENTS/Resources/AppIcon.png"
cp Resources/MenuBarIcon.png "$CONTENTS/Resources/MenuBarIcon.png"
xcrun actool Resources/Assets.xcassets \
    --compile "$CONTENTS/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist .build/AppIcon-partial.plist

codesign --force --sign - "$CONTENTS/MacOS/nullwavectl"
codesign --force --sign - "$APP_DIR"
echo "Built: $PWD/$APP_DIR"
