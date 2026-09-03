#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nullwave-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-nullwave}"
REPOSITORY="${REPOSITORY:-jasonlotito/nullwave}"
VERSION="${1:-${VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}}"
CURRENT_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
CURRENT_BUILD="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
APP_DIR="dist/Nullwave.app"
ARCHIVE="dist/Nullwave-$VERSION.zip"
TAG="v$VERSION"
APPCAST_TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Version must use x.y.z format (for example: 1.1.0)." >&2
    exit 1
fi

if [ "$(git branch --show-current)" != "main" ]; then
    echo "Releases must be created from main." >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash working-tree changes before releasing." >&2
    exit 1
fi

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1 \
    && [ "${REPLACE_EXISTING_RELEASE:-0}" != "1" ]; then
    echo "Release $TAG already exists. Choose a new version." >&2
    exit 1
fi

if [ "$VERSION" != "$CURRENT_VERSION" ]; then
    case "$CURRENT_BUILD" in
        *[!0-9]*|'') echo "CFBundleVersion must be an integer." >&2; exit 1 ;;
    esac
    plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
    plutil -replace CFBundleVersion -string "$((CURRENT_BUILD + 1))" Resources/Info.plist

    perl -pi -e "s#downloads/Nullwave-[0-9]+(?:\\.[0-9]+)+\\.zip#downloads/Nullwave-$VERSION.zip#g; s#/releases/tag/v[0-9]+(?:\\.[0-9]+)+#/releases/tag/v$VERSION#g; s/Version [0-9]+(?:\\.[0-9]+)+/Version $VERSION/g; s/Download Nullwave [0-9]+(?:\\.[0-9]+)+/Download Nullwave $VERSION/g" docs/index.html
fi

make test

SIGNING_IDENTITY="$SIGNING_IDENTITY" ./scripts/build-app.sh

rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

# The notarization ticket changes the app bundle, so package the final archive
# only after stapling it.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR"
CHECKSUM="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

if [ ! -x "$APPCAST_TOOL" ]; then
    swift package resolve
fi

appcast_source="$(mktemp -d /tmp/nullwave-appcast.XXXXXX)"
trap 'rm -rf "$appcast_source"' EXIT
cp "$ARCHIVE" "$appcast_source/"
"$APPCAST_TOOL" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://nullwaveapp.com/downloads/" \
    --full-release-notes-url "https://github.com/$REPOSITORY/releases/tag/$TAG" \
    --link "https://nullwaveapp.com/" \
    --maximum-versions 1 \
    -o "$PWD/docs/appcast.xml" \
    "$appcast_source"

git add Resources/Info.plist docs/index.html docs/appcast.xml
if ! git diff --cached --quiet; then
    git commit -m "Prepare Nullwave $VERSION release"
    git push origin main
fi

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ARCHIVE#Nullwave $VERSION for macOS (Apple silicon)" \
        --repo "$REPOSITORY" --clobber
    gh workflow run pages.yml --repo "$REPOSITORY"
else
    gh release create "$TAG" "$ARCHIVE#Nullwave $VERSION for macOS (Apple silicon)" \
        --repo "$REPOSITORY" \
        --target main \
        --title "Nullwave $VERSION" \
        --generate-notes
fi

echo "SHA-256: $CHECKSUM"
echo "Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
