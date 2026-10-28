#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/math-tests"
mkdir -p "$BUILD/module-cache"
RUN="$(mktemp -d "$BUILD/run.XXXXXX")"
APP="$RUN/MathRenderingTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R "$ROOT/assets/math" "$APP/Contents/Resources/MathRenderer"
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Sources/MathMessageView.swift" "$ROOT/Tests/math-rendering-tests.swift" \
  -framework SwiftUI -framework AppKit -framework WebKit -o "$APP/Contents/MacOS/MathRenderingTests"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.margin.math-tests</string><key>CFBundleExecutable</key><string>MathRenderingTests</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
if [ "${1:-}" = "--build-only" ]; then printf 'Compiled math tests: %s\n' "$APP"; exit 0; fi
open -n -W "$APP"
if [ ! -f "$RUN/result.txt" ]; then echo "Math tests produced no result: $RUN" >&2; exit 1; fi
cat "$RUN/result.txt"
printf '\n'
if ! rg -q '^PASS ' "$RUN/result.txt"; then exit 1; fi
