#!/bin/bash
# Makes the website's sample windows and app icons:
#
#   ./Scripts/site-assets.sh
#
# - renders the HTML mockups in website/mock-windows at 2x with headless Chrome (see render.sh: a throwaway profile
#   per shot, nothing on screen) and writes each window as WebP, 1400 and 640 pixels wide:
#   website/img/windows/<id>-1400.webp and <id>-640.webp;
# - writes website/img/windows/manifest.json: every window id with the pixel size of both files;
# - exports macOS's own icons of the sample apps, read from their bundles (no app is launched), as
#   website/img/apps/<app>.webp (256 px) and <app>-128.png.
#
# Needs Google Chrome, Swift (Xcode or the Command Line Tools) and cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

CWEBP="$(command -v cwebp || echo /opt/homebrew/bin/cwebp)"
WEBPINFO="$(command -v webpinfo || echo /opt/homebrew/bin/webpinfo)"
[ -x "$CWEBP" ] || { echo "cwebp is needed: brew install webp" >&2; exit 1; }
command -v swift >/dev/null || { echo "swift is needed: xcode-select --install" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/site-assets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# "width height" of an image file.
dims() {
  if [ -x "$WEBPINFO" ]; then
    "$WEBPINFO" "$1" | awk '/^ *Width:/ && !w { w = $2 } /^ *Height:/ && !h { h = $2 } END { print w, h }'
  else
    sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w, h }'
  fi
}

echo "▸ Windows"
website/mock-windows/render.sh "$WORK/windows" > "$WORK/rendered.txt"
ids=()
while IFS= read -r png; do ids+=("$(basename "$png" .png)"); done < "$WORK/rendered.txt"

mkdir -p "$WORK/out"
for id in "${ids[@]}"; do
  png="$WORK/windows/$id.png"
  read -r width _ <<< "$(sips -g pixelWidth -g pixelHeight "$png" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w, h }')"
  for size in 1400 640; do
    resize=()
    [ "$width" -eq "$size" ] || resize=(-resize "$size" 0)
    "$CWEBP" -quiet -q 86 -m 6 -sharp_yuv -metadata none ${resize[@]+"${resize[@]}"} "$png" -o "$WORK/out/$id-$size.webp"
  done
done

{
  echo "{"
  i=0
  for id in "${ids[@]}"; do
    i=$((i + 1))
    read -r w1 h1 <<< "$(dims "$WORK/out/$id-1400.webp")"
    read -r w2 h2 <<< "$(dims "$WORK/out/$id-640.webp")"
    comma=","
    [ "$i" -eq "${#ids[@]}" ] && comma=""
    printf '  "%s": { "1400": { "width": %d, "height": %d }, "640": { "width": %d, "height": %d } }%s\n' \
      "$id" "$w1" "$h1" "$w2" "$h2" "$comma"
  done
  echo "}"
} > "$WORK/out/manifest.json"

WINDOWS=website/img/windows
mkdir -p "$WINDOWS"
rm -f "$WINDOWS"/*.webp "$WINDOWS"/manifest.json
cp "$WORK/out"/*.webp "$WORK/out/manifest.json" "$WINDOWS/"

echo "▸ App icons"
cat > "$WORK/icons.swift" <<'SWIFT'
// Draws each app's icon, as macOS shows it, into 256 and 128 pixel PNGs with transparency.
// Usage: swift icons.swift <output folder> <name>=<app path>=<bundle id> ...
import AppKit
import UniformTypeIdentifiers

// The default icon style, even on a Mac set to dark, clear or tinted icons. This lives in the process's own argument
// domain: nothing is written to anyone's preferences.
UserDefaults.standard.setVolatileDomain(["AppleIconAppearanceTheme": "Regular"], forName: UserDefaults.argumentDomain)

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func png(_ icon: NSImage, size: Int, to url: URL) -> Bool {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

var failed = false
for spec in CommandLine.arguments.dropFirst(2) {
    let parts = spec.components(separatedBy: "=")
    let (name, path, bundleID) = (parts[0], parts[1], parts[2])
    // The usual place first, then wherever Launch Services knows the app to be.
    var app: URL? = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    if app == nil { app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    guard let app else {
        print("missing \(name)")
        continue
    }
    let icon = NSWorkspace.shared.icon(forFile: app.resolvingSymlinksInPath().path)
    for size in [256, 128] {
        if !png(icon, size: size, to: output.appendingPathComponent("\(name)-\(size).png")) {
            FileHandle.standardError.write("could not draw \(name) at \(size) px\n".data(using: .utf8)!)
            failed = true
        }
    }
    print("found \(name) \(app.resolvingSymlinksInPath().path)")
}
exit(failed ? 1 : 0)
SWIFT
mkdir -p "$WORK/apps"
swift "$WORK/icons.swift" "$WORK/apps" \
  "safari=/Applications/Safari.app=com.apple.Safari" \
  "chrome=/Applications/Google Chrome.app=com.google.Chrome" \
  "mail=/System/Applications/Mail.app=com.apple.mail" \
  "notes=/System/Applications/Notes.app=com.apple.Notes" \
  "messages=/System/Applications/Messages.app=com.apple.MobileSMS" \
  "music=/System/Applications/Music.app=com.apple.Music" \
  "finder=/System/Library/CoreServices/Finder.app=com.apple.finder" \
  "terminal=/System/Applications/Utilities/Terminal.app=com.apple.Terminal" \
  "xcode=/Applications/Xcode.app=com.apple.dt.Xcode" \
  "preview=/System/Applications/Preview.app=com.apple.Preview" > "$WORK/icons.txt"

APPS=website/img/apps
mkdir -p "$APPS"
rm -f "$APPS"/*.webp "$APPS"/*-128.png
exported=0
while read -r status name _; do
  if [ "$status" = "missing" ]; then
    echo "  not installed, no icon: $name" >&2
    continue
  fi
  "$CWEBP" -quiet -q 90 -alpha_q 100 -m 6 -sharp_yuv -metadata none "$WORK/apps/$name-256.png" -o "$APPS/$name.webp"
  cp "$WORK/apps/$name-128.png" "$APPS/$name-128.png"
  exported=$((exported + 1))
done < "$WORK/icons.txt"

echo "✓ $WINDOWS: ${#ids[@]} windows; $APPS: $exported icons"
