#!/bin/bash
# Riffle's checks, the same ones CI runs.
#
#   ./Scripts/test.sh              → build, unit tests, translations, release build for Apple silicon and Intel
#   ./Scripts/test.sh unit l10n    → only the steps named: build, unit, l10n, universal
#
# RIFFLE_SCRATCH_PATH=<folder> keeps the build there instead of in .build (which Scripts/build.sh points into
# ~/Library/Caches/Riffle). RIFFLE_REAL_CRASH_TESTS=1 adds the one test that really crashes, leaving a crash report
# (CI sets it). Note that the translation check also rewrites Localization/source.json from the code.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH_PATH="${RIFFLE_SCRATCH_PATH:-.build}"
if [ $# -eq 0 ]; then set -- build unit l10n universal; fi

for step in "$@"; do
  case "$step" in
    build)
      echo "▸ Building"
      swift build --scratch-path "$SCRATCH_PATH"
      ;;
    unit)
      echo "▸ Unit tests"
      swift test --scratch-path "$SCRATCH_PATH"
      ;;
    l10n)
      echo "▸ Translations"
      python3 Scripts/l10n.py check
      # The script's own test, on a copy of the project.
      python3 Tests/L10n/test_l10n.py
      ;;
    universal)
      # What Scripts/build.sh ships: the app in release, one binary for both architectures (macOS 26 still runs on some
      # Intel Macs). The unit tests run on the build machine's architecture only.
      echo "▸ Release build for Apple silicon and Intel"
      flags=(-c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH_PATH")
      swift build "${flags[@]}" --product Riffle
      binary="$(swift build "${flags[@]}" --show-bin-path)/Riffle"
      archs="$(lipo -archs "$binary")"
      if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
        echo "✗ $binary is built for $archs, not arm64 and x86_64" >&2
        exit 1
      fi
      echo "  $archs"
      ;;
    *)
      echo "Unknown step \"$step\": use build, unit, l10n or universal." >&2
      exit 64
      ;;
  esac
done
