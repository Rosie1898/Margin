#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$PROJECT_ROOT/.build/native-tests"
mkdir -p "$TEST_BUILD/module-cache"
TEST_RUN="$(mktemp -d "$TEST_BUILD/run.XXXXXX")"

NODE_BIN="${NODE_BINARY:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ] && [ -x "$PROJECT_ROOT/Margin.app/Contents/Resources/node" ]; then
  NODE_BIN="$PROJECT_ROOT/Margin.app/Contents/Resources/node"
fi
if [ -z "$NODE_BIN" ] && [ -x "$PROJECT_ROOT/Leaf Reader.app/Contents/Resources/node" ]; then
  NODE_BIN="$PROJECT_ROOT/Leaf Reader.app/Contents/Resources/node"
fi
if [ ! -x "$NODE_BIN" ]; then
  echo 'Native checks require Node.js 22+. Set NODE_BINARY to its absolute path.' >&2
  exit 1
fi
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo 'Native checks require Node.js 22+.' >&2
  exit 1
fi

# Use current source resources without rebuilding or touching a running app.
mkdir -p "$TEST_RUN/Resources/Backend"
cp "$NODE_BIN" "$TEST_RUN/Resources/node"
chmod +x "$TEST_RUN/Resources/node"
cp "$PROJECT_ROOT"/Backend/*.mjs "$TEST_RUN/Resources/Backend/"

SWIFT_FLAGS=(-parse-as-library -module-cache-path "$TEST_BUILD/module-cache"
  -framework SwiftUI -framework AppKit -framework PDFKit -framework CryptoKit -framework Security -framework Vision -framework CoreText)
MODELS="$PROJECT_ROOT/Sources/Models.swift"
CHAT="$PROJECT_ROOT/Sources/ChatService.swift"
KEYCHAIN="$PROJECT_ROOT/Sources/KeychainStore.swift"
STRINGS="$PROJECT_ROOT/Sources/UIStrings.swift"

compile_check() {
  local name="$1"
  shift
  if ! xcrun swiftc "${SWIFT_FLAGS[@]}" "$@" "$PROJECT_ROOT/Tests/$name.swift" -o "$TEST_BUILD/$name" >"$TEST_RUN/$name-build.log" 2>&1; then
    cat "$TEST_RUN/$name-build.log" >&2
    exit 1
  fi
}

compile_check store-tests "$MODELS" "$CHAT" "$KEYCHAIN" "$STRINGS" "$PROJECT_ROOT/Sources/ReaderStore.swift" "$PROJECT_ROOT/Sources/ReaderOCR.swift" "$PROJECT_ROOT/Sources/LocalOCR.swift" "$PROJECT_ROOT/Sources/SampleDocument.swift"
compile_check canvas-tests "$MODELS" "$PROJECT_ROOT/Sources/PDFCanvas.swift" "$PROJECT_ROOT/Sources/SelectionActionSurface.swift"
compile_check chat-lifecycle "$MODELS" "$CHAT" "$KEYCHAIN"
compile_check keychain-tests "$KEYCHAIN"
compile_check localization-tests "$MODELS" "$CHAT" "$KEYCHAIN" "$STRINGS" "$PROJECT_ROOT/Sources/ReaderStore.swift" "$PROJECT_ROOT/Sources/ReaderOCR.swift" "$PROJECT_ROOT/Sources/LocalOCR.swift" "$PROJECT_ROOT/Sources/SampleDocument.swift"
compile_check split-persistence-tests "$MODELS" "$CHAT" "$KEYCHAIN" "$STRINGS" "$PROJECT_ROOT/Sources/ReaderStore.swift" "$PROJECT_ROOT/Sources/ReaderOCR.swift" "$PROJECT_ROOT/Sources/LocalOCR.swift" "$PROJECT_ROOT/Sources/SampleDocument.swift" "$PROJECT_ROOT/Sources/ReaderSplitView.swift"
compile_check outline-tests "$MODELS" "$PROJECT_ROOT/Sources/LibraryOutline.swift"
compile_check sample-navigation-tests "$MODELS" "$CHAT" "$KEYCHAIN" "$STRINGS" "$PROJECT_ROOT/Sources/ReaderStore.swift" "$PROJECT_ROOT/Sources/ReaderOCR.swift" "$PROJECT_ROOT/Sources/LocalOCR.swift" "$PROJECT_ROOT/Sources/SampleDocument.swift"
echo 'Compiled 8 native checks.' 

run_check() {
  local name="$1"
  local result=0
  "$TEST_BUILD/$name" "$PROJECT_ROOT" "$TEST_RUN" >"$TEST_RUN/$name.log" 2>&1 || result=$?
  if [ "$result" -ne 0 ]; then
    cat "$TEST_RUN/$name.log" >&2
    printf 'Native check failed: %s (exit %s). Logs: %s\n' "$name" "$result" "$TEST_RUN" >&2
    exit "$result"
  fi
  tail -n 1 "$TEST_RUN/$name.log"
}

run_check store-tests
run_check canvas-tests
run_check chat-lifecycle
run_check keychain-tests
run_check localization-tests
run_check split-persistence-tests
run_check outline-tests
run_check sample-navigation-tests
printf '{"status":"passed","checks":["store-tests","canvas-tests","chat-lifecycle","keychain-tests","localization-tests","split-persistence-tests","outline-tests","sample-navigation-tests"],"externalAPICalls":0}\n' >"$TEST_RUN/result.json"
printf 'Native checks passed. Results: %s\n' "$TEST_RUN"
