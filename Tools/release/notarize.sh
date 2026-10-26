#!/usr/bin/env bash
# T-37 notarization (docs/SDD/11 Tools/release; 03 N-9, M3-exit п.4):
# Apple notary submit — wait — staple. Credentials ride the environment:
#   NOTARY_KEYCHAIN_PROFILE   name of a notarytool keychain profile
#   (createdAt once: xcrun notarytool store-credentials — Apple ID,
#   team/app-specific password, team ID) — preferred;
# OR fresh storing via AC_USERNAME/AC_PASSWORD/AC_TEAM_ID (CI secrets).
# Without credentials the script FAILS LOUD (distribution gate: 09
# M3-exit п.4); CI skips silently when secrets are absent (release.yml).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TARGET="${1:-build/release/MyCommander.dmg}"
[ -e "$TARGET" ] || { echo "notarize: FAIL — $TARGET missing (pass DMG/app path)" >&2; exit 1; }
xcrun --find notarytool >/dev/null 2>&1 || { echo "notarize: FAIL — notarytool requires full Xcode" >&2; exit 1; }

PROFILE=""
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  PROFILE="$NOTARY_KEYCHAIN_PROFILE"
elif [ -n "${AC_USERNAME:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM_ID:-}" ]; then
  # CI path: store the profile once per runner (name pinned for reuse).
  PROFILE="mc-notary-ci"
  xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$AC_USERNAME" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD"
else
  echo "notarize: FAIL — set NOTARY_KEYCHAIN_PROFILE (preferred) or AC_USERNAME/AC_PASSWORD/AC_TEAM_ID" >&2
  exit 1
fi

echo "==> notarytool submit --wait"
xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait

case "$TARGET" in
  *.dmg)
    echo "==> stapler staple + validate"
    xcrun stapler staple "$TARGET"
    xcrun stapler validate "$TARGET"
    ;;
  *)
    # The DMG wrapper carries the staple; pass the DMG (not the .app) here
    # for release distribution, 09 M3-exit п.4 clean-machine check.
    echo "notarize: note — staple the DMG (pass the DMG path); .app staples live inside the disk image"
    ;;
esac

echo "notarize: OK — $TARGET notarized"
