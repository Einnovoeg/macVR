#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/MacVRJPEGSenderApp/main.c"
OUTPUT_PATH="${1:-$ROOT_DIR/.build/win/macvr-jpeg-sender.exe}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "Using x86_64-w64-mingw32-gcc"
  x86_64-w64-mingw32-gcc \
    -O2 \
    -std=c11 \
    -Wall \
    -Wextra \
    -D_CRT_SECURE_NO_WARNINGS \
    -o "$OUTPUT_PATH" \
    "$SOURCE_FILE" \
    -lws2_32
elif command -v zig >/dev/null 2>&1; then
  echo "Using zig cc"
  zig cc \
    -target x86_64-windows-gnu \
    -O2 \
    -std=c11 \
    -Wall \
    -Wextra \
    -D_CRT_SECURE_NO_WARNINGS \
    -o "$OUTPUT_PATH" \
    "$SOURCE_FILE" \
    -lws2_32
else
  echo "error: no Windows C toolchain found." >&2
  echo "install x86_64-w64-mingw32-gcc or zig to build macvr-jpeg-sender.exe" >&2
  exit 1
fi

echo "Built $OUTPUT_PATH"
