#!/bin/bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release.sh <version>  (e.g. 0.1.0)}"
SCHEME="Tokenio"
PROJECT="Tokenio.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
ZIP_PATH="$BUILD_DIR/$SCHEME-$VERSION.zip"

# Load notarization credentials
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi

# Find signing identity
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [[ -z "$IDENTITY" ]]; then
    echo "Error: No Developer ID Application certificate found"
    exit 1
fi
echo "Signing with: $IDENTITY"

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive
echo "Building release archive..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    -quiet

# Sign
echo "Signing..."
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$SCHEME/Tokenio.entitlements" \
    "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Signature OK"

# Notarize
echo "Notarizing..."
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$SCHEME-notarize.zip"

if [[ -n "${NOTARIZE_KEY_ID:-}" && -n "${NOTARIZE_ISSUER:-}" && -n "${NOTARIZE_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$BUILD_DIR/$SCHEME-notarize.zip" \
        --key-id "$NOTARIZE_KEY_ID" \
        --issuer "$NOTARIZE_ISSUER" \
        --key "$NOTARIZE_KEY_PATH" \
        --wait
    xcrun stapler staple "$APP_PATH"
    echo "Notarization OK"
else
    echo "Warning: Notarization credentials not found in .env — skipping"
    echo "  Set NOTARIZE_KEY_ID, NOTARIZE_ISSUER, NOTARIZE_KEY_PATH"
fi

rm -f "$BUILD_DIR/$SCHEME-notarize.zip"

# Package
echo "Packaging..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Created: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

# GitHub release
echo ""
read -p "Create GitHub release v$VERSION? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git tag "v$VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" \
        --title "Tokenio $VERSION" \
        --generate-notes \
        "$ZIP_PATH"
    echo "Released: https://github.com/elomid/tokenio/releases/tag/v$VERSION"
fi
