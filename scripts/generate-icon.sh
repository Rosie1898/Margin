#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/module-cache"
swiftc -parse-as-library -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/Sources/Branding.swift" "$ROOT/scripts/generate-icon.swift" \
  -framework SwiftUI -framework AppKit -o "$ROOT/.build/generate-icon"
"$ROOT/.build/generate-icon" "$ROOT/assets"
