#!/bin/bash
# Installs a verified build at the one daily-use path. Quit Replyline first.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="${1:-build/Replyline.app}"
DESTINATION="/Applications/Replyline.app"

codesign --verify --deep --strict "$SOURCE"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
[[ "$IDENTIFIER" == "local.coverai.Replyline" ]] || { echo "Unexpected bundle identifier" >&2; exit 1; }
DESCRIPTION="$(codesign --display --verbose=2 "$SOURCE" 2>&1)"
[[ "$DESCRIPTION" == *"Authority=Apple Development:"* ]] || { echo "Apple Development signature required" >&2; exit 1; }

# Replacements must satisfy the installed version's original identity.
if [ -d "$DESTINATION" ]; then
  REQUIREMENT="$(codesign -d -r- "$DESTINATION" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"
  [[ -n "$REQUIREMENT" ]] || { echo "Cannot read installed code requirement" >&2; exit 1; }
  codesign --verify --deep --strict -R="$REQUIREMENT" "$SOURCE"
fi
if ps -axo comm= | awk -v expected="$DESTINATION/Contents/MacOS/Replyline" '$0 == expected {found=1} END {exit !found}'; then
  echo "Quit the installed Replyline before replacing it." >&2
  exit 1
fi

# Stage on the destination filesystem; retain the old app for recovery.
STAGE="$(mktemp -d /Applications/.replyline-install.XXXXXX)"
mkdir -p ../.tmp/stable-signing
BACKUP="$(mktemp -d ../.tmp/stable-signing/install-backup.XXXXXX)"
ditto "$SOURCE" "$STAGE/Replyline.app"
codesign --verify --deep --strict "$STAGE/Replyline.app"
if [ -d "$DESTINATION" ]; then mv "$DESTINATION" "$BACKUP/Replyline.app"; fi
if ! mv "$STAGE/Replyline.app" "$DESTINATION"; then
  if [ -d "$BACKUP/Replyline.app" ]; then mv "$BACKUP/Replyline.app" "$DESTINATION"; fi
  echo "Install failed; previous app restored." >&2
  exit 1
fi
rmdir "$STAGE"
codesign --verify --deep --strict "$DESTINATION"
echo "Installed /Applications/Replyline.app"
