#!/bin/sh
# Assembles "AuthReach.app" from the SwiftPM release build.
# Usage: scripts/make-app.sh [output-dir]        (default: ./build)
# Env: SIGN_IDENTITY (default "-" ad-hoc), VERSION, BUILD_NUMBER
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/AuthReach.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

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
