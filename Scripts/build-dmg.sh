#!/bin/bash

# Build, sign, notarize, and package CircadianLights as a DMG
# Uses credentials from The Photo Map LLC developer account

set -e

# Configuration
APP_NAME="CircadianLights"
BUNDLE_ID="com.circadianlights.app"
TEAM_ID="28FC5D45XH"
SIGNING_IDENTITY="Developer ID Application: The Photo Map LLC (28FC5D45XH)"
NOTARIZATION_PROFILE="Interviewer-Notarization"  # Reuse existing profile from interviewer project

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_DIR="$PROJECT_DIR/dist"
DMG_NAME="$APP_NAME.dmg"

echo "=== Building $APP_NAME ==="

# Clean previous builds
rm -rf "$APP_BUNDLE"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# Build release binary
echo "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/Sources/Info.plist" "$APP_BUNDLE/Contents/"

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy entitlements for signing
ENTITLEMENTS="$PROJECT_DIR/$APP_NAME.entitlements"

echo "=== Signing $APP_NAME ==="

# Sign the app bundle
codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_BUNDLE"

# Verify signature
echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "=== Notarizing $APP_NAME ==="

# Create a zip for notarization
NOTARIZE_ZIP="$DMG_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

# Submit for notarization
echo "Submitting to Apple for notarization..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARIZATION_PROFILE" \
    --wait

# Staple the notarization ticket
echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

# Clean up notarization zip
rm "$NOTARIZE_ZIP"

echo "=== Creating DMG ==="

# Create DMG staging area
DMG_STAGING="$DMG_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"

# Copy app to staging
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Create symlink to Applications
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_DIR/$DMG_NAME"

# Sign the DMG
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_DIR/$DMG_NAME"

# Clean up staging
rm -rf "$DMG_STAGING"

echo "=== Notarizing DMG ==="

# Submit DMG for notarization
echo "Submitting DMG to Apple for notarization..."
xcrun notarytool submit "$DMG_DIR/$DMG_NAME" \
    --keychain-profile "$NOTARIZATION_PROFILE" \
    --wait

# Staple the notarization ticket to DMG
echo "Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG_DIR/$DMG_NAME"

echo "=== Done ==="
echo "DMG created at: $DMG_DIR/$DMG_NAME"
echo ""
echo "To verify notarization:"
echo "  spctl -a -t open --context context:primary-signature -v '$DMG_DIR/$DMG_NAME'"
