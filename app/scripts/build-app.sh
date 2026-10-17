#!/bin/bash
# Builds Replyline.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="${REPLYLINE_APP_OUTPUT:-build/Replyline.app}"
VERSION="${REPLYLINE_VERSION:-0.3.10}"
BUILD_NUMBER="${REPLYLINE_BUILD_NUMBER:-27}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number" >&2; exit 1; }

# Pin the local certificate so an update keeps the same signing identity.
# Never fall back to ad hoc: that would invalidate the user's TCC grants.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f .signing-identity ]; then IDENTITY="$(cat .signing-identity)"; fi
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || {
  echo "Set SIGN_IDENTITY or .signing-identity to the SHA-1 of the approved Apple Development certificate." >&2
  exit 1
}
IDENTITY="$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')"
security find-identity -v -p codesigning | awk -v expected="$IDENTITY" '
  $2 == expected && /"Apple Development:/ { found=1 }
  END { exit !found }
' || { echo "The pinned Apple Development identity is unavailable. No ad hoc fallback." >&2; exit 1; }

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! swift build -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then swift build -c "$CONFIG" --triple "$triple" >&2; fi
  cp "$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/Tendedero" "$OUT/Tendedero-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
mkdir -p ../.tmp/build
OUT="$(mktemp -d ../.tmp/build/universal.XXXXXX)"
build_arch arm64
build_arch x86_64
lipo -create "$OUT/Tendedero-arm64" "$OUT/Tendedero-x86_64" -output "$OUT/Tendedero"
BIN="$OUT/Tendedero"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Replyline"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp -R ThirdPartyNotices "$APP/Contents/Resources/ThirdPartyNotices"

# Icon
WORK="$(mktemp -d ../.tmp/build/icon.XXXXXX)"
swift scripts/make-replyline-icon.swift "$WORK/icon.png"
ICONSET="$WORK/Replyline.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Replyline.icns"
rm -rf "$WORK"

# Translations: one folder per language, listed in Info.plist so macOS knows
# which languages the app speaks.
LANGUAGES=""
for dir in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Replyline</string>
  <key>CFBundleDisplayName</key><string>Replyline</string>
  <key>CFBundleIdentifier</key><string>local.coverai.Replyline</string>
  <key>CFBundleExecutable</key><string>Replyline</string>
  <key>CFBundleIconFile</key><string>Replyline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Replyline watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Replyline watches the folder you chose so it can hang new images on the line.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Replyline watches the folder you chose so it can hang new images on the line.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed with the pinned Apple Development certificate"
echo "Built $APP"
