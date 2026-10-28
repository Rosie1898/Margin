#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/Margin.app"
NODE_BIN="${NODE_BINARY:-$(command -v node || true)}"
# Reuse the installed runtime when this Mac has no standalone Node command.
if [ -z "$NODE_BIN" ] && [ -f "$ROOT/.local-install-path" ]; then
  NODE_BIN="$(cat "$ROOT/.local-install-path")/Contents/Resources/node"
fi
if [ ! -x "$NODE_BIN" ]; then echo 'Node.js 22+ is required to build the local connection service.' >&2; exit 1; fi
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then echo 'Node.js 22+ is required.' >&2; exit 1; fi
NODE_LICENSE="${NODE_LICENSE_FILE:-}"
if [ -z "$NODE_LICENSE" ] && [ "$("$NODE_BIN" --version)" = "v24.19.0" ]; then
  NODE_LICENSE="$ROOT/third_party/node/LICENSE"
fi
if [ ! -f "$NODE_LICENSE" ]; then echo 'Set NODE_LICENSE_FILE to the complete license accompanying your Node.js distribution.' >&2; exit 1; fi
# Build separately so failures preserve the previous app and moved caches cannot break compilation.
BUILD_WORK="$(mktemp -d "${TMPDIR:-/tmp}/margin-build.XXXXXX")"
trap 'rm -rf "$BUILD_WORK"' EXIT
APP="$BUILD_WORK/Margin.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend" "$APP/Contents/Resources/Samples" "$BUILD_WORK/module-cache"
swiftc -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$BUILD_WORK/module-cache" -o "$APP/Contents/MacOS/LeafReader" "$ROOT"/Sources/*.swift -framework SwiftUI -framework AppKit -framework PDFKit -framework CryptoKit -framework Security -framework Vision -framework CoreText -framework WebKit
for SOURCE in "$ROOT"/Backend/*.mjs; do
  case "$SOURCE" in *.test.mjs) continue ;; esac
  cp "$SOURCE" "$APP/Contents/Resources/Backend/"
done
cp -R "$ROOT/assets/math" "$APP/Contents/Resources/MathRenderer"
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp "$NODE_LICENSE" "$APP/Contents/Resources/ThirdParty/Node-LICENSE.txt"
# The optional Lucas sample is downloaded only at the reader's request.
# No third-party PDF is redistributed in the source or app bundle.
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/MarginMonogram.icns"
rm -f "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/MarginIcon.icns"
if [ ! -f "$APP/Contents/Resources/node" ] || ! cmp -s "$NODE_BIN" "$APP/Contents/Resources/node"; then cp "$NODE_BIN" "$APP/Contents/Resources/node"; fi
chmod +x "$APP/Contents/Resources/node"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.leaf.pdfreader</string>
<key>CFBundleName</key><string>Margin</string>
<key>CFBundleDisplayName</key><string>Margin</string>
<key>CFBundleExecutable</key><string>LeafReader</string>
<key>CFBundleIconFile</key><string>MarginMonogram.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.3</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array>
<string>en</string><string>zh-Hans</string><string>zh-Hant</string>
<string>ja</string><string>ko</string><string>fr</string>
<string>de</string><string>es</string><string>pt</string>
</array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
# In-place builds must also advertise a changed bundle to Finder/LaunchServices.
touch "$APP"
python3 "$ROOT/scripts/install-local.py" --source "$APP" --destination "$OUTPUT" >/dev/null
printf 'Built: %s\n' "$OUTPUT"
# Local installation is opt-in and runs only after a successful signed build.
if [ -f "$ROOT/.local-install-path" ]; then
  python3 "$ROOT/scripts/install-local.py" --source "$OUTPUT"
fi
