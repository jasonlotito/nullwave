#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
mkdir -p .build/ModuleCache .build/swiftpm-cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift build --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" -c release

APP_DIR="dist/Nullwave.app"
CONTENTS="$APP_DIR/Contents"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp .build/release/Nullwave "$CONTENTS/MacOS/Nullwave"
cp .build/release/nullwavectl "$CONTENTS/MacOS/nullwavectl"
ditto .build/release/Sparkle.framework "$CONTENTS/Frameworks/Sparkle.framework"
cp .build/release/nullwavectl dist/nullwavectl
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.png "$CONTENTS/Resources/AppIcon.png"
cp Resources/MenuBarIcon.png "$CONTENTS/Resources/MenuBarIcon.png"
xcrun actool Resources/Assets.xcassets \
    --compile "$CONTENTS/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist .build/AppIcon-partial.plist

sign_item() {
    if [ "$SIGNING_IDENTITY" = "-" ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$1"
    fi
}

if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$CONTENTS/Frameworks/Sparkle.framework"
else
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$CONTENTS/Frameworks/Sparkle.framework"
fi
sign_item "$CONTENTS/MacOS/nullwavectl"
sign_item "$APP_DIR"
echo "Built: $PWD/$APP_DIR"
