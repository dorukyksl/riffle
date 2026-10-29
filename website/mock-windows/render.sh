#!/usr/bin/env bash
# Renders the website's sample windows to PNG at 2x with headless Chrome:
#   website/mock-windows/render.sh <output-dir> [id ...]
# writes <output-dir>/<id>.png for every window in the table below (or only the ids given). Each window is one page
# here plus a variant (<page>.html?v=<variant>). Every shot runs headless in its own throwaway Chrome profile, so no
# window ever appears and nothing of the user's own Chrome is touched.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <output-dir> [id ...]" >&2
  exit 64
fi

# id                page      variant    width height  (CSS px; the PNG is twice that)
windows="
safari-lisbon       browser   lisbon     700   438
safari-sourdough    browser   sourdough  700   438
chrome-kyoto        browser   kyoto      700   528
mail-inbox          mail      inbox      700   467
notes-weekend       notes     weekend    700   538
notes-books         notes     books      700   538
finder-downloads    finder    downloads  700   500
finder-projects     finder    projects   700   500
music-now           music     now        700   452
terminal-build      terminal  build      700   483
xcode-sketchpad     code      sketchpad  700   490
preview-invoice     document  invoice    700   884
"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$chrome" ]; then
  echo "Google Chrome not found at: $chrome (set CHROME=/path/to/chrome)" >&2
  exit 69
fi

mkdir -p "$1"
out="$(cd "$1" && pwd)"
shift

# Only the ids asked for, if any; an unknown id is an error.
for wanted in "$@"; do
  if ! printf '%s\n' "$windows" | awk -v id="$wanted" '$1 == id { found = 1 } END { exit !found }'; then
    echo "unknown window: $wanted" >&2
    exit 65
  fi
done

# file:// URL of this folder, with the characters that would break a URL escaped.
url_dir="$here"
url_dir="${url_dir//%/%25}"
url_dir="${url_dir// /%20}"
url_dir="${url_dir//#/%23}"
url_dir="${url_dir//\?/%3F}"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mock-windows.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

while read -r id page variant width height; do
  [ -n "$id" ] || continue
  if [ $# -gt 0 ]; then
    keep=0
    for wanted in "$@"; do [ "$wanted" = "$id" ] && keep=1; done
    [ $keep -eq 1 ] || continue
  fi
  if [ ! -f "$here/$page.html" ]; then
    echo "missing page for $id: $page.html" >&2
    exit 66
  fi
  png="$out/$id.png"
  profile="$(mktemp -d "$tmp_root/profile.XXXXXX")"
  rm -f "$png"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-extensions --disable-background-networking --disable-sync --use-mock-keychain --mute-audio \
    --user-data-dir="$profile" --force-device-scale-factor=2 --window-size="$width,$height" \
    --screenshot="$png" "file://$url_dir/$page.html?v=$variant" >/dev/null 2>&1 || true
  rm -rf "$profile"
  if [ ! -s "$png" ]; then
    echo "failed to render $id" >&2
    exit 1
  fi
  echo "$png"
done <<< "$windows"
