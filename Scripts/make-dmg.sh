#!/bin/bash
# Packs Riffle.app into the disk image the website offers. Opened, it shows one small window, the way Mac apps are
# installed: Riffle and a link to Applications side by side on the icon's dusk, an arrow from one to the other, and the
# volume wears Riffle's icon. Dragging Riffle onto Applications installs it.
#
#   ./Scripts/make-dmg.sh              → builds the app (Scripts/build.sh), then website/download/Riffle.dmg
#   ./Scripts/make-dmg.sh --no-build   → packs the build/Riffle.app that's already there
#
# The window is laid out by Scripts/dmg-layout.py, which writes Finder's .DS_Store directly: no Finder scripting, nothing
# on screen. Its picture is Resources/dmg/background.png and background@2x.png, drawn by Scripts/dmg-background.sh.
# The image is checked after it's made: mounted, its app's architectures, signature and version read back, the window's
# file and picture in place, and the picture's alias resolved by macOS itself.
#
# Signed with a Developer ID (Scripts/build.sh picks it when there is one), the app and then the image go to Apple's
# notary, and the tickets are stapled to both, so Gatekeeper opens them without a word, offline too; the check then
# asks Gatekeeper itself. That needs the notary's credentials in the keychain, stored once (it asks for an app-specific
# password, made at account.apple.com):
#   xcrun notarytool store-credentials riffle-notary --apple-id <Apple ID> --team-id <team ID>
# RIFFLE_NOTARY_PROFILE names another profile. With any other signature the image is made as before, not notarized.
#
# A notarized image is also the update installed copies get: it goes to website/updates/ as Riffle-<version>-<build>.dmg,
# and website/updates/appcast.xml, the feed they read once a day, is written again to list it, signed with Riffle's
# update key (the login keychain's "Private key for signing Sparkle updates", account "riffle"). Release notes, when
# there are some, are ReleaseNotes/<version>.md. Never edit appcast.xml by hand: it's signed, so run this again instead.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = "--no-build" ] || ./Scripts/build.sh
APP="build/Riffle.app"
OUT="website/download/Riffle.dmg"
VOLUME="Riffle"
BACKGROUND=".background/background.tiff"
[ -d "$APP" ] || { echo "✗ $APP isn't there: run ./Scripts/build.sh first" >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stage/.background" "$MOUNT"

# The path an alias resolves to, or nothing.
resolve() { swift Scripts/check-alias.swift "$1" 2>/dev/null || true; }

# Who signed the app decides whether it goes to the notary.
SIGNER="$(codesign --display --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
NOTARY_PROFILE="${RIFFLE_NOTARY_PROFILE:-riffle-notary}"
NOTARIZE=false
if [[ "$SIGNER" == "Developer ID Application"* ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ $APP is signed with a Developer ID, but the keychain has no notary profile \"$NOTARY_PROFILE\". Store it once:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id <your team ID>" >&2
    exit 1
  fi
  NOTARIZE=true
fi
# Sends a zip or a disk image to the notary and waits; a refusal stops the script, with the notary's log.
notarize() {
  echo "  sending $(basename "$1") to Apple's notary (a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$WORK/notary.json" || true
  local status id
  status="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$WORK/notary.json" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$WORK/notary.json" 2>/dev/null || true)"
    echo "✗ the notary didn't accept $(basename "$1") (status: ${status:-none})" >&2
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true; else cat "$WORK/notary.json" >&2; fi
    exit 1
  fi
}

if $NOTARIZE; then
  echo "▸ Notarizing the app"
  ditto -c -k --keepParent "$APP" "$WORK/Riffle.zip"
  notarize "$WORK/Riffle.zip"
  xcrun stapler staple -q "$APP"
fi

echo "▸ Packing $OUT"
ditto "$APP" "$WORK/stage/Riffle.app"
ln -s /Applications "$WORK/stage/Applications"
# One picture for every screen: 1x and 2x together.
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out "$WORK/stage/$BACKGROUND" >/dev/null
cp Resources/AppIcon.icns "$WORK/stage/.VolumeIcon.icns"
# Writable first, so the window can be laid out, and HFS+: the alias to the picture names it by its file number.
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"
SetFile -a C "$MOUNT"   # the volume wears .VolumeIcon.icns. Nothing is set on the app itself: Finder information on
                        # a signed bundle breaks its signature, and Finder leaves ".app" off by itself.
RIFFLE_ALIAS_OUT="$WORK/alias" python3 Scripts/dmg-layout.py "$MOUNT" "$VOLUME" "$BACKGROUND"
sync
hdiutil detach -quiet "$MOUNT"
mkdir -p "$(dirname "$OUT")"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -ov -o "$OUT"
if $NOTARIZE; then
  echo "▸ Notarizing the disk image"
  codesign --force --sign "$SIGNER" --timestamp "$OUT"
  notarize "$OUT"
  xcrun stapler staple -q "$OUT"
fi

echo "▸ Checking it"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$OUT"
MOUNTED="$MOUNT/Riffle.app"
ARCHS="$(lipo -archs "$MOUNTED/Contents/MacOS/Riffle")"
for arch in arm64 x86_64; do
  [[ " $ARCHS " == *" $arch "* ]] || { echo "✗ the app in the image is built for $ARCHS, without $arch" >&2; exit 1; }
done
codesign --verify --strict --deep "$MOUNTED"
[ -L "$MOUNT/Applications" ] || { echo "✗ the image has no link to Applications" >&2; exit 1; }
for file in .DS_Store "$BACKGROUND" .VolumeIcon.icns; do
  [ -s "$MOUNT/$file" ] || { echo "✗ the image has no $file" >&2; exit 1; }
done
RESOLVED="$(resolve "$WORK/alias")"
[ "$RESOLVED" = "$MOUNT/$BACKGROUND" ] || [ "$RESOLVED" = "$(cd "$MOUNT" && pwd -P)/$BACKGROUND" ] ||
  { echo "✗ the window's picture doesn't resolve (got: ${RESOLVED:-nothing})" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNTED/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$MOUNTED/Contents/Info.plist")"
NOTARIZED=""
if $NOTARIZE; then
  # Gatekeeper's own verdict, on the app as it comes out of the image and on the image itself.
  spctl --assess --type execute "$MOUNTED" 2>/dev/null || { echo "✗ Gatekeeper refuses the app in the image" >&2; exit 1; }
  NOTARIZED=", notarized"
fi
hdiutil detach -quiet "$MOUNT"
if $NOTARIZE; then
  spctl --assess --type open --context context:primary-signature "$OUT" 2>/dev/null || { echo "✗ Gatekeeper refuses the image" >&2; exit 1; }
  xcrun stapler validate -q "$OUT" || { echo "✗ the image carries no notarization ticket" >&2; exit 1; }
fi

if $NOTARIZE; then
  echo "▸ Writing the update feed"
  UPDATES="website/updates"
  ARCHIVE="Riffle-$VERSION-$BUILD"
  SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
  mkdir -p "$UPDATES"
  # Only the newest image is offered; the feed keeps its one entry (--maximum-versions 1) and no deltas.
  find "$UPDATES" -maxdepth 1 \( -name 'Riffle-*.dmg' -o -name 'Riffle-*.md' \) -delete
  cp "$OUT" "$UPDATES/$ARCHIVE.dmg"
  [ -f "ReleaseNotes/$VERSION.md" ] && cp "ReleaseNotes/$VERSION.md" "$UPDATES/$ARCHIVE.md"
  # The private key leaves the keychain only for generate_appcast, into this run's own folder, removed with it.
  (umask 077 && "$SPARKLE_BIN/generate_keys" --account riffle -x "$WORK/update-key" >/dev/null)
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$WORK/update-key" --download-url-prefix "https://appriffle.com/updates/" \
    --link "https://appriffle.com/" --embed-release-notes --maximum-versions 1 --maximum-deltas 0 "$UPDATES"
  rm -f "$WORK/update-key" "$UPDATES/$ARCHIVE.md"
  rm -rf "$UPDATES/old_updates"
  grep -q "sparkle:version>$BUILD<" "$UPDATES/appcast.xml" || { echo "✗ the feed doesn't list build $BUILD" >&2; exit 1; }
  grep -q "sparkle-signatures" "$UPDATES/appcast.xml" || { echo "✗ the feed isn't signed" >&2; exit 1; }
fi

echo "✓ $OUT: Riffle $VERSION ($BUILD), $ARCHS$NOTARIZED, $(du -h "$OUT" | cut -f1 | tr -d ' ')"
