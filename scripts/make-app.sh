#!/bin/sh
# Assembles "AuthReach.app" from the SwiftPM release build.
# Usage: scripts/make-app.sh [output-dir]        (default: ./build)
# Env: SIGN_IDENTITY, VERSION, BUILD_NUMBER, AUTHREACH_ARCHS
#
# AUTHREACH_ARCHS lists the architectures to build, default this Mac's own
# (one release build, for a fast local loop). Releases set "arm64 x86_64" for
# a universal binary. The name is namespaced because Xcode build phases and
# other tooling export a plain ARCHS that would silently thin the build.
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
ARCHS="${AUTHREACH_ARCHS:-$(uname -m)}"

if [ -z "${DEVELOPER_DIR:-}" ] \
  && ! xcode-select -p | grep -q "Xcode.app" \
  && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# One build per architecture, merged with lipo. A single multi-arch
# `swift build --arch arm64 --arch x86_64` goes through a different build
# system that, on Xcode 16.x, fails to build package dependencies
# ("no such module 'KeyboardShortcuts'"). Each slice is copied out right
# away: depending on the SwiftPM version, both builds can share one
# products folder, which is why the folder is asked for, not hard-coded.
SLICES_DIR="$(mktemp -d)"
trap 'rm -rf "$SLICES_DIR"' EXIT
for arch in $ARCHS; do
  swift build -c release --arch "$arch"
  BIN="$(swift build -c release --arch "$arch" --show-bin-path)"
  cp "$BIN/AuthReach" "$SLICES_DIR/AuthReach-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# shellcheck disable=SC2046 # one path per slice, none contain spaces
lipo -create $(for arch in $ARCHS; do echo "$SLICES_DIR/AuthReach-$arch"; done) \
  -output "$APP/Contents/MacOS/AuthReach"
for arch in $ARCHS; do
  lipo "$APP/Contents/MacOS/AuthReach" -verify_arch "$arch" \
    || { echo "Built binary is missing the $arch slice"; exit 1; }
done
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM dependencies with resources emit .bundle dirs next to the binary;
# Bundle.module traps at runtime when they're missing from Resources.
for bundle in "$BIN"/*.bundle; do
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
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/AuthReach"); signed: $SIGN_IDENTITY)"
