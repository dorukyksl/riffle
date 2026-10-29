#!/bin/bash
# The website's icon files and the parts of its logo, drawn by Scripts/make-icon.swift:
#
#   ./Scripts/site-images.sh                        # website/img/icon-*.png, icon-512.webp and img/logo/*.webp
#   ./Scripts/site-images.sh --reference <folder>   # also the switcher as the app draws it, in every layout, from the
#                                                   # website's sample windows: what the page's own copy is checked against
#
# Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cwebp >/dev/null || { echo "cwebp is needed: brew install webp" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Icon"
swift Scripts/make-icon.swift "$WORK/AppIcon.iconset" --layers "$WORK/layers" >/dev/null
cp "$WORK/AppIcon.iconset/icon_32x32@2x.png" website/img/icon-64.png
cp "$WORK/AppIcon.iconset/icon_128x128@2x.png" website/img/icon-256.png
cwebp -quiet -q 90 -alpha_q 100 "$WORK/AppIcon.iconset/icon_256x256@2x.png" -o website/img/icon-512.webp
mkdir -p website/img/logo
for file in "$WORK"/layers/*.png; do
  cwebp -quiet -q 90 -alpha_q 100 -resize 512 0 "$file" -o "website/img/logo/$(basename "$file" .png).webp"
done

if [ "${1:-}" = "--reference" ] && [ -n "${2:-}" ]; then
  echo "▸ The app's switcher"
  swift build -c release --arch arm64 >/dev/null
  "$(swift build -c release --arch arm64 --show-bin-path)/Riffle" --site-images "$2" --windows website/img/windows >/dev/null
  echo "✓ $2"
fi
echo "✓ website/img"
