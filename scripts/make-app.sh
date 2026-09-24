#!/bin/sh
# Assembles "AuthReach.app" from the SwiftPM release build.
# Usage: scripts/make-app.sh [output-dir]        (default: ./build)
# Env: SIGN_IDENTITY, VERSION, BUILD_NUMBER
#
# SIGN_IDENTITY defaults to the first "Developer ID Application" identity in
# the login keychain, else "-" (ad-hoc). A Developer ID build is the same
# code identity as the release, so it can read the Keychain items the release
# created without a permission prompt; an ad-hoc build is a new identity on
# every rebuild and macOS asks each time.
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/AuthReach.app"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

if [ -z "${DEVELOPER_DIR:-}" ] \
  && ! xcode-select -p | grep -q "Xcode.app" \
  && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/AuthReach" "$APP/Contents/MacOS/AuthReach"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM dependencies with resources emit .bundle dirs next to the binary;
# Bundle.module traps at runtime when they're missing from Resources.
for bundle in .build/release/*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  [ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  [ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

codesign --verify --strict "$APP"
echo "Built: $APP (signed: $SIGN_IDENTITY)"
