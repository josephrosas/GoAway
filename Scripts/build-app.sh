#!/bin/zsh
# Usage: Scripts/build-app.sh [debug|release] [--install] [--reset-tcc] [--adhoc]
#
#   --install    copy the finished bundle to /Applications/GoAway.app
#   --reset-tcc  forget GoAway's Full Disk Access entry so it can be re-granted cleanly
#   --adhoc      skip the stable signing identity (the FDA grant will break on every rebuild)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
INSTALL=0
RESET_TCC=0
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    --reset-tcc) RESET_TCC=1 ;;
    --adhoc) ADHOC=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

BUNDLE_ID="com.unga.GoAway"
IDENTITY="${GOAWAY_SIGN_IDENTITY:-GoAway Development}"

mkdir -p "$ROOT/.build-toolchain"
clang -c -arch arm64 -mmacosx-version-min=14.0 \
  "$ROOT/Scripts/package-description-shim.s" \
  -o "$ROOT/.build-toolchain/package-description-shim.o"

export SWIFT_EXEC="$ROOT/Scripts/swiftc-manifest-fix"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" || ! -f "$ROOT/Sources/GoAway/Assets/AppLogo.png" ]]; then
  echo "Generating app icon…"
  swift "$ROOT/Scripts/make-icon.swift"
fi

echo "Building GoAway ($CONFIG)…"
swift build -c "$CONFIG" --product GoAway

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/GoAway"
APP="$ROOT/dist/GoAway.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/GoAway"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$ROOT/Sources/GoAway/Assets/AppLogo.png" "$APP/Contents/Resources/AppLogo.png"

chmod +x "$APP/Contents/MacOS/GoAway"

# Full Disk Access is keyed to the signature's designated requirement. A stable
# identity keeps that requirement constant across rebuilds; ad-hoc does not.
SIGN_ARGS=()
if [[ $ADHOC -eq 0 ]]; then
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    "$ROOT/Scripts/make-signing-cert.sh" || true
  fi
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN_ARGS=(--sign "$IDENTITY")
  fi
fi
if [[ ${#SIGN_ARGS[@]} -eq 0 ]]; then
  echo ""
  echo "WARNING: signing ad-hoc. The Full Disk Access grant will be tied to this exact"
  echo "         binary and will stop working the next time you rebuild."
  echo "         Run Scripts/make-signing-cert.sh to create a stable identity."
  echo ""
  SIGN_ARGS=(--sign -)
fi

codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/GoAway.entitlements" "$APP"

echo ""
echo "Signature requirement (Full Disk Access is bound to this):"
codesign -d -r- "$APP" 2>&1 | grep designated || true
echo ""

if [[ $RESET_TCC -eq 1 ]]; then
  echo "Resetting Full Disk Access entry for $BUNDLE_ID…"
  tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" || true
fi

TARGET="$APP"
if [[ $INSTALL -eq 1 ]]; then
  TARGET="/Applications/GoAway.app"
  echo "Installing to $TARGET…"
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
fi

echo "Built $TARGET"
echo "Open with: open \"$TARGET\""
