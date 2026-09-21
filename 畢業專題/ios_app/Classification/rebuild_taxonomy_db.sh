#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-/Users/elaine/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3}"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-/tmp/swift-module-cache}"
TMP_WORK_DIR="${TMP_WORK_DIR:-/tmp/codex-coreml}"
SWIFT_EXECUTABLE="${SWIFT_EXECUTABLE:-$TMP_WORK_DIR/generate_text_embeddings}"

mkdir -p "$MODULE_CACHE_DIR" "$TMP_WORK_DIR"

"$PYTHON_BIN" "$ROOT_DIR/Classification/import_xlsx_to_sqlite.py" \
  --xlsx "$ROOT_DIR/Classification/分類表.xlsx" \
  --sqlite "$ROOT_DIR/MobileCLIPExplore/SQLite/PhotoAI.sqlite"

TMPDIR="$TMP_WORK_DIR/" \
xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -o "$SWIFT_EXECUTABLE" \
  "$ROOT_DIR/Classification/generate_text_embeddings.swift" \
  "$ROOT_DIR/MobileCLIPExplore/Tokenizer/CLIPTokenizer.swift" \
  "$ROOT_DIR/MobileCLIPExplore/Tokenizer/GPT2ByteEncoder.swift" \
  "$ROOT_DIR/MobileCLIPExplore/Tokenizer/Utils.swift"

TMPDIR="$TMP_WORK_DIR/" \
"$SWIFT_EXECUTABLE" \
  --sqlite "$ROOT_DIR/MobileCLIPExplore/SQLite/PhotoAI.sqlite" \
  --model "$ROOT_DIR/MobileCLIPExplore/Models/mobileclip_s2_text.mlpackage" \
  --resources "$ROOT_DIR/MobileCLIPExplore/Resources"
