#!/bin/bash
# Builds Riffle.app (release, one binary for Apple silicon and Intel), signs it, and optionally installs it.
#
#   ./Scripts/build.sh             → build/Riffle.app
#   ./Scripts/build.sh --install   → also replaces /Applications/Riffle.app and starts it
#   RIFFLE_CACHE=<folder> ./Scripts/build.sh   → keeps the build products in <folder> (default ~/Library/Caches/Riffle)
#
# Signing uses your "Developer ID Application" certificate when there is one (what notarization takes, so what the
# website hands out), else your "Apple Development" one. That matters: macOS ties the Accessibility and Screen
# Recording permissions to the signature, so with a stable certificate they survive rebuilds. Without one the app is
# signed ad hoc and the permissions have to be granted again after each build. RIFFLE_SIGN_IDENTITY picks another.
# The hardened runtime doesn't change that: the requirement the permissions are tied to names the certificate and
# the bundle identifier, not the signing options.
#
# Updates come through Sparkle (Sources/Riffle/App/Updates.swift): the app reads FEED_URL once a day and installs only
# what's signed with the private half of UPDATE_KEY, kept in the login keychain (account "riffle"). Scripts/make-dmg.sh
# signs each release with it and writes the feed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build products live outside the project, behind symlinks: in a folder synced by iCloud Drive (Desktop & Documents)
# they would be uploaded, and codesign refuses bundles carrying the tags iCloud adds to files.
CACHE="${RIFFLE_CACHE:-$HOME/Library/Caches/Riffle}"
for dir in .build build; do
  mkdir -p "$CACHE/$dir"
  if [ "$(readlink "$dir" 2>/dev/null || true)" != "$CACHE/$dir" ]; then
    rm -rf "$dir"
    ln -s "$CACHE/$dir" "$dir"
  fi
done

APP_NAME="Riffle"
BUNDLE_ID="com.dorukyuksel.riffle"
VERSION="1.0.2"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
FEED_URL="https://appriffle.com/updates/appcast.xml"
UPDATE_KEY="S8yWdHdFl/0KpL6Z9VF5iD2ukQPo/l3L/8xwt0cIHOg="
OUT="build/$APP_NAME.app"
# macOS 26 still runs on some Intel Macs.
ARCHS=(arm64 x86_64)
ARCH_FLAGS=()
for arch in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done

echo "▸ Compiling (release, ${ARCHS[*]})"
# Only the app: the package also has a test helper that crashes on purpose.
swift build -c release "${ARCH_FLAGS[@]}" --product "$APP_NAME"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Drawing the app icon"
  mkdir -p Resources
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift Scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "▸ Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"
# Without its debug symbols: they only name the files it was built from, and those paths name the machine.
strip -S "$OUT/Contents/MacOS/$APP_NAME"
BUILT_ARCHS="$(lipo -archs "$OUT/Contents/MacOS/$APP_NAME")"
for arch in "${ARCHS[@]}"; do
  if [[ " $BUILT_ARCHS " != *" $arch "* ]]; then
    echo "✗ $OUT is built for $BUILT_ARCHS, without $arch" >&2
    exit 1
  fi
done
# Sparkle, which the binary finds through its @executable_path/../Frameworks rpath (Package.swift). Riffle isn't
# sandboxed, so the XPC services Sparkle carries for sandboxed apps are left out; what stays is signed again below.
SPARKLE="$OUT/Contents/Frameworks/Sparkle.framework"
mkdir -p "$OUT/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
LOAD_COMMANDS="$(otool -l "$OUT/Contents/MacOS/$APP_NAME")"
if ! grep -q "path @executable_path/../Frameworks " <<< "$LOAD_COMMANDS"; then
  echo "✗ $OUT can't find Sparkle.framework: its binary has no @executable_path/../Frameworks rpath" >&2
  exit 1
fi
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>tr</string><string>en</string><string>ar</string><string>de</string><string>es</string><string>fr</string><string>he</string><string>id</string><string>it</string><string>ja</string><string>ko</string><string>nl</string><string>pl</string><string>pt-BR</string><string>ru</string><string>sv</string><string>th</string><string>vi</string><string>zh-Hans</string><string>zh-HK</string><string>zh-Hant</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Riffle. Free software under the GNU GPL, version 3.</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$UPDATE_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
</dict>
</plist>
PLIST

echo "▸ Signing"
IDENTITY="${RIFFLE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  IDENTITY="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$IDENTITIES")"
  [ -n "$IDENTITY" ] || IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$IDENTITIES")"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "  No signing certificate found: signing ad hoc (permissions reset on every build)."
else
  echo "  $IDENTITY"
fi
# Notarization wants a secure timestamp on a Developer ID signature; any other signature goes without (offline, faster).
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP="--timestamp"
# The hardened runtime, with no entitlements: Riffle generates no code at run time and loads none but Apple's and the
# Sparkle.framework it carries (its dlsym lookups reach system frameworks, and Sparkle is signed with Riffle's own
# identity, both of which library validation allows). Accessibility, the event tap, screen capture, the global
# shortcuts and the login item are the user's to grant in System Settings, not entitlements, and its only Apple event,
# the "quit" NSRunningApplication.terminate() sends, needs no Automation consent.
# Signed inside out, the way Sparkle's documentation does it, never --deep: Sparkle's helpers first (keeping their
# identifiers), then the framework, then the app.
for helper in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
  codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" --preserve-metadata=identifier,entitlements "$helper"
done
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$SPARKLE"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime "$TIMESTAMP" "$OUT"
codesign --verify --strict --deep "$OUT"
# Each architecture has a signature of its own.
for arch in "${ARCHS[@]}"; do
  SIGNATURE="$(codesign --display --verbose --arch "$arch" "$OUT" 2>&1)"
  if ! grep -q '^CodeDirectory .*flags=.*runtime' <<< "$SIGNATURE"; then
    echo "✗ $OUT ($arch) isn't signed with the hardened runtime" >&2
    exit 1
  fi
done

if [ "${1:-}" = "--install" ]; then
  echo "▸ Installing to /Applications"
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.8 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$OUT" "/Applications/"
  open "/Applications/$APP_NAME.app"
fi

echo "✓ $OUT"
