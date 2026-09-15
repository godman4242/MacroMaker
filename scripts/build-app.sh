#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) "Macro Maker.app" with SwiftPM — no Xcode needed.
#
#   ./scripts/build-app.sh                      # ad-hoc signed, for this Mac
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
#                                               # signed for distribution (then notarize — see README)
#
# Output: build/Macro Maker.app and build/MacroMaker.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Macro Maker"
EXECUTABLE="MacroMaker"
BUILD_DIR="build"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Support/Info.plist)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Info.plist)"

# Guard against the Xcode project and the plist drifting apart (two copies of the same values).
grep -q "PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID\$" project.yml \
  || { echo "error: bundle id $BUNDLE_ID in Info.plist doesn't match project.yml" >&2; exit 1; }
grep -q "macOS: \"$MIN_MACOS\"" project.yml \
  || { echo "error: LSMinimumSystemVersion $MIN_MACOS doesn't match project.yml" >&2; exit 1; }

binaries=()
for arch in arm64 x86_64; do
  echo "▸ Building ${arch}…"
  swift build -c release --triple "$arch-apple-macosx$MIN_MACOS"
  binaries+=("$(swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --show-bin-path)/$EXECUTABLE")
done

APP="$BUILD_DIR/$APP_NAME.app"
echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing ($SIGN_IDENTITY)…"
sign_args=(--force --options runtime --entitlements Support/MacroMaker.entitlements --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && sign_args+=(--timestamp)
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

rm -f "$BUILD_DIR/$EXECUTABLE.zip"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$EXECUTABLE.zip"

echo "✔ $APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
echo "✔ $BUILD_DIR/$EXECUTABLE.zip"
