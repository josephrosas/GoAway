#!/bin/zsh
# Usage: Scripts/appcast.sh <updates-folder>
#
# Adds the DMG from Scripts/release.sh to <updates-folder> (a local mirror of
# the folder served next to SUFeedURL) and regenerates appcast.xml there.
# Sparkle's generate_appcast signs each update with the EdDSA private key in
# your login keychain. Upload the folder's contents afterwards.
#
# One-time setup:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys
# creates that private key and prints the public key. Pass the public key to
# every build as GOAWAY_SPARKLE_PUBLIC_KEY.
#
#   GOAWAY_DOWNLOAD_PREFIX  URL the DMGs are served from (defaults to SUFeedURL's folder)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FOLDER="${1:?Usage: Scripts/appcast.sh <updates-folder>}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$TOOLS/generate_appcast" ]]; then
  swift package resolve
fi

PLIST="$ROOT/dist/GoAway.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
DMG="$ROOT/dist/GoAway-$VERSION.dmg"
if [[ ! -f "$DMG" ]]; then
  echo "No $DMG; run Scripts/release.sh first." >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1; then
  echo "This build has no SUPublicEDKey, so it could never verify an update." >&2
  echo "Rebuild with GOAWAY_SPARKLE_PUBLIC_KEY set." >&2
  exit 1
fi
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "WARNING: $DMG is not notarized; Gatekeeper will block the update."
fi

FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")"
PREFIX="${GOAWAY_DOWNLOAD_PREFIX:-${FEED%/*}/}"

mkdir -p "$FOLDER"
cp "$DMG" "$FOLDER/"
"$TOOLS/generate_appcast" --download-url-prefix "$PREFIX" "$FOLDER"

echo ""
echo "Updated $FOLDER/appcast.xml"
echo "Upload the contents of $FOLDER so appcast.xml is served at $FEED"
