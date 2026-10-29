#!/bin/bash
# Draws the picture behind Riffle's disk image window from Resources/dmg/background.html, at 1x and 2x:
#
#   ./Scripts/dmg-background.sh   → Resources/dmg/background.png (660 × 440) and background@2x.png (1320 × 880)
#
# Scripts/make-dmg.sh joins the two into one picture for Retina and other screens. Needs Google Chrome, run headless in
# a throwaway profile: nothing appears on screen and nothing of your own Chrome is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$chrome" ] || { echo "Google Chrome not found at: $chrome (set CHROME=/path/to/chrome)" >&2; exit 69; }
page="$(pwd)/Resources/dmg/background.html"
page="${page// /%20}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dmg-background.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for scale in 1 2; do
  out="Resources/dmg/background.png"
  [ "$scale" = 2 ] && out="Resources/dmg/background@2x.png"
  rm -f "$out"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-extensions --disable-background-networking --disable-sync --use-mock-keychain --mute-audio \
    --allow-file-access-from-files --user-data-dir="$tmp/profile-$scale" --force-device-scale-factor="$scale" \
    --window-size=660,440 --screenshot="$(pwd)/$out" "file://$page" >/dev/null 2>&1 || true
  [ -s "$out" ] || { echo "failed to draw $out" >&2; exit 1; }
  echo "✓ $out ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w " × " h }'))"
done
