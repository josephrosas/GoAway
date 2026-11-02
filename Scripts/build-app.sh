#!/bin/zsh
# Usage: Scripts/build-app.sh [debug|release] [--install] [--reset-tcc] [--adhoc] [--release-dist]
#
#   --install       copy the finished bundle to /Applications/GoAway.app
#   --reset-tcc     forget GoAway's Full Disk Access entry so it can be re-granted cleanly
#   --adhoc         skip the stable signing identity (the FDA grant will break on every rebuild)
#   --release-dist  distribution build: release, universal (arm64 + x86_64), hardened
#                   runtime, secure timestamp, version from the latest git tag (vX.Y.Z).
#                   Sign with a Developer ID via GOAWAY_SIGN_IDENTITY. See Scripts/release.sh.
#
# Updates (Sparkle) are switched on only when the bundle has an EdDSA public key:
#   GOAWAY_SPARKLE_PUBLIC_KEY  printed by .build/artifacts/sparkle/Sparkle/bin/generate_keys
#   GOAWAY_FEED_URL            overrides SUFeedURL in Resources/Info.plist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
INSTALL=0
RESET_TCC=0
ADHOC=0
DIST=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    --reset-tcc) RESET_TCC=1 ;;
    --adhoc) ADHOC=1 ;;
    --release-dist) DIST=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

BUNDLE_ID="com.unga.GoAway"
IDENTITY="${GOAWAY_SIGN_IDENTITY:-GoAway Development}"

ARCH_ARGS=()
if [[ $DIST -eq 1 ]]; then
  CONFIG="release"
  ARCH_ARGS=(--arch arm64 --arch x86_64)
  if [[ $ADHOC -eq 1 ]]; then
    echo "--release-dist cannot be ad-hoc signed." >&2
    exit 2
  fi
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "WARNING: $IDENTITY is not a Developer ID; this build cannot be notarized."
  fi
fi

# The Command Line Tools' PackageDescription fails to link the manifest; the
# wrapper patches that. Xcode's toolchain needs no help.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  if [[ $DIST -eq 1 ]]; then
    echo "--release-dist needs Xcode (universal builds); run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 2
  fi
  mkdir -p "$ROOT/.build-toolchain"
  clang -c -arch arm64 -mmacosx-version-min=14.0 \
    "$ROOT/Scripts/package-description-shim.s" \
    -o "$ROOT/.build-toolchain/package-description-shim.o"
  export SWIFT_EXEC="$ROOT/Scripts/swiftc-manifest-fix"
fi

if [[ ! -f "$ROOT/Resources/AppIcon.icns" || ! -f "$ROOT/Sources/GoAway/Assets/AppLogo.png" ]]; then
  echo "Generating app icon…"
  swift "$ROOT/Scripts/make-icon.swift"
fi

echo "Building GoAway ($CONFIG${ARCH_ARGS:+, universal})…"
swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --product GoAway
swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --product GoAwayProbe

BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/GoAway"
APP="$ROOT/dist/GoAway.app"

if [[ $DIST -eq 1 ]]; then
  for binary in "$BIN" "$BIN_DIR/GoAwayProbe"; do
    archs="$(lipo -archs "$binary")"
    if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
      echo "Not universal: $binary ($archs)" >&2
      exit 1
    fi
  done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/GoAway"
cp "$BIN_DIR/GoAwayProbe" "$APP/Contents/MacOS/GoAwayProbe"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/GoAway" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/GoAway"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$ROOT/Sources/GoAway/Assets/AppLogo.png" "$APP/Contents/Resources/AppLogo.png"

chmod +x "$APP/Contents/MacOS/GoAway"

# Version: the latest vX.Y.Z tag names the release; the commit count numbers
# the build, so every release build sorts after the one before it.
PLIST="$APP/Contents/Info.plist"
if [[ $DIST -eq 1 ]]; then
  TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$TAG" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$PLIST"
  else
    echo "WARNING: no vX.Y.Z tag; keeping the version in Resources/Info.plist."
  fi
  BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
  if (( BUILD > CURRENT )); then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
  fi
fi
echo "Version $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST") ($(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST"))"

if [[ -n "${GOAWAY_FEED_URL:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $GOAWAY_FEED_URL" "$PLIST"
fi
if [[ -n "${GOAWAY_SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $GOAWAY_SPARKLE_PUBLIC_KEY" "$PLIST"
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1; then
  echo "Updates are off in this build (no GOAWAY_SPARKLE_PUBLIC_KEY)."
fi

# Full Disk Access is keyed to the signature's designated requirement. A stable
# identity keeps that requirement constant across rebuilds; ad-hoc does not.
SIGN_ARGS=()
if [[ $ADHOC -eq 0 ]]; then
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    if [[ $DIST -eq 1 ]]; then
      echo "Signing identity not found: $IDENTITY" >&2
      exit 1
    fi
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
ENTITLEMENTS="$ROOT/Resources/GoAway.entitlements"
if [[ $DIST -eq 1 ]]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  SIGN_ARGS+=(--options runtime --timestamp)
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    # Without a Team ID the runtime's library check rejects the embedded Sparkle.
    # Developer ID builds share one Team ID and keep the check.
    ENTITLEMENTS="$(mktemp -t goaway-entitlements)"
    cp "$ROOT/Resources/GoAway.entitlements" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
  fi
fi

# Nested code first, innermost out; the outer signature seals it. Sparkle is
# re-signed so its team matches the app's (the hardened runtime checks that).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$SPARKLE"/XPCServices/*.xpc(N); do
  codesign --force "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$xpc"
done
codesign --force "${SIGN_ARGS[@]}" "$SPARKLE/Autoupdate"
codesign --force "${SIGN_ARGS[@]}" "$SPARKLE/Updater.app"
codesign --force "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID.probe" \
  "$APP/Contents/MacOS/GoAwayProbe"
codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP"

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
