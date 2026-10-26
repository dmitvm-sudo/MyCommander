#!/usr/bin/env bash
# T-37 Sparkle appcast generator (docs/SDD/11 Tools/release; 03 N-9):
# edits/creates ./appcast.xml from the DMG produced by make-dmg.sh.
#
# Usage: Tools/release/update-appcast.sh [DMG_PATH]
# Env:
#   SPARKLE_SIGN_UPDATE    path to Sparkle's `sign_update` (ships in the
#                          Sparkle release ZIP; the SPM artifact carries only
#                          the framework). Without it the item lands UNsigned
#                          (SKIP_SIGNATURE_WARNING=1 silences the warning for
#                          drafts — the release gate 03 N-9 requires EdDSA).
#   ARCHIVE_TARGET         override the enclosure download target.
#
# Beta channel: a version string containing «beta» wears
# sparkle:channel="beta" — stable updaters ignore it (Sparkle 2).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
GH_SLUG="dmitvm-sudo/MyCommander"

DMG="${1:-$(ls -t build/release/MyCommander-*.dmg 2>/dev/null | head -1)}"
[ -n "${DMG:-}" ] && [ -e "$DMG" ] || { echo "update-appcast: FAIL — DMG missing (run make-dmg.sh or pass the path)" >&2; exit 1; }

# Version stem from MyCommander-<version>.dmg (builds carry the build count
# as the last dash part of the DMG name only when APP_BUILD was injected —
# the canonical name stays MyCommander-<version>.dmg).
BASE=$(basename "$DMG"); BASE="${BASE%.dmg}"
VERSION="${BASE#MyCommander-}"

# Version description host: GitHub Releases tag v<version>.
ARCHIVE_TARGET="${ARCHIVE_TARGET:-https://github.com/$GH_SLUG/releases/download/v$VERSION/$(basename "$DMG")}"

# EdDSA signature — two components from sign_update output:
#   sparkle:edSignature="…"  sparkle:length="…"
# SPARKLE_ED_KEY_FILE (optional): file with the private EdDSA key (exported
# via `generate_keys -x`; SHRED after the release session — the keychain
# route stays the default because sign_update blocks on a keychain-consent
# dialog inside headless sessions otherwise, T-37/T-38 first-tag protocol).
SIG_SIG=""; SIG_LEN=""
SIG_TOOL="${SPARKLE_SIGN_UPDATE:-}"
if [ -z "$SIG_TOOL" ]; then
  FOUND=$(find build .build -name "sign_update" -type f -perm -u+x 2>/dev/null | head -1)
  [ -n "$FOUND" ] && SIG_TOOL="$FOUND"
fi
if [ -n "$SIG_TOOL" ] && [ -x "$SIG_TOOL" ]; then
  OUT=$("$SIG_TOOL" ${SPARKLE_ED_KEY_FILE:+--ed-key-file "$SPARKLE_ED_KEY_FILE"} "$DMG" 2>&1 || true)
  SIG_SIG=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$OUT")
  SIG_LEN=$(sed -nE 's/.*sparkle:length="([0-9]+)".*/\1/p' <<<"$OUT")
  if [ -z "$SIG_SIG" ]; then
    # Common one-time cause: no ed25519 key on this machine
    # (generate_keys — Sparkle docs) — the release gate (03 N-9) stops an
    # unsigned appcast; drafts may proceed with the warning.
    echo "update-appcast: WARNING — sign_update failed ($OUT); DMG goes unsigned" >&2
  fi
elif [ "${SKIP_SIGNATURE_WARNING:-0}" != "1" ]; then
  echo "update-appcast: WARNING — SPARKLE_SIGN_UPDATE not set; the DMG lands unsigned (03 N-9 fails on missing EdDSA)" >&2
fi

python3 - "$DMG" "$VERSION" "$ARCHIVE_TARGET" "$SIG_SIG" "$SIG_LEN" "$GH_SLUG" <<'PY'
import os, re, sys

dmg, version, target, sig, sig_len, slug = sys.argv[1:7]
path = "appcast.xml"
size = os.path.getsize(dmg)

# Sparkle convention: BUILD stays meaningful — go the git build count only
# when releases publish it; CPShortVersion = marketing version.
build_env = os.environ.get("APP_BUILD", "")
# CFBundleVersion mirrors buildNumber; when nothing is injected, «1» matches
# the Info.plist template default.
build = build_env or "1"
# Release notes pointer: GitHub Releases page for the tag.
notes = f"https://github.com/{slug}/releases/tag/v{version}"

enclosure = [
    '        <enclosure',
    f'          url="{target}"',
    '          type="application/octet-stream"',
    f'          sparkle:shortVersionString="{version}"',
    f'          sparkle:buildNumber="{os.environ.get("APP_BUILD", "") or version}"',
    f'          size="{size}"',
    '          sparkle:installationType="package"',
]
if sig:
    enclosure.append(f'          sparkle:edSignature="{sig}"')
    if sig_len:
        enclosure.append(f'          sparkle:length="{sig_len}"')
enclosure.append("        />")

is_beta = "beta" in version.lower()
channel = '        <sparkle:channel>beta</sparkle:channel>' if is_beta else ""

item = "\n".join([
    "    <item>",
    f"      <title>Version {version}</title>",
    f"      <pubDate></pubDate>",   # filled below (locale-safe)
    f"      <sparkle:releaseNotesLink>{notes}</sparkle:releaseNotesLink>",
] + ([channel] if is_beta else []) + enclosure + ["" , "    </item>"])

# pubDate with the RFC822 English locale — do it in python (portable).
from email.utils import formatdate
item = item.replace("<pubDate></pubDate>", f"<pubDate>{formatdate(usegmt=False)}</pubDate>")

def drop_matching_item(xml: str, version: str) -> str:
    # One item per version — re-running replaces the old block.
    return re.sub(
        r"\n\s*<item>(?:(?!</item>).)*sparkle:shortVersionString=\""
        + re.escape(version) + r"\"(?:(?!</item>).)*</item>",
        "",
        xml, flags=re.S,
    )

if os.path.exists(path):
    tree = open(path, encoding="utf-8").read()
    tree = drop_matching_item(tree, version)
    tree = tree.replace("  </channel>", item + "  </channel>")
else:
    tree = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>MyCommander updates</title>
    <link>https://github.com/{slug}/releases</link>
    <description>MyCommander appcast (Sparkle 2 · EdDSA · 03 N-9)</description>
    <language>ru</language>
{item}  </channel>
</rss>
"""
open(path, "w", encoding="utf-8").write(tree)
tagged = " (beta channel)" if is_beta else ""
print(f"update-appcast: OK → {path} ({version}{tagged})")
PY
