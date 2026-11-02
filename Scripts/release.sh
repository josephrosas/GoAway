#!/bin/zsh
# Usage: Scripts/release.sh [--skip-notarize]
#
# Builds the distribution app (Scripts/build-app.sh --release-dist), packs it
# into dist/GoAway-<version>.dmg, then notarizes and staples the DMG.
#
#   GOAWAY_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   GOAWAY_NOTARY_PROFILE  keychain profile saved once with:
#                          xcrun notarytool store-credentials GoAway \
#                            --apple-id you@example.com --team-id TEAMID
#                          (defaults to "GoAway")
#   GOAWAY_SPARKLE_PUBLIC_KEY  EdDSA public key for updates (see Scripts/appcast.sh)
#   --skip-notarize        stop after the signed DMG (for checking the build)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

IDENTITY="${GOAWAY_SIGN_IDENTITY:-}"
PROFILE="${GOAWAY_NOTARY_PROFILE:-GoAway}"
if [[ $NOTARIZE -eq 1 && "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo "Set GOAWAY_SIGN_IDENTITY to your Developer ID Application identity." >&2
  echo "Available identities:" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 2
fi
if [[ $NOTARIZE -eq 1 && -z "${GOAWAY_SPARKLE_PUBLIC_KEY:-}" ]]; then
  echo "Set GOAWAY_SPARKLE_PUBLIC_KEY; a release without it can never update itself." >&2
  exit 2
fi
export GOAWAY_SIGN_IDENTITY="${IDENTITY:-GoAway Development}"

"$ROOT/Scripts/build-app.sh" --release-dist

APP="$ROOT/dist/GoAway.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/GoAway-$VERSION.dmg"

echo "Packing $DMG…"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/goaway-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/GoAway.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "GoAway $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
codesign --force --sign "$GOAWAY_SIGN_IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE -eq 0 ]]; then
  echo "Built $DMG (not notarized)"
  exit 0
fi

echo "Submitting to Apple's notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo ""
echo "Released $DMG"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
