#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/ocr-tests"
mkdir -p "$BUILD/module-cache"
RUN="$(mktemp -d "$BUILD/run.XXXXXX")"
FLAGS=(-parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/module-cache"
  -framework SwiftUI -framework AppKit -framework PDFKit -framework CryptoKit -framework Security -framework Vision -framework CoreText)
xcrun swiftc "${FLAGS[@]}" "$ROOT/Sources/LocalOCR.swift" "$ROOT/Tests/ocr-tests.swift" -o "$BUILD/ocr-tests"
SOURCES=()
for name in Models ChatService KeychainStore UIStrings ReaderStore ReaderOCR LocalOCR SampleDocument PDFCanvas SelectionActionSurface; do
  SOURCES+=("$ROOT/Sources/$name.swift")
done
xcrun swiftc "${FLAGS[@]}" "${SOURCES[@]}" "$ROOT/Tests/ocr-store-tests.swift" -o "$BUILD/ocr-store-tests"
if [ "${1:-}" = "--build-only" ]; then
  printf 'OCR checks compiled: %s\n' "$BUILD"
  exit 0
fi
# Run sequentially: each test uses only synthetic PDFs and isolated local data.
# No ChatService is started and no account or model request is made.
"$BUILD/ocr-tests" "$ROOT" "$RUN/engine"
"$BUILD/ocr-store-tests" "$ROOT" "$RUN/store"
printf 'OCR checks passed. Results: %s\n' "$RUN"
