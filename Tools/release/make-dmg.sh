#!/usr/bin/env bash
# T-37 release packaging (docs/SDD/11 Tools/release; 03 N-9): UDZO DMG from
# the assembled app (build-app.sh runs first). Layout: app + a soft symlink
# to /Applications (drag-install affordance).
#
# Inputs: tools/release/build-app.sh outcome (build/release/MyCommander.app).
# Outcome: build/release/MyCommander-<version>.dmg
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

[ -d build/release/MyCommander.app ] || { echo "make-dmg: FAIL — run Tools/release/build-app.sh first" >&2; exit 1; }

plist_check() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/release/MyCommander.app/Contents/Info.plist 2>/dev/null; }
VERSION=${APP_VERSION:-$(plist_check)} || VERSION="1.0.0"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R build/release/MyCommander.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="build/release/MyCommander-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MyCommander $VERSION" \
  -srcfolder "$STAGING" \
  -ov -fs HFS+ -format UDZO "$DMG" >/dev/null

echo "make-dmg: OK → $DMG ($VERSION)"
