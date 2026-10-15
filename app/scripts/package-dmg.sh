#!/bin/bash
# Package an already signed Replyline release without Finder automation.
# Usage: scripts/package-dmg.sh [path/to/Replyline.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Replyline.app}"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$IDENTIFIER" == "local.coverai.Replyline" ]] || {
  echo "Expected a versioned Replyline app." >&2; exit 1;
}
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f .signing-identity ]; then IDENTITY="$(cat .signing-identity)"; fi
[[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo "Configure the approved signing certificate SHA-1 first." >&2; exit 1; }
IDENTITY="$(printf '%s' "$IDENTITY" | tr '[:lower:]' '[:upper:]')"
security find-identity -v -p codesigning | awk -v expected="$IDENTITY" '
  $2 == expected && /"Apple Development:/ { found=1 }
  END { exit !found }
' || { echo "The approved Apple Development certificate is unavailable." >&2; exit 1; }
DMG="build/Replyline-$VERSION.dmg"
[[ ! -e "$DMG" && ! -e "$DMG.sha256" ]] || { echo "$DMG or its checksum already exists; refusing to replace a release." >&2; exit 1; }
mkdir -p ../.tmp/package-dmg build
WORK="$(mktemp -d ../.tmp/package-dmg/release.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
codesign --display --extract-certificates="$WORK/certificate" "$APP"
APP_IDENTITY="$(shasum -a 1 "$WORK/certificate0" | awk '{print toupper($1)}')"
[[ "$APP_IDENTITY" == "$IDENTITY" ]] || { echo "App and DMG must use the same approved certificate." >&2; exit 1; }
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Replyline.app"
cp LICENSE "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<TEXT
Replyline $VERSION

适用于 macOS 14 及以上，包含 Apple silicon 与 Intel 架构。

安装或更新：
1. 保存编辑内容，从 Replyline 菜单正常退出旧版。
2. 将 Replyline.app 拖到 Applications，已有旧版时选择替换。
3. 从「应用程序」启动，日常安装位置为 /Applications/Replyline.app。

更新应用不会清空常用素材，素材目录为 ~/Library/Application Support/Replyline/Library/。
本包使用 Apple Development 证书签名，未做 Apple 公证；首次使用时按系统提示处理安全确认和辅助功能授权。
视频素材需要 0.3.6 或更高版本。消息由用户在微信确认后手动发送。

基于 Tendedero 修改，保留 MIT 许可，详见 LICENSE.txt。
TEXT
codesign --verify --deep --strict "$STAGE/Replyline.app"
hdiutil create -quiet -srcfolder "$STAGE" -volname "Replyline $VERSION" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$WORK/release.dmg"
codesign --timestamp --sign "$IDENTITY" "$WORK/release.dmg"
codesign --verify --strict "$WORK/release.dmg"
mv "$WORK/release.dmg" "$DMG"
(cd build && shasum -a 256 "Replyline-$VERSION.dmg" > "Replyline-$VERSION.dmg.sha256")
echo "Built $DMG and $DMG.sha256 (signed, not notarized)"
