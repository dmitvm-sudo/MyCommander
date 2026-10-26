#!/usr/bin/env bash
# T-37 release assembly (docs/SDD/11: Tools/release; 03 N-9): builds the
# distributable MyCommander.app from the SPM Release build.
#
# Inputs (env, all optional):
#   SIGN_IDENTITY       codesign identity («Developer ID Application: …»);
#                       unset → ad-hoc signature («-») for local DMG smoke.
#   SPARKLE_FEED_URL    SUFeedURL for the appcast (default: repo raw appcast).
#   SPARKLE_EDDSA_KEY   Sparkle EdDSA public key (sign_update -p „generate/set“);
#                       unset → the plist key stays empty (updater dormant).
#   APP_VERSION / APP_BUILD  marketing/build versions (default: from git).
#
# Outcome: build/release/MyCommander.app (+ the lproj catalogs at
# Contents/Resources — F-22 lesson T-35: the app bundle resolves the master
# catalogs through Bundle.main, they must live in Contents/Resources/).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BIN_SWIFTC="${SW:-swift}"
CONFIG="${CONFIG:-release}"

echo "==> swift build -c $CONFIG"
# Plain build (no --build-tests: plain release build doesn't turn on
# -enable-testing — test targets would fail on @testable; the tests ride
# `swift test -c release`, see 08 §8.5 gate).
"$BIN_SWIFTC" build -c "$CONFIG" >/dev/null
BIN_DIR="$("$BIN_SWIFTC" build -c "$CONFIG" --show-bin-path)"

VERSION="${APP_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0.0)}"
VERSION="${VERSION#v}"
BUILD="${APP_BUILD:-$(git rev-list --count HEAD)}"
BUNDLE_ID="${APP_BUNDLE_ID:-org.mycommander.MyCommander}"
FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/dmitvm-sudo/MyCommander/main/appcast.xml}"
EDDSA_KEY="${SPARKLE_EDDSA_KEY:-}"

APP=build/release/MyCommander.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# 1) the executable.
cp "$BIN_DIR/MyCommander" "$APP/Contents/MacOS/"

# 2) resources: the SPM-generated resource bundle holds lproj catalogs,
#    keymap/theme jsons — merge its contents into Contents/Resources.
SPM_BUNDLE="$BIN_DIR/MyCommander_MyCommander.bundle"
if [ -d "$SPM_BUNDLE" ]; then
  cp -R "$SPM_BUNDLE/." "$APP/Contents/Resources/"
fi

# 3) Info.plist (template substitution).
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@BUILD@|$BUILD|g" \
    -e "s|@SPARKLE_FEED_URL@|$FEED_URL|g" \
    -e "s|@SPARKLE_EDDSA_KEY@|$EDDSA_KEY|g" \
    Tools/release/Info.plist.in > "$APP/Contents/Info.plist"

# 4) Sparkle framework (F-9): the binary artifact lives under
#    .build/artifacts/sparkle/Sparkle/Sparkle.xcframework — copy the macOS
#    slice into Contents/Frameworks; SPM checkouts may instead expose
#    $BIN_DIR/Sparkle.framework (future product layout drift protection).
SPARKLE_FRAMEWORK=""
for candidate in "$BIN_DIR/Sparkle.framework" \
                 "$(find "$REPO_ROOT/.build/artifacts" -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 6 2>/dev/null | head -1)"; do
  if [ -d "$candidate" ]; then
    SPARKLE_FRAMEWORK="$candidate"
    break
  fi
done
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
  # The executable's SPM rpaths point into .build — add the bundle-relative
  # one for the framework lookup (install name is @rpath/Sparkle.framework)
  # and drop the dev-toolchain entry it shipped with (dead on other machines).
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MyCommander"
  DEV_RPATH=$(otool -l "$APP/Contents/MacOS/MyCommander" | sed -n '/LC_RPATH/,+2p' | grep -E "Toolchain|/ swift-|swift-[0-9]" | sed -E 's/.*path ([^ ]+)( \(offset.*\))?/\1/' | head -1 || true)
  if [ -n "$DEV_RPATH" ]; then
    install_name_tool -delete_rpath "$DEV_RPATH" "$APP/Contents/MacOS/MyCommander" 2>/dev/null || true
  fi
else
  echo "build-app: WARNING — Sparkle.framework not found (updater will be inert in this build)" >&2
fi

# 5) signatures: deep ad-hoc by default; real identity via SIGN_IDENTITY
#    (Developer ID) — notarization rides Tools/release/notarize.sh.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp --options runtime "$APP"
  echo "==> codesign: $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "==> codesign: ad-hoc (no SIGN_IDENTITY — local smoke only)"
fi

echo "build-app: OK → $APP (version $VERSION build $BUILD)"
