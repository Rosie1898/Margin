#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Margin.app"
NODE_BIN="${NODE_BINARY:-$(command -v node || true)}"
if [ ! -x "$NODE_BIN" ]; then echo 'Node.js 22+ is required to build the local connection service.' >&2; exit 1; fi
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then echo 'Node.js 22+ is required.' >&2; exit 1; fi
NODE_LICENSE="${NODE_LICENSE_FILE:-}"
if [ -z "$NODE_LICENSE" ] && [ "$("$NODE_BIN" --version)" = "v24.19.0" ]; then
  NODE_LICENSE="$ROOT/third_party/node/LICENSE"
fi
if [ ! -f "$NODE_LICENSE" ]; then echo 'Set NODE_LICENSE_FILE to the complete license accompanying your Node.js distribution.' >&2; exit 1; fi
# Recreate resources so stale test modules or sample PDFs cannot enter a release.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend" "$APP/Contents/Resources/Samples" "$ROOT/.build/module-cache"
swiftc -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$ROOT/.build/module-cache" -o "$APP/Contents/MacOS/LeafReader" "$ROOT"/Sources/*.swift -framework SwiftUI -framework AppKit -framework PDFKit -framework CryptoKit -framework Security -framework Vision -framework CoreText
for SOURCE in "$ROOT"/Backend/*.mjs; do
  case "$SOURCE" in *.test.mjs) continue ;; esac
  cp "$SOURCE" "$APP/Contents/Resources/Backend/"
done
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
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>12</string>
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
printf 'Built: %s\n' "$APP"
