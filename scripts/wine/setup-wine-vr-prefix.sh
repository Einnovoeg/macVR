#!/usr/bin/env bash
set -euo pipefail

PREFIX_PATH="${1:-$HOME/.macvr/wineprefix}"
WINE_BIN="${WINE_BIN:-wine64}"
WINETRICKS_BIN="${WINETRICKS_BIN:-winetricks}"

echo "Using prefix: $PREFIX_PATH"
mkdir -p "$PREFIX_PATH"

if ! command -v "$WINE_BIN" >/dev/null 2>&1; then
  echo "error: $WINE_BIN not found in PATH (set WINE_BIN=... to override)." >&2
  exit 1
fi

if ! command -v "$WINETRICKS_BIN" >/dev/null 2>&1; then
  echo "error: $WINETRICKS_BIN not found in PATH (set WINETRICKS_BIN=... to override)." >&2
  exit 1
fi

export WINEPREFIX="$PREFIX_PATH"
export WINEARCH=win64

echo "Initializing prefix..."
"$WINE_BIN" wineboot -u

echo "Installing runtime dependencies (this can take a while)..."
"$WINETRICKS_BIN" -q \
  corefonts \
  vcrun2022 \
  d3dcompiler_47 \
  dxvk

echo "Prefix setup complete."
echo "Next: run scripts/wine/run-steam-with-macvr.sh \"$PREFIX_PATH\""
